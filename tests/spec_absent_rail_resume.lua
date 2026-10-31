return function()
	local api, util = vim.api, require("lazyvcs.util")
	local rail = require("lazyvcs.absent_rail")
	local names =
		{ "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "winfixwidth", "winfixheight" }
	local function preferences(label)
		return {
			number = true,
			relativenumber = true,
			signcolumn = "yes:1",
			foldcolumn = "2",
			statuscolumn = label,
			winfixwidth = false,
			winfixheight = false,
		}
	end
	local function capture(win)
		return util.capture_win_options(win, names)
	end
	local cases = {}
	for _, mode in ipairs({ "noop", "release", "close", "rebind", "same_session", "new_session", "takeover" }) do
		cases[#cases + 1] = {
			"test_core_absent_rail_resume_" .. mode,
			function()
				vim.cmd.tabnew()
				local tab, win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
				vim.cmd.vnew()
				local other = api.nvim_get_current_win()
				api.nvim_set_current_win(win)
				local hooks, sessions = {}, {}
				local s = {}
				sessions[#sessions + 1] = s
				local target = (mode == "new_session" or mode == "takeover") and {} or s
				if target ~= s then
					sessions[#sessions + 1] = target
				end
				local original = preferences("ORIGINAL")
				local resumed, fired, armed, replacement, after = false, 0, true, nil, nil
				local ok, err = xpcall(function()
					util.set_win_options(win, original)
					local other_before = capture(other)
					rail.apply(s, win, false)
					local old = assert(s.rail)
					hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", {
						pattern = names,
						nested = true,
						callback = function()
							if not armed or not resumed or api.nvim_get_current_win() ~= win then
								return
							end
							armed, fired = false, fired + 1
							if mode == "release" then
								rail.release(s)
							elseif mode == "close" then
								api.nvim_win_close(win, true)
							elseif mode == "rebind" then
								api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
								util.set_win_options(win, preferences("UNRELATED"))
								after = capture(win)
							elseif mode == "same_session" or mode == "new_session" or mode == "takeover" then
								if mode ~= "takeover" then
									rail.release(s)
								end
								util.set_win_options(win, preferences("REPLACEMENT"))
								rail.apply(target, win, true)
								replacement = assert(target.rail)
							end
						end,
					})
					hooks[#hooks + 1] = api.nvim_create_autocmd("BufLeave", {
						nested = true,
						callback = function()
							if not resumed and api.nvim_get_current_win() == win then
								assert(
									s.rail == old and old.suspended,
									"real BufLeave did not suspend the existing rail"
								)
								resumed = true
								rail.apply(s, win, false)
							end
						end,
					})
					api.nvim_set_current_win(other)
					assert(resumed and fired == 1, "native resume setter callback did not run")
					if mode == "noop" then
						assert(s.rail == old and not old.suspended)
						for name, value in pairs(old.written) do
							assert(util.get_win_option(win, name) == value, "resume missed " .. name)
						end
						rail.release(s)
						assert(vim.deep_equal(capture(win), original), "normal resume lost original options")
					elseif mode == "release" then
						assert(not s.rail)
						rail.release(s)
						assert(
							vim.deep_equal(capture(win), original),
							"released resume continued writing collapsed options"
						)
					elseif mode == "close" then
						assert(not api.nvim_win_is_valid(win) and not s.rail)
					elseif mode == "rebind" then
						assert(not s.rail, "resume retained a departed buffer")
						assert(vim.deep_equal(capture(win), after), "old resume changed replacement buffer options")
					else
						assert(
							replacement and target.rail == replacement and replacement ~= old and replacement.stacked
						)
						for name, value in pairs(replacement.written) do
							assert(util.get_win_option(win, name) == value, "old resume changed new " .. name)
						end
						assert(
							not util.get_win_option(win, "winfixwidth"),
							"old resume wrote its width into the stacked replacement"
						)
						local clone
						api.nvim_win_call(win, function()
							clone = api.nvim_open_win(
								api.nvim_get_current_buf(),
								false,
								{ relative = "editor", row = 1, col = 1, width = 16, height = 2 }
							)
						end)
						assert(
							vim.deep_equal(capture(clone), preferences("REPLACEMENT")),
							"resume replacement lost copy provenance"
						)
						api.nvim_win_close(clone, true)
						rail.release(target)
						assert(
							vim.deep_equal(capture(win), preferences("REPLACEMENT")),
							"resume replacement lost its own preferences"
						)
					end
					assert(vim.deep_equal(capture(other), other_before), "resume changed an unrelated window")
				end, debug.traceback)
				for _, id in ipairs(hooks) do
					pcall(api.nvim_del_autocmd, id)
				end
				for _, session in ipairs(sessions) do
					pcall(rail.release, session)
				end
				if api.nvim_tabpage_is_valid(tab) then
					api.nvim_set_current_tabpage(tab)
					vim.cmd.tabclose({ bang = true })
				end
				assert(ok, err)
			end,
		}
	end
	return cases
end
