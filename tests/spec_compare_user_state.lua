-- Compare touches only its own panes: windows it does not own, a picker preview
-- in a pane, and folds in other windows on a pane's buffer keep their state.
return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, util = require("lazyvcs.compare"), require("lazyvcs.util")
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job and not s.job
		end, "Compare did not load", 15000)
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
	local function levels(win)
		return api.nvim_win_call(win, function()
			vim.cmd("normal! zx")
			local out = {}
			for line = 1, api.nvim_buf_line_count(0) do
				out[#out + 1] = vim.fn.foldlevel(line)
			end
			return table.concat(out, "")
		end)
	end
	local code = {
		"local function a()",
		"  if x then",
		"    if y then",
		"      return 1",
		"    end",
		"  end",
		"end",
		"local t = {",
		"  b = function()",
		"    return 2",
		"  end,",
		"}",
	}
	local cases = {}

	-- Showing a buffer in a pane changes no fold in a window that shares it.
	for name, method in pairs({
		treesitter = { "expr", "v:lua.vim.treesitter.foldexpr()" },
		indent = { "indent" },
		expr = { "expr", "indent(v:lnum)/shiftwidth()" },
	}) do
		cases[#cases + 1] = {
			"test_core_compare_keeps_shared_buffer_folds_" .. name,
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/code.lua", table.concat(code, "\n") .. "\n")
				h.exec({ "git", "add", "code.lua" }, f.root)
				h.exec({ "git", "commit", "-m", "code" }, f.root)
				code[4] = "      return 10"
				h.write_file(f.root .. "/code.lua", table.concat(code, "\n") .. "\n")
				code[4] = "      return 1"
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/code.lua"))
				local editor, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
				vim.bo[buf].shiftwidth = 2
				vim.wo[editor].foldmethod = method[1]
				if method[2] then
					vim.wo[editor].foldexpr = method[2]
				end
				vim.wo[editor].foldnestmax = 1
				if name == "treesitter" then
					vim.treesitter.start(buf, "lua")
				end
				local before = levels(editor)
				assert(before:find("1", 1, true), "the editor has no folds to compare")
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ready(s)
				assert(s.right == buf, "Compare did not show the editor's buffer")
				vim.wait(50)
				assert(levels(editor) == before, name .. " folds changed in the editor: " .. levels(editor))
				compare.close(s)
				assert(levels(editor) == before, name .. " folds changed after Compare closed")
				if name == "treesitter" then
					vim.treesitter.stop(buf)
				end
			end,
		}
	end

	-- Closing Compare touches only its panes.
	cases[#cases + 1] = {
		"test_core_compare_close_keeps_folds_in_unrelated_windows",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			local f = h.make_git_fixture()
			local lines = {}
			for index = 1, 20 do
				lines[index] = "other " .. index
			end
			local other = h.tempdir() .. "/other.txt"
			h.write_file(other, table.concat(lines, "\n") .. "\n")
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local origin = api.nvim_get_current_win()
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			-- An ordinary window in Compare's tab with folds of its own.
			api.nvim_set_current_win(s.sidewin)
			vim.cmd("split " .. vim.fn.fnameescape(other))
			local win = api.nvim_get_current_win()
			vim.wo[win].foldmethod = "manual"
			vim.cmd("3,6fold")
			vim.cmd("10,12fold")
			assert(vim.fn.foldclosed(3) == 3, "the user's fold was not created")
			compare.close(s)
			api.nvim_set_current_win(origin)
			vim.cmd.buffer(vim.fn.bufnr(other))
			assert(vim.fn.foldlevel(4) == 1 and vim.fn.foldlevel(11) == 1, "closing Compare deleted the user's folds")
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
	-- Compare never takes a user's window for one of its own: fold limits of
	-- any size, a diff the user started, and windows split from theirs stay.
	for _, depth in ipairs({ 100, 1000 }) do
		cases[#cases + 1] = {
			"test_core_compare_leaves_user_fold_depth_" .. depth,
			function()
				local f = fixture()
				local text = {}
				for index = 1, 8 do
					text[index] = string.rep("  ", index % 4) .. "line " .. index
				end
				local other = h.tempdir() .. "/other.txt"
				h.write_file(other, table.concat(text, "\n") .. "\n")
				vim.cmd.edit(vim.fn.fnameescape(other))
				local win = api.nvim_get_current_win()
				vim.bo.shiftwidth = 2
				util.set_win_options(win, { foldmethod = "indent", foldnestmax = depth })
				local before = levels(win)
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local s = open(f)
				compare.close(s)
				api.nvim_set_current_win(win)
				vim.cmd("split")
				local split = api.nvim_get_current_win()
				for _, w in ipairs({ win, split }) do
					assert(util.get_win_option(w, "foldnestmax") == depth, "Compare changed the user's fold depth")
					assert(levels(w) == before, "Compare changed the user's folds: " .. levels(w))
				end
				api.nvim_win_close(split, true)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_leaves_user_diff_that_enters_compare_buffer",
		function()
			local f = fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local win = api.nvim_get_current_win()
			local s = open(f)
			-- The pane leaves a.txt and returns, so it has a record for it.
			compare.navigate_file("next", 1)
			ctx.wait_for(function()
				return s.shown_item.relpath == "b.txt" and not s.preview_job
			end, "Compare did not show b.txt", 15000)
			compare.navigate_file("prev", 1)
			ctx.wait_for(function()
				return s.shown_item.relpath == "a.txt" and not s.preview_job
			end, "Compare did not show a.txt", 15000)
			-- The user diffs another file, then opens the file Compare shows there.
			api.nvim_set_current_win(win)
			vim.cmd("diffthis")
			vim.cmd.edit(vim.fn.fnameescape(f.a))
			assert(vim.wo[win].diff, "Compare turned off the user's diff")
			compare.close(s)
			assert(vim.wo[win].diff, "closing Compare turned off the user's diff")
			vim.cmd("diffoff!")
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_leaves_user_diff_in_explicit_split_target",
		function()
			local f = fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.a))
			local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
			vim.cmd("diffthis")
			local s = open(f)
			assert(s.right == buf, "Compare did not show the user's buffer")
			-- From the focused pane, a plugin splits the user's window.
			api.nvim_set_current_win(s.rightwin)
			local split = api.nvim_open_win(buf, false, { win = win, split = "right" })
			assert(vim.wo[split].diff, "Compare turned off the diff the split took from the user's window")
			api.nvim_win_close(split, true)
			compare.close(s)
			assert(vim.wo[win].diff, "closing Compare turned off the user's diff")
			api.nvim_win_call(win, function()
				vim.cmd("diffoff")
			end)
		end,
	}
	-- Compare writes no option of its own into a pane's 'foldignore', locally or
	-- globally, so splits after :set foldignore+= and -= keep the user's value.
	cases[#cases + 1] = {
		"test_core_compare_pane_foldignore_stays_the_users",
		function()
			local f = fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local s = open(f)
			local before = vim.api.nvim_get_option_value("foldignore", { win = s.rightwin, scope = "global" })
			api.nvim_set_current_win(s.rightwin)
			vim.cmd("set foldignore+=!")
			vim.cmd("set foldignore-=!")
			vim.cmd("split")
			local split = api.nvim_get_current_win()
			for _, scope in ipairs({ "local", "global" }) do
				local value = api.nvim_get_option_value("foldignore", { win = split, scope = scope })
				assert(value == before, scope .. " foldignore is not the user's: " .. vim.inspect(value))
			end
			api.nvim_win_close(split, true)
			compare.close(s)
		end,
	}
	-- The edit actions reuse a window that already shows the file; its diff is
	-- the user's or a live diff's, not something the edit brought in.
	cases[#cases + 1] = {
		"test_core_compare_edit_keeps_user_diff_in_editor",
		function()
			local f = fixture()
			local peer_file = h.tempdir() .. "/peer.txt"
			h.write_file(peer_file, lines(20, 5))
			vim.cmd.edit(vim.fn.fnameescape(f.a))
			local editor, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
			vim.cmd("diffthis")
			vim.cmd("vsplit " .. vim.fn.fnameescape(peer_file))
			local peer = api.nvim_get_current_win()
			vim.cmd("diffthis")
			api.nvim_set_current_win(editor)
			local s = open(f)
			assert(s.right == buf, "Compare did not show the editor's buffer")
			for _, from in ipairs({ s.rightwin, s.sidewin }) do
				api.nvim_set_current_tabpage(s.tab)
				api.nvim_set_current_win(from)
				s.actions.edit()
				assert(api.nvim_get_current_win() == editor, "edit did not use the editor")
				for _, win in ipairs({ editor, peer }) do
					assert(
						vim.wo[win].diff and vim.wo[win].scrollbind and vim.wo[win].cursorbind,
						"the edit action turned off the user's diff"
					)
				end
			end
			compare.close(s)
			vim.cmd("diffoff!")
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_edit_keeps_live_diff_in_editor",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
			local f = h.make_git_fixture()
			vim.cmd("tabnew")
			vim.cmd("silent! tabonly!")
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local buf = api.nvim_get_current_buf()
			actions.open()
			ctx.wait_for(function()
				local live = state.get(buf)
				return live and live.phase == "active"
			end, "live diff did not open", 15000)
			local live = assert(state.get(buf))
			local editor = live.editable_win
			api.nvim_set_current_win(editor)
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ctx.wait_for(function()
				return s.preview_result and not s.preview_job and not s.job
			end, "Compare did not load", 15000)
			assert(s.right == buf, "Compare did not show the live diff's buffer")
			api.nvim_set_current_win(s.rightwin)
			s.actions.edit()
			assert(api.nvim_get_current_win() == editor, "edit did not use the live diff's window")
			assert(vim.wo[editor].diff and vim.wo[live.base_win].diff, "the edit action turned off the live diff")
			assert(state.for_window(editor) == live and live.phase == "active", "the live diff ended")
			compare.close(s)
			actions.close(live)
		end,
	}
	-- A window's own saved diff for the file comes back when the edit action
	-- opens the file there; the window never copied the pane.
	cases[#cases + 1] = {
		"test_core_compare_edit_keeps_saved_user_diff",
		function()
			local f = fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.a))
			local editor, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
			vim.cmd("diffthis")
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local s = open(f)
			assert(s.right == buf, "Compare did not show the user's buffer")
			api.nvim_set_current_win(s.rightwin)
			s.actions.edit()
			assert(api.nvim_get_current_win() == editor and api.nvim_win_get_buf(editor) == buf)
			assert(vim.wo[editor].diff and vim.wo[editor].scrollbind, "the edit action turned off the user's diff")
			compare.close(s)
			vim.cmd("diffoff!")
		end,
	}
	-- A copied pane's diff goes, and the window's own bindings stay.
	cases[#cases + 1] = {
		"test_core_compare_edit_keeps_editor_bindings",
		function()
			local f = fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local editor = api.nvim_get_current_win()
			util.set_win_options(editor, { scrollbind = true, cursorbind = true })
			local s = open(f)
			-- Revisiting a file gives its pane a saved record, so the editor copies the live pane.
			compare.navigate_file("next", 1)
			ctx.wait_for(function()
				return s.shown_item.relpath == "b.txt" and not s.preview_job
			end, "Compare did not show b.txt", 15000)
			compare.navigate_file("prev", 1)
			ctx.wait_for(function()
				return s.shown_item.relpath == "a.txt" and not s.preview_job
			end, "Compare did not show a.txt", 15000)
			api.nvim_set_current_win(s.rightwin)
			s.actions.edit()
			assert(api.nvim_get_current_win() == editor)
			local values = util.capture_win_options(editor, { "diff", "scrollbind", "cursorbind", "winbar" })
			assert(not values.diff, "the editor kept the pane's diff: " .. vim.inspect(values))
			assert(values.scrollbind and values.cursorbind, "the editor lost its own bindings: " .. vim.inspect(values))
			assert(not tostring(values.winbar):find("WORKTREE", 1, true), "the editor kept the pane label")
			compare.close(s)
			util.set_win_options(editor, { scrollbind = false, cursorbind = false })
		end,
	}
	-- The edit action's trial switch leaves nothing behind: no token in the
	-- editor's 'foldignore', locally, globally, or in later buffers, and the
	-- view of the file it leaves.
	local function copying_editor(f, prepare)
		local s = open(f)
		prepare()
		compare.navigate_file("next", 1)
		ctx.wait_for(function()
			return s.shown_item.relpath == "b.txt" and not s.preview_job
		end, "Compare did not show b.txt", 15000)
		compare.navigate_file("prev", 1)
		ctx.wait_for(function()
			return s.shown_item.relpath == "a.txt" and not s.preview_job
		end, "Compare did not show a.txt", 15000)
		api.nvim_set_current_win(s.rightwin)
		s.actions.edit()
		return s
	end
	cases[#cases + 1] = {
		"test_core_compare_edit_leaves_no_trial_token",
		function()
			local f = fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local editor = api.nvim_get_current_win()
			local group = api.nvim_create_augroup("lazyvcs_test_foldignore_append", { clear = true })
			local ok, err = xpcall(function()
				local s = copying_editor(f, function()
					api.nvim_create_autocmd("BufEnter", { group = group, command = "set foldignore+=!" })
				end)
				assert(api.nvim_get_current_win() == editor)
				-- A later, unrelated buffer in the editor folds by indent.
				vim.cmd.enew()
				api.nvim_buf_set_lines(0, 0, -1, false, { "x", "  a1", "    s2", "  a3", "x" })
				vim.bo.shiftwidth = 2
				-- Earlier specs may leave other fold limits in this window.
				util.set_win_options(0, { foldmethod = "indent", foldnestmax = 20, foldminlines = 1 })
				for _, scope in ipairs({ "local", "global" }) do
					local value = api.nvim_get_option_value("foldignore", { win = editor, scope = scope })
					assert(
						not value:find("\28", 1, true),
						scope .. " foldignore kept the token: " .. vim.inspect(value)
					)
				end
				local levels = {}
				for line = 1, 5 do
					levels[line] = vim.fn.foldlevel(line)
				end
				assert(
					table.concat(levels, "") == "01210",
					"the token changed indent folds: " .. table.concat(levels, "")
				)
				compare.close(s)
			end, debug.traceback)
			api.nvim_del_augroup_by_id(group)
			vim.cmd("set foldignore&")
			assert(ok, err)
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_edit_keeps_view_of_left_file",
		function()
			local f = fixture()
			local long = h.tempdir() .. "/long.txt"
			local text = {}
			for index = 1, 100 do
				text[index] = "line " .. index
			end
			h.write_file(long, table.concat(text, "\n") .. "\n")
			vim.cmd.edit(vim.fn.fnameescape(long))
			local editor, left = api.nvim_get_current_win(), api.nvim_get_current_buf()
			vim.wo.wrap = false
			vim.fn.winrestview({ lnum = 40, col = 0, topline = 35 })
			-- A view recorder, like the :mkview autocommands.
			local saved
			local group = api.nvim_create_augroup("lazyvcs_test_view_recorder", { clear = true })
			api.nvim_create_autocmd("BufWinLeave", {
				group = group,
				callback = function(args)
					if args.buf == left then
						saved = vim.fn.winsaveview()
					end
				end,
			})
			local ok, err = xpcall(function()
				local s = copying_editor(f, function() end)
				assert(api.nvim_get_current_win() == editor)
				assert(saved, "the recorder saw no view")
				assert(
					saved.lnum == 40 and saved.topline == 35,
					"the edit moved the left file's view: " .. vim.inspect(saved)
				)
				compare.close(s)
			end, debug.traceback)
			api.nvim_del_augroup_by_id(group)
			assert(ok, err)
		end,
	}
	-- The trial switch returns to the left file without applying
	-- 'foldlevelstart', so its fold level and open folds stay.
	cases[#cases + 1] = {
		"test_core_compare_edit_keeps_folds_of_left_file",
		function()
			local f = fixture()
			local nested = h.tempdir() .. "/nested.txt"
			local text = {}
			for index = 1, 30 do
				text[index] = string.rep("  ", index % 3) .. "line " .. index
			end
			h.write_file(nested, table.concat(text, "\n") .. "\n")
			local foldlevelstart = vim.o.foldlevelstart
			vim.o.foldlevelstart = 99
			vim.cmd.edit(vim.fn.fnameescape(nested))
			local editor, left = api.nvim_get_current_win(), api.nvim_get_current_buf()
			vim.bo.shiftwidth = 2
			vim.cmd("setlocal foldmethod=indent foldlevel=0")
			vim.cmd("normal! 5Gzo")
			local function folds()
				local closed = {}
				for line = 1, 30 do
					if vim.fn.foldclosed(line) == line then
						closed[#closed + 1] = line
					end
				end
				return vim.wo.foldlevel .. ":" .. table.concat(closed, ",")
			end
			local expected, saved = folds(), nil
			-- A view recorder, like the :mkview autocommands.
			local group = api.nvim_create_augroup("lazyvcs_test_fold_recorder", { clear = true })
			api.nvim_create_autocmd("BufWinLeave", {
				group = group,
				callback = function(args)
					if args.buf == left then
						saved = folds()
					end
				end,
			})
			local ok, err = xpcall(function()
				local s = copying_editor(f, function() end)
				assert(api.nvim_get_current_win() == editor)
				assert(
					saved == expected,
					"the edit changed the left file's folds: " .. tostring(saved) .. " ~= " .. expected
				)
				compare.close(s)
			end, debug.traceback)
			api.nvim_del_augroup_by_id(group)
			vim.o.foldlevelstart = foldlevelstart
			assert(ok, err)
		end,
	}
	return cases
end
