return function(ctx)
	local api, h = vim.api, ctx.helpers
	local util, state = require("lazyvcs.util"), require("lazyvcs.state")
	local integration = require("lazyvcs.integrations.resession")
	local names = {
		"diff",
		"scrollbind",
		"cursorbind",
		"wrap",
		"foldmethod",
		"foldenable",
		"foldcolumn",
		"winbar",
		"winhighlight",
	}
	local hooks
	local function dispatch(name, tab)
		for _, callback in ipairs(hooks[name]) do
			callback("batch", {}, tab)
		end
	end
	local function guarded(fn)
		return function()
			integration.teardown()
			local original = package.loaded.resession
			local foldclosed, foldlevel, setter, notify =
				vim.fn.foldclosed, vim.fn.foldlevel, util.set_win_option_noautocmd, util.notify
			local columns, lines, diffopt = vim.o.columns, vim.o.lines, vim.o.diffopt
			hooks = { pre_save = {}, post_save = {} }
			package.loaded.resession = {
				add_hook = function(name, callback)
					table.insert(hooks[name], callback)
				end,
				remove_hook = function(name, callback)
					for i, hook in ipairs(hooks[name]) do
						if hook == callback then
							table.remove(hooks[name], i)
							break
						end
					end
				end,
			}
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			vim.o.columns, vim.o.lines = 220, 45
			local ok, err = xpcall(fn, debug.traceback)
			vim.fn.foldclosed, util.set_win_option_noautocmd, util.notify = foldclosed, setter, notify
			vim.fn.foldlevel = foldlevel
			integration.teardown()
			package.loaded.resession = original
			h.cleanup()
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			vim.cmd("diffoff")
			vim.o.columns, vim.o.lines, vim.o.diffopt = columns, lines, diffopt
			assert(ok, err)
		end
	end
	local function fixture(enabled)
		local f, left, right = h.make_git_fixture(), {}, {}
		for i = 1, 180 do
			left[i], right[i] = "line " .. i, "line " .. i
		end
		right[40], right[140] = "change one", "change two"
		for i = 1, 4 do
			h.write_file(f.root .. "/batch" .. i .. ".txt", table.concat(left, "\n") .. "\n")
		end
		h.exec({ "git", "add", "." }, f.root)
		h.exec({ "git", "commit", "-m", "batch fixture" }, f.root)
		local sessions, wins = {}, {}
		for i = 1, 3 do
			local file = f.root .. "/batch" .. i .. ".txt"
			h.write_file(file, table.concat(right, "\n") .. "\n")
			vim.cmd("rightbelow new")
			util.editor_window(api.nvim_get_current_win())
			vim.cmd.edit(vim.fn.fnameescape(file))
			local buf = api.nvim_get_current_buf()
			require("lazyvcs").open()
			ctx.wait_for(function()
				return state.get(buf) ~= nil
			end, "batch live diff did not open", 15000)
			local s = assert(state.get(buf))
			sessions[#sessions + 1] = s
			wins[#wins + 1], wins[#wins + 2] = s.editable_win, s.base_win
		end
		vim.cmd("rightbelow new")
		util.editor_window(api.nvim_get_current_win())
		vim.cmd.edit(vim.fn.fnameescape(f.root .. "/batch4.txt"))
		vim.cmd("diffthis")
		wins[#wins + 1] = api.nvim_get_current_win()
		api.nvim_win_call(sessions[1].editable_win, function()
			vim.cmd.split()
		end)
		wins[#wins + 1] = api.nvim_get_current_win()
		-- nvim_win_call restores focus; find the new derived editable split.
		for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
			if api.nvim_win_get_buf(win) == sessions[1].editable_bufnr and win ~= sessions[1].editable_win then
				wins[#wins] = win
			end
		end
		vim.cmd("diffupdate")
		vim.wait(100, function()
			return false
		end)
		for _, win in ipairs(wins) do
			util.set_win_option(win, "foldenable", enabled)
		end
		return sessions, wins
	end
	local function snapshot(wins, folds)
		local result = {}
		for _, win in ipairs(wins) do
			result[win] = {
				buf = api.nvim_win_get_buf(win),
				options = util.capture_win_options(win, names),
				view = api.nvim_win_call(win, vim.fn.winsaveview),
			}
			if folds then
				result[win].folds = api.nvim_win_call(win, function()
					local values = {}
					for line = 1, api.nvim_buf_line_count(0) do
						values[line] = vim.fn.foldclosed(line)
					end
					return values
				end)
			end
		end
		return result
	end
	local function intact(sessions, wins, before, folds)
		local after = snapshot(wins, folds)
		for win, record in pairs(before) do
			for name, value in pairs(record) do
				assert(vim.deep_equal(after[win][name], value), "batch save changed " .. name .. " in window " .. win)
			end
		end
		for _, s in ipairs(sessions) do
			assert(state.get(s.editable_bufnr) == s and s.phase == "active")
		end
	end
	local function scans()
		local original, counts = vim.fn.foldclosed, {}
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.foldclosed = function(line)
			local win = api.nvim_get_current_win()
			if line == 1 then
				counts[win] = (counts[win] or 0) + 1
			end
			return original(line)
		end
		return counts, function()
			vim.fn.foldclosed = original
		end
	end

	local cases = {
		{
			"test_live_diff_resession_preserves_other_tab_user_diff",
			function()
				local sessions = fixture(false)
				local first_tab = sessions[1].tabpage
				vim.cmd.tabnew()
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local buf = api.nvim_get_current_buf()
				require("lazyvcs").open()
				ctx.wait_for(function()
					return state.get(buf) ~= nil
				end, "other-tab diff did not open", 15000)
				local outside = assert(state.get(buf))
				api.nvim_set_current_tabpage(first_tab)
				vim.cmd("belowright new")
				local win = api.nvim_get_current_win()
				api.nvim_win_set_buf(win, buf)
				vim.cmd.diffthis()
				local before = util.capture_win_options(win, names)
				dispatch("pre_save")
				assert(
					vim.deep_equal(util.capture_win_options(win, names), before),
					"save projected another tab's session onto user diff window"
				)
				dispatch("post_save")
				assert(outside.phase == "active" and vim.deep_equal(util.capture_win_options(win, names), before))
			end,
		},
		{
			"test_live_diff_resession_disabled_folds_do_not_scan_lines",
			function()
				local sessions, wins = fixture(false)
				local before, focus = snapshot(wins), api.nvim_get_current_win()
				local counts, stop = scans()
				local foldclosed, calls = vim.fn.foldclosed, 0
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.foldclosed = function(line)
					calls = calls + 1
					return foldclosed(line)
				end
				dispatch("pre_save")
				dispatch("post_save")
				vim.fn.foldclosed = foldclosed
				stop()
				assert(next(counts) == nil, "disabled folds visited scan lines")
				assert(calls == 0, "disabled folds scanned " .. calls .. " lines")
				intact(sessions, wins, before)
				assert(api.nvim_get_current_win() == focus, "batch save changed focus")
				-- Interrupted saves and partial projection failures use the same rollback.
				dispatch("pre_save")
				ctx.wait_for(function()
					return sessions[1].phase == "active"
				end, "batch fallback did not resume")
				intact(sessions, wins, before)
				local setter, notify, writes, messages = util.set_win_option_noautocmd, util.notify, 0, {}
				---@diagnostic disable-next-line: duplicate-set-field
				util.set_win_option_noautocmd = function(...)
					writes = writes + 1
					if writes == 8 then
						error("partial batch projection failure\nsecond line")
					end
					return setter(...)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(message)
					messages[#messages + 1] = message
				end
				dispatch("pre_save")
				util.set_win_option_noautocmd, util.notify = setter, notify
				assert(
					#messages == 1 and not messages[1]:find("\n"),
					"batch failure was not one single-line notification"
				)
				intact(sessions, wins, before)
			end,
		},
		{
			"test_live_diff_resession_captures_each_window_once",
			function()
				local sessions, wins = fixture(true)
				-- User-selected non-diff methods need no capture or replay.
				util.set_win_option(wins[1], "foldmethod", "manual")
				util.set_win_option(wins[#wins], "foldmethod", "manual")
				local before = snapshot(wins)
				local captures, stop = scans()
				dispatch("pre_save")
				stop()
				for _, win in ipairs(wins) do
					local expected = before[win].options.foldmethod == "diff" and 1 or nil
					assert(captures[win] == expected, "unexpected fold capture count: " .. tostring(captures[win]))
				end
				local restores
				restores, stop = scans()
				dispatch("post_save")
				stop()
				for _, win in ipairs(wins) do
					local expected = before[win].options.foldmethod == "diff" and 1 or nil
					assert(restores[win] == expected, "unexpected fold restore count: " .. tostring(restores[win]))
				end
				intact(sessions, wins, before)
				-- Scope the next save to this tab while another live session remains active.
				vim.cmd.tabnew()
				local other = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(other.file))
				local buf = api.nvim_get_current_buf()
				require("lazyvcs").open()
				ctx.wait_for(function()
					return state.get(buf) ~= nil
				end, "other-tab session did not open", 15000)
				local outside = assert(state.get(buf))
				local options = util.capture_win_options(outside.editable_win, names)
				dispatch("pre_save", sessions[1].tabpage)
				assert(
					outside.phase == "active"
						and vim.deep_equal(util.capture_win_options(outside.editable_win, names), options)
				)
				dispatch("post_save")
				intact(sessions, wins, before)
			end,
		},
		{
			"test_live_diff_resession_batch_preserves_original_folds",
			function()
				local sessions, wins = fixture(true)
				for i, win in ipairs(wins) do
					api.nvim_win_call(win, function()
						vim.cmd("normal! zM")
						local line = i % 2 == 0 and 80 or 1
						assert(vim.fn.foldclosed(line) > 0, "batch fixture lacks folds")
						api.nvim_win_set_cursor(win, { line, 0 })
						vim.cmd("normal! zo")
					end)
				end
				local before = snapshot(wins, true)
				dispatch("pre_save")
				dispatch("post_save")
				intact(sessions, wins, before, true)
				-- Closing a projected session must not restore its transient options.
				dispatch("pre_save")
				local closed = sessions[1]
				require("lazyvcs.actions").close(closed.editable_bufnr)
				local options = util.capture_win_options(closed.editable_win, names)
				dispatch("post_save")
				assert(not state.get(closed.editable_bufnr), "batch revived closed session")
				assert(
					vim.deep_equal(util.capture_win_options(closed.editable_win, names), options),
					"closed editor regained transient options"
				)
				local replaced = sessions[3]
				dispatch("pre_save")
				local target = api.nvim_create_buf(true, false)
				api.nvim_win_set_buf(replaced.editable_win, target)
				util.set_win_options(
					replaced.editable_win,
					{ wrap = true, foldmethod = "manual", winbar = "replacement" }
				)
				local replacement_options = util.capture_win_options(replaced.editable_win, names)
				dispatch("post_save")
				assert(
					vim.deep_equal(util.capture_win_options(replaced.editable_win, names), replacement_options),
					"replacement received stale save options"
				)
				ctx.wait_for(function()
					return state.get(replaced.editable_bufnr) == nil
				end, "batch did not reconcile replaced source")
				-- Changed buffer text invalidates obsolete fold positions.
				local remaining = sessions[2]
				dispatch("pre_save")
				api.nvim_buf_set_lines(remaining.editable_bufnr, 0, -1, false, { "changed during serialization" })
				dispatch("post_save")
				ctx.wait_for(function()
					return remaining.current_text and remaining.current_text.lines[1] == "changed during serialization"
				end, "batch did not refresh serialized edit")
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
