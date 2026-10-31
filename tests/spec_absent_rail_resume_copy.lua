return function()
	local api, util = vim.api, require("lazyvcs.util")
	local rail = require("lazyvcs.absent_rail")
	local names =
		{ "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "winfixwidth", "winfixheight" }
	local cases = {}
	for _, mode in ipairs({ "initial", "resume_first", "resume_middle", "resume_preferences", "resume_release" }) do
		cases[#cases + 1] = {
			"test_core_absent_rail_copy_" .. mode,
			function()
				vim.cmd.tabnew()
				local tab, win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
				vim.cmd.vnew()
				local other = api.nvim_get_current_win()
				api.nvim_set_current_win(win)
				local original = {
					number = true,
					relativenumber = true,
					signcolumn = "yes:1",
					foldcolumn = "2",
					statuscolumn = "ORIGINAL",
					winfixwidth = false,
					winfixheight = false,
				}
				local expected = vim.deepcopy(original)
				local s, clone, hooks, writes = {}, nil, {}, 0
				local armed, resumed = mode == "initial", false
				local function capture(target)
					return util.capture_win_options(target, names)
				end
				local ok, err = xpcall(function()
					util.set_win_options(win, original)
					local other_before = capture(other)
					hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", {
						pattern = names,
						nested = true,
						callback = function()
							if not armed or api.nvim_get_current_win() ~= win then
								return
							end
							writes = writes + 1
							if mode == "resume_middle" and writes == 1 then
								return
							end
							armed = false
							clone = api.nvim_open_win(
								api.nvim_get_current_buf(),
								false,
								{ relative = "editor", row = 1, col = 1, width = 20, height = 3 }
							)
							if mode == "resume_preferences" then
								api.nvim_win_call(clone, function()
									vim.cmd("setlocal signcolumn=yes:2 statuscolumn=LATEST")
								end)
								expected.signcolumn, expected.statuscolumn = "yes:2", "LATEST"
							elseif mode == "resume_release" then
								rail.release(s)
							end
						end,
					})
					rail.apply(s, win, false)
					if mode ~= "initial" then
						hooks[#hooks + 1] = api.nvim_create_autocmd("BufLeave", {
							nested = true,
							callback = function()
								if not resumed and api.nvim_get_current_win() == win then
									assert(s.rail and s.rail.suspended, "natural BufLeave did not suspend rail")
									resumed, armed = true, true
									rail.apply(s, win, false)
								end
							end,
						})
						api.nvim_set_current_win(other)
					end
					assert(clone, "native setter copy did not run")
					assert(
						vim.deep_equal(capture(clone), expected),
						"native copy retained collapsed options before release"
					)
					rail.release(s)
					assert(vim.deep_equal(capture(clone), expected), "release changed native copy preferences")
					assert(vim.deep_equal(capture(win), original), "resume/copy lost original source options")
					assert(vim.deep_equal(capture(other), other_before), "resume/copy changed unrelated window")
				end, debug.traceback)
				for _, id in ipairs(hooks) do
					pcall(api.nvim_del_autocmd, id)
				end
				pcall(rail.release, s)
				if clone and api.nvim_win_is_valid(clone) then
					api.nvim_win_close(clone, true)
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
