return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare = require("lazyvcs.compare")
	local sessions = {}
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job and not s.job and s.navigation and not s.navigation.pending
		end, "compare pending", 15000)
	end
	local function fixture()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
		local f = h.make_git_fixture()
		local base = {}
		for i = 1, 100 do
			base[i] = "line " .. i
		end
		for _, name in ipairs({ "a.txt", "b.txt" }) do
			h.write_file(f.root .. "/" .. name, table.concat(base, "\n") .. "\n")
		end
		h.exec({ "git", "add", "." }, f.root)
		h.exec({ "git", "commit", "-m", "review base" }, f.root)
		base[20], base[80] = "first change", "second change"
		for _, name in ipairs({ "a.txt", "b.txt" }) do
			h.write_file(f.root .. "/" .. name, table.concat(base, "\n") .. "\n")
		end
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local s = assert(compare.open({ path = f.root, base = "HEAD" }))
		sessions[#sessions + 1] = s
		ready(s)
		assert(s.shown_item.relpath == "a.txt" and s.worktree)
		return f, s
	end
	local function keys(value)
		api.nvim_feedkeys(api.nvim_replace_termcodes(value, true, false, true), "xt", false)
	end
	local function guard(fn)
		return function()
			local cwd = vim.fn.getcwd()
			local ok, err = xpcall(fn, debug.traceback)
			for _, s in ipairs(sessions) do
				pcall(compare.close, s)
			end
			sessions = {}
			vim.cmd.cd(vim.fn.fnameescape(cwd))
			h.cleanup()
			assert(ok, err)
		end
	end
	return {
		{
			"test_core_compare_a3_review_survives_edits_save_reload",
			guard(function()
				local _, s = fixture()
				api.nvim_set_current_win(s.rightwin)
				keys("]v]v")
				assert(s.navigation.reviewed and api.nvim_win_get_cursor(s.rightwin)[1] == 80)
				api.nvim_buf_set_lines(s.right, 9, 10, false, { "edited" })
				api.nvim_exec_autocmds("TextChanged", { buffer = s.right })
				ctx.wait_for(function()
					return s.navigation and not s.navigation.pending and #s.navigation.saved == 3
				end, "edit hunks absent", 15000)
				compare.action("files")
				keys("<CR>")
				assert(api.nvim_win_get_cursor(s.rightwin)[1] == 80, "review restarted after edit")
				vim.cmd.write()
				ctx.wait_for(function()
					return not s.worktree_list_job
				end, "list pending", 15000)
				ready(s)
				local generation = s.preview_generation
				compare.action("files")
				keys("<CR>")
				assert(api.nvim_win_get_cursor(s.rightwin)[1] == 80)
				assert(s.preview_generation == generation, "Enter reloaded displayed path")
				vim.cmd.edit()
				ready(s)
				compare.action("files")
				keys("<CR>")
				assert(api.nvim_win_get_cursor(s.rightwin)[1] == 80, "review restarted after reread")
			end),
		},
		{
			"test_core_compare_a3_native_edit_navigation_uses_current_tick",
			guard(function()
				local _, s = fixture()
				api.nvim_set_current_win(s.rightwin)
				api.nvim_win_set_cursor(s.rightwin, { 1, 0 })
				vim.cmd("normal! zR")
				keys("dd]v")
				assert(api.nvim_win_get_cursor(s.rightwin)[1] == 19, "jump used old hunk coordinates")
			end),
		},
		{
			"test_core_compare_a3_capture_rejection_keeps_real_buffer",
			guard(function()
				local _, s = fixture()
				local buf = s.right
				api.nvim_set_current_win(s.rightwin)
				api.nvim_buf_set_lines(buf, 0, 1, false, { "binary\0text" })
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				ctx.wait_for(function()
					return s.navigation and s.navigation.pending
				end, "capture did not fail", 15000)
				assert(
					s.worktree and s.right == buf and api.nvim_win_get_buf(s.rightwin) == buf and vim.bo[buf].modifiable
				)
				api.nvim_buf_set_lines(buf, 0, 1, false, { "line 1" })
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				ready(s)
				assert(#s.navigation.saved > 0)
			end),
		},
		{
			"test_core_compare_a3_picker_routes_same_worktree_position",
			guard(function()
				local _, s = fixture()
				for _, win in ipairs({ s.leftwin, s.sidewin }) do
					api.nvim_set_current_win(win)
					vim.cmd.edit(vim.fn.fnameescape(api.nvim_buf_get_name(s.right)))
					api.nvim_win_set_cursor(win, { 55, 2 })
					ctx.wait_for(function()
						return api.nvim_get_current_win() == s.rightwin
					end, "picker selection dropped", 15000)
					assert(vim.deep_equal(api.nvim_win_get_cursor(s.rightwin), { 55, 2 }))
					assert(api.nvim_win_get_buf(s.leftwin) == s.left and api.nvim_win_get_buf(s.sidewin) == s.sidebar)
				end
			end),
		},
		{
			"test_core_compare_a3_marks_survive_metadata_and_close",
			guard(function()
				local _, s = fixture()
				local buf = s.right
				api.nvim_set_current_win(s.rightwin)
				api.nvim_win_set_cursor(s.rightwin, { 45, 0 })
				keys("mamA")
				compare.action("metadata")
				compare.action("metadata")
				ready(s)
				assert(s.right == buf and api.nvim_buf_get_mark(buf, "a")[1] == 45)
				compare.close(s)
				assert(api.nvim_buf_is_valid(buf) and api.nvim_get_mark("A", {})[1] == 45)
			end),
		},
		{
			"test_core_compare_a3_teardown_keeps_other_tab_focus",
			guard(function()
				local _, s = fixture()
				vim.cmd.tabnew()
				local win = api.nvim_get_current_win()
				api.nvim_win_close(s.rightwin, true)
				ctx.wait_for(function()
					return s.closed
				end, "teardown pending")
				assert(api.nvim_get_current_win() == win, "teardown stole focus")
			end),
		},
		{
			"test_core_compare_a3_literal_tilde_api",
			guard(function()
				local f, s = fixture()
				compare.close(s)
				local parent = h.tempdir()
				local literal = parent .. "/~"
				h.exec({ "git", "clone", "--no-hardlinks", f.root, literal }, parent)
				h.write_file(literal .. "/a.txt", "literal path change\n")
				vim.cmd.cd(vim.fn.fnameescape(parent))
				for _, path in ipairs({ "~", "./~", parent .. "/~" }) do
					local next = assert(compare.open({ path = path, base = "HEAD" }))
					sessions[#sessions + 1] = next
					ready(next)
					assert(next.root == require("lazyvcs.util").canonical_path(literal), "literal tilde expanded")
					compare.close(next)
				end
			end),
		},
		{
			"test_core_compare_a3_swap_conflict_falls_back_then_edit_loads_real_file",
			guard(function()
				local f, first = fixture()
				compare.close(first)
				local path = f.root .. "/a.txt"
				local marker = f.root .. "/swap-owner-ready"
				local directory, updatecount, swapfile = vim.o.directory, vim.o.updatecount, vim.o.swapfile
				vim.o.updatecount = 200
				vim.o.swapfile = true
				vim.o.directory = f.root
				local child = vim.fn.jobstart({
					vim.v.progpath,
					"--headless",
					"-u",
					"NONE",
					"-i",
					"NONE",
					"--cmd",
					"set swapfile directory=" .. vim.fn.fnameescape(f.root),
					"-c",
					"edit " .. vim.fn.fnameescape(path),
					"-c",
					"preserve",
					"-c",
					"lua vim.fn.writefile({'ready'}," .. vim.inspect(marker) .. ")",
				})
				assert(child > 0)
				local ok, err = xpcall(function()
					ctx.wait_for(function()
						return vim.uv.fs_stat(marker) ~= nil
					end, "swap owner did not start", 15000)
					assert(vim.fn.jobwait({ child }, 0)[1] == -1)
					local s = assert(compare.open({ path = f.root, base = "HEAD" }))
					sessions[#sessions + 1] = s
					ready(s)
					assert(not s.worktree and not vim.bo[s.right].modifiable, "swap conflict did not choose snapshot")
					api.nvim_set_current_win(s.sidewin)
					local edited, edit_error = pcall(compare.action, "edit")
					assert(edited, edit_error)
					assert(api.nvim_buf_get_name(0) == path and api.nvim_buf_line_count(0) == 100)
					assert(vim.bo.modifiable and not vim.bo.readonly, "real file was not editable")
				end, debug.traceback)
				vim.fn.jobstop(child)
				vim.fn.jobwait({ child }, 5000)
				vim.o.directory, vim.o.updatecount, vim.o.swapfile = directory, updatecount, swapfile
				assert(ok, err)
			end),
		},
	}
end
