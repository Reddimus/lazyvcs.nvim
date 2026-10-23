-- A Compare pane that shows a real buffer must give back the folds, fold
-- options, and saved view the user had for it, and touch nothing else.
return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, util = require("lazyvcs.compare"), require("lazyvcs.util")
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job and not s.job
		end, "Compare did not load", 15000)
	end
	local function navigate(s, direction, relpath)
		compare.navigate_file(direction, 1)
		ctx.wait_for(function()
			return s.shown_item and s.shown_item.relpath == relpath and not s.preview_job and s.preview_result
		end, "Compare did not show " .. relpath, 15000)
	end
	local function lines(count, changed)
		local out = {}
		for index = 1, count do
			out[index] = (index == changed and "changed " or "line ") .. index
		end
		return table.concat(out, "\n") .. "\n"
	end
	-- a.txt (20 lines) and b.txt are committed, then changed.
	local function fixture()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
		local f = h.make_git_fixture()
		f.a, f.b = f.root .. "/a.txt", f.root .. "/b.txt"
		h.write_file(f.a, lines(20))
		h.write_file(f.b, "second\n")
		h.exec({ "git", "add", "a.txt", "b.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "files" }, f.root)
		h.write_file(f.a, lines(20, 16))
		h.write_file(f.b, "changed\n")
		vim.cmd("tabnew")
		vim.cmd("silent! tabonly!")
		return f
	end
	local function open(f)
		local s = assert(compare.open({ path = f.root, base = "HEAD" }))
		ready(s)
		assert(s.shown_item.relpath == "a.txt" and s.worktree, "a.txt is not an editable working buffer")
		return s
	end
	-- Fold starts at every level, closed folds, and the fold options.
	local function folds(win)
		return api.nvim_win_call(win, function()
			local enabled = vim.wo.foldenable
			vim.wo.foldenable = true
			local starts, closed = {}, {}
			for line = 1, api.nvim_buf_line_count(0) do
				local level = vim.fn.foldlevel(line)
				if level > 0 and (line == 1 or vim.fn.foldlevel(line - 1) < level) then
					starts[#starts + 1] = line .. ":" .. level
				end
				if vim.fn.foldclosed(line) == line then
					closed[#closed + 1] = line
				end
			end
			vim.wo.foldenable = enabled
			return string.format(
				"fdm=%s fen=%s fdl=%d starts=%s closed=%s",
				vim.wo.foldmethod,
				tostring(enabled),
				vim.wo.foldlevel,
				table.concat(starts, ","),
				table.concat(closed, ",")
			)
		end)
	end
	-- Nested manual folds, one of them open, in the current window.
	local function make_folds()
		vim.wo.foldmethod = "manual"
		vim.cmd("4,5fold")
		vim.cmd("3,8fold")
		vim.cmd("normal! 3Gzo")
		vim.cmd("11,13fold")
		vim.cmd("normal! gg")
	end
	local cases = {}

	-- With the :help :loadview auto-view autocommands, reviewing a file in
	-- Compare neither loads its view into a pane nor saves the pane's view.
	cases[#cases + 1] = {
		"test_core_compare_keeps_user_views_and_folds",
		function()
			local f = fixture()
			local viewdir = h.tempdir() .. "/views"
			local saved_viewdir, saved_viewoptions = vim.o.viewdir, vim.o.viewoptions
			vim.o.viewdir = viewdir
			vim.o.viewoptions = "folds,cursor,curdir"
			local group = api.nvim_create_augroup("lazyvcs_test_user_views", { clear = true })
			api.nvim_create_autocmd("BufWinLeave", { group = group, pattern = "*.txt", command = "silent! mkview" })
			api.nvim_create_autocmd("BufWinEnter", { group = group, pattern = "*.txt", command = "silent! loadview" })
			local ok, err = xpcall(function()
				vim.cmd.edit(vim.fn.fnameescape(f.a))
				local win = api.nvim_get_current_win()
				make_folds()
				local expected = folds(win)
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local view = vim.fn.glob(viewdir .. "/*a.txt*")
				assert(view ~= "", "the auto-view autocommands saved no view")
				local saved = vim.fn.readfile(view)
				local s = open(f)
				assert(not folds(s.rightwin):find("starts=3:1", 1, true), "the pane loaded the user's view")
				navigate(s, "next", "b.txt")
				assert(table.concat(vim.fn.readfile(view), "\n") == table.concat(saved, "\n"), "Compare saved a view")
				compare.close(s)
				api.nvim_set_current_win(win)
				vim.cmd.edit(vim.fn.fnameescape(f.a))
				assert(folds(win) == expected, "the user's view lost its folds: " .. folds(win) .. " ~= " .. expected)
			end, debug.traceback)
			api.nvim_del_augroup_by_id(group)
			vim.o.viewdir, vim.o.viewoptions = saved_viewdir, saved_viewoptions
			assert(ok, err)
		end,
	}

	-- A window without a record of its own gets the user's folds back, whether
	-- the newest record is a closed window's or Compare's pane's.
	for _, closing in ipairs({ "navigate", "close", "quit", "tabclose" }) do
		cases[#cases + 1] = {
			"test_core_compare_keeps_closed_window_folds_after_" .. closing,
			function()
				local f = fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				vim.cmd("split " .. vim.fn.fnameescape(f.a))
				make_folds()
				vim.wo.foldenable = false
				local expected = folds(api.nvim_get_current_win())
				vim.cmd("close")
				local s = open(f)
				if closing == "navigate" then
					navigate(s, "next", "b.txt")
				end
				if closing == "quit" then
					-- The user quits the pane; Compare closes the rest.
					api.nvim_set_current_win(s.rightwin)
					vim.cmd("quit")
					ctx.wait_for(function()
						return s.closed
					end, "Compare did not close", 3000)
				elseif closing == "tabclose" then
					vim.cmd("tabclose " .. api.nvim_tabpage_get_number(s.tab))
				end
				compare.close(s)
				vim.cmd("tabnew")
				vim.cmd.buffer(vim.fn.bufnr(f.a))
				local win = api.nvim_get_current_win()
				assert(
					folds(win) == expected,
					"a new window lost the user's folds: " .. folds(win) .. " ~= " .. expected
				)
				assert(not vim.wo[win].diff and not vim.wo[win].scrollbind, "a new window inherited diff mode")
				vim.cmd("tabclose")
			end,
		}
	end

	-- Indent folds keep their level and the folds the user opened and closed.
	cases[#cases + 1] = {
		"test_core_compare_keeps_indent_fold_state",
		function()
			local f = fixture()
			local text = {}
			for index = 1, 20 do
				text[index] = string.rep("  ", index % 4) .. "line " .. index
			end
			h.write_file(f.a, table.concat(text, "\n") .. "\n")
			h.exec({ "git", "add", "a.txt" }, f.root)
			h.exec({ "git", "commit", "-m", "indent" }, f.root)
			text[16] = text[16] .. " changed"
			h.write_file(f.a, table.concat(text, "\n") .. "\n")
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			vim.cmd("split " .. vim.fn.fnameescape(f.a))
			vim.bo.shiftwidth = 2
			vim.wo.foldmethod = "indent"
			vim.wo.foldlevel = 1
			vim.cmd("normal! 3Gzc")
			vim.cmd("normal! 6Gzo")
			local expected = folds(api.nvim_get_current_win())
			vim.cmd("close")
			local s = open(f)
			navigate(s, "next", "b.txt")
			compare.close(s)
			vim.cmd("tabnew")
			vim.cmd.buffer(vim.fn.bufnr(f.a))
			local win = api.nvim_get_current_win()
			assert(
				folds(win) == expected,
				"a new window lost the user's fold state: " .. folds(win) .. " ~= " .. expected
			)
			vim.cmd("tabclose")
		end,
	}

	-- A split of the pane is the user's window on the buffer, with their state.
	cases[#cases + 1] = {
		"test_core_compare_pane_split_gets_user_folds",
		function()
			local f = fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.a))
			make_folds()
			vim.cmd("setlocal nofoldenable")
			local expected = folds(api.nvim_get_current_win())
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local s = open(f)
			api.nvim_set_current_win(s.rightwin)
			vim.cmd("split")
			local split = api.nvim_get_current_win()
			assert(not vim.wo[split].diff and not vim.wo[split].scrollbind, "the split kept diff mode")
			assert(folds(split) == expected, "the split lost the user's folds: " .. folds(split) .. " ~= " .. expected)
			api.nvim_win_close(split, true)
			compare.close(s)
		end,
	}

	-- Closing Compare leaves a picker preview in a pane as it is.
	cases[#cases + 1] = {
		"test_core_compare_close_keeps_preview_folds",
		function()
			local f = fixture()
			local other = h.tempdir() .. "/other.txt"
			h.write_file(other, lines(20))
			vim.cmd.edit(vim.fn.fnameescape(other))
			make_folds()
			local expected = folds(api.nvim_get_current_win())
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local s = open(f)
			-- A picker previews other.txt in the unfocused right pane.
			api.nvim_set_current_win(s.sidewin)
			api.nvim_win_set_buf(s.rightwin, vim.fn.bufnr(other))
			assert(folds(s.rightwin) == expected, "the preview did not get the user's folds")
			compare.close(s)
			vim.cmd("tabnew")
			vim.cmd.buffer(vim.fn.bufnr(other))
			local win = api.nvim_get_current_win()
			assert(folds(win) == expected, "closing Compare deleted the preview's folds: " .. folds(win))
			vim.cmd("tabclose")
		end,
	}

	-- Closing Compare keeps the winbar, folds, and diff of windows it does not own.
	cases[#cases + 1] = {
		"test_core_compare_close_keeps_unrelated_window_state",
		function()
			local f = fixture()
			local dir = h.tempdir()
			local peers = {}
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local origin = api.nvim_get_current_win()
			for index, name in ipairs({ "left.txt", "right.txt" }) do
				h.write_file(dir .. "/" .. name, index == 1 and "one\n" or "two\n")
				vim.cmd("botright vsplit " .. vim.fn.fnameescape(dir .. "/" .. name))
				vim.cmd("diffthis")
				util.set_win_option(0, "winbar", "PEER")
				peers[#peers + 1] = api.nvim_get_current_win()
			end
			api.nvim_set_current_win(origin)
			local other = dir .. "/other.txt"
			h.write_file(other, lines(20))
			local s = open(f)
			api.nvim_set_current_win(s.sidewin)
			vim.cmd("split " .. vim.fn.fnameescape(other))
			make_folds()
			util.set_win_option(0, "winbar", "MINE")
			local expected = folds(api.nvim_get_current_win())
			compare.close(s)
			for _, win in ipairs(peers) do
				assert(vim.wo[win].diff and vim.wo[win].scrollbind, "closing Compare turned off the user's diff")
				assert(util.get_win_option(win, "winbar") == "PEER", "closing Compare changed the user's winbar")
			end
			vim.cmd("tabnew")
			vim.cmd.buffer(vim.fn.bufnr(other))
			local win = api.nvim_get_current_win()
			assert(folds(win) == expected, "closing Compare deleted the user's folds: " .. folds(win))
			assert(util.get_win_option(win, "winbar") == "MINE", "closing Compare cleared the user's winbar")
			vim.cmd("tabclose")
			vim.cmd("diffoff!")
		end,
	}
	return cases
end
