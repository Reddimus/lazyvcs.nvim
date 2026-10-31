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
	local function add(name, fn)
		cases[#cases + 1] = {
			"test_core_absent_rail_initial_" .. name,
			function()
				vim.cmd.tabnew()
				local tab, win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
				vim.cmd.vsplit()
				local other = api.nvim_get_current_win()
				api.nvim_set_current_win(win)
				local hooks, owners = {}, {}
				local function own(s)
					owners[#owners + 1] = { session = s, record = s.rail }
				end
				local function hook(callback)
					hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", {
						pattern = names,
						nested = true,
						callback = callback,
					})
				end
				local ok, err = xpcall(function()
					fn(win, other, hook, own)
				end, debug.traceback)
				for _, id in ipairs(hooks) do
					pcall(api.nvim_del_autocmd, id)
				end
				for i = #owners, 1, -1 do
					local item = owners[i]
					-- A failing baseline can detach this private fixture's session pointer.
					if not item.session.rail then
						item.session.rail = item.record
					end
					pcall(rail.release, item.session)
				end
				if api.nvim_tabpage_is_valid(tab) then
					api.nvim_set_current_tabpage(tab)
					vim.cmd.tabclose({ bang = true })
				end
				assert(ok, err)
			end,
		}
	end
	for _, mode in ipairs({
		"normal",
		"release",
		"close",
		"rebind",
		"same_session",
		"new_session",
		"takeover",
		"copy",
		"latest",
	}) do
		add(mode, function(win, other, hook, own)
			local s, target = {}, nil
			target = (mode == "new_session" or mode == "takeover") and {} or s
			local original = preferences("ORIGINAL")
			util.set_win_options(win, original)
			local other_before = capture(other)
			local armed, fired, first, replacement, after, clone = mode ~= "normal", 0, nil, nil, nil, nil
			hook(function(event)
				if not armed or api.nvim_get_current_win() ~= win then
					return
				end
				armed, fired, first = false, fired + 1, event.match
				own(s)
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
					replacement = target.rail
					own(target)
				elseif mode == "copy" then
					clone = api.nvim_open_win(
						api.nvim_get_current_buf(),
						false,
						{ relative = "editor", row = 1, col = 1, width = 16, height = 2 }
					)
					after = capture(clone)
				elseif mode == "latest" then
					util.set_win_option(win, "number", false)
					util.set_win_option(win, "signcolumn", "yes:2")
				end
			end)
			rail.apply(s, win, false)
			assert(mode == "normal" or fired == 1, "native initial write callback did not run")
			if mode == "normal" then
				own(s)
				assert(s.rail and fired == 0)
				rail.release(s)
				assert(vim.deep_equal(capture(win), original))
			elseif mode == "release" then
				assert(fired == 1 and not s.rail)
				rail.release(s)
				assert(vim.deep_equal(capture(win), original), "retired initial apply left collapsed options")
			elseif mode == "close" then
				assert(fired == 1 and not api.nvim_win_is_valid(win) and not s.rail)
			elseif mode == "rebind" then
				assert(fired == 1 and not s.rail, "initial apply retained a departed buffer")
				assert(vim.deep_equal(capture(win), after), "old apply altered the replacement buffer")
			elseif mode == "same_session" or mode == "new_session" or mode == "takeover" then
				assert(replacement and target.rail == replacement and replacement.stacked)
				api.nvim_win_call(win, function()
					clone = api.nvim_open_win(
						api.nvim_get_current_buf(),
						false,
						{ relative = "editor", row = 1, col = 1, width = 16, height = 2 }
					)
				end)
				assert(vim.deep_equal(capture(clone), preferences("REPLACEMENT")), "old apply replaced copy ownership")
				rail.release(target)
				assert(vim.deep_equal(capture(win), preferences("REPLACEMENT")))
			elseif mode == "copy" then
				assert(fired == 1 and first == "statuscolumn", "copy provenance was not the first write")
				assert(vim.deep_equal(after, original), "native first-write copy inherited collapsed options")
				rail.release(s)
				assert(vim.deep_equal(capture(win), original))
			elseif mode == "latest" then
				assert(fired == 1 and not s.rail.before.number and s.rail.before.signcolumn == "yes:2")
				original.number, original.signcolumn = false, "yes:2"
				rail.release(s)
				assert(vim.deep_equal(capture(win), original), "initial apply lost a later field's preference")
			end
			assert(vim.deep_equal(capture(other), other_before), "initial apply changed an unrelated window")
		end)
	end
	for _, new_session in ipairs({ false, true }) do
		add("mismatched_cleanup_" .. (new_session and "new_session" or "same_session"), function(win, other, hook, own)
			local s = {}
			local target = new_session and {} or s
			util.set_win_options(win, preferences("ORIGINAL"))
			rail.apply(s, win, false)
			own(s)
			local armed, replacement = true, nil
			hook(function()
				if armed and api.nvim_get_current_win() == win then
					armed = false
					rail.release(s)
					util.set_win_options(other, preferences("REPLACEMENT"))
					rail.apply(target, other, false)
					replacement = target.rail
					own(target)
				end
			end)
			rail.apply(s, other, true)
			assert(replacement and target.rail == replacement and not replacement.stacked, "cleanup replacement lost")
			rail.release(target)
			assert(vim.deep_equal(capture(other), preferences("REPLACEMENT")))
			assert(vim.deep_equal(capture(win), preferences("ORIGINAL")))
		end)
	end
	add("one_owner_per_window", function(win, _, _, own)
		local previous, current = {}, {}
		local original = preferences("ORIGINAL")
		util.set_win_options(win, original)
		rail.apply(previous, win, false)
		own(previous)
		rail.apply(current, win, true)
		own(current)
		assert(not previous.rail and current.rail, "one window retained two rail owners")
		rail.release(current)
		assert(vim.deep_equal(capture(win), original), "new owner adopted another rail's collapsed options")
	end)
	return cases
end
