-- Neovim copies a buffer's last window options into a window that has none
-- saved for it. Editable Compare panes must not leak diff state into editors.
return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, util = require("lazyvcs.compare"), require("lazyvcs.util")
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job and not s.job
		end, "editable Compare did not load", 15000)
	end
	local function fixture()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
		local f = h.make_git_fixture()
		h.write_file(f.root .. "/a.txt", "first\n")
		h.write_file(f.root .. "/b.txt", "second\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local origin = api.nvim_get_current_win()
		local s = assert(compare.open({ path = f.root, base = "HEAD" }))
		ready(s)
		assert(s.shown_item.relpath == "a.txt" and s.worktree, "a.txt is not an editable working buffer")
		return f, s, origin
	end
	local function navigate(s, direction, relpath)
		compare.navigate_file(direction, 1)
		ctx.wait_for(function()
			return s.shown_item and s.shown_item.relpath == relpath and not s.preview_job and s.preview_result
		end, "Compare did not show " .. relpath, 15000)
	end
	local function assert_plain(win, context)
		local values = util.capture_win_options(win, {
			"diff",
			"scrollbind",
			"cursorbind",
			"foldmethod",
			"foldcolumn",
			"winbar",
		})
		assert(
			not values.diff
				and not values.scrollbind
				and not values.cursorbind
				and values.foldmethod ~= "diff"
				and values.foldcolumn == "0"
				and not tostring(values.winbar):find("WORKTREE", 1, true),
			context .. " inherited Compare pane options: " .. vim.inspect(values)
		)
	end
	local cases = {}
	for _, from in ipairs({ "side", "right" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_edit_from_" .. from .. "_keeps_editor_options",
			function()
				local f, s, origin = fixture()
				-- Revisiting a file gives its pane a saved window-option record.
				navigate(s, "next", "b.txt")
				navigate(s, "prev", "a.txt")
				local buf = s.right
				api.nvim_set_current_win(from == "side" and s.sidewin or s.rightwin)
				s.actions.edit()
				local editor = api.nvim_get_current_win()
				assert(editor == origin and api.nvim_win_get_buf(editor) == buf, "edit did not use the editor")
				assert_plain(editor, "edit window")
				assert(vim.wo[s.rightwin].diff and vim.wo[s.rightwin].scrollbind, "edit changed the Compare pane")
				compare.close(s)
				assert_plain(editor, "edit window after close")
				vim.cmd("vsplit")
				vim.cmd.buffer(buf)
				assert_plain(api.nvim_get_current_win(), "new split")
				vim.cmd.close()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/a.txt"))
				assert_plain(editor, "editor after :edit")
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_worktree_released_buffer_keeps_editor_options",
		function()
			local f, s, origin = fixture()
			local buf = s.right
			api.nvim_set_current_win(s.rightwin)
			api.nvim_buf_set_lines(buf, 0, -1, false, { "edited in compare" })
			vim.wait(50)
			vim.cmd.write()
			navigate(s, "next", "b.txt")
			assert(api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted, "saved buffer was not retained")
			compare.close(s)
			api.nvim_set_current_win(origin)
			vim.cmd("vsplit")
			vim.cmd.buffer(buf)
			assert_plain(api.nvim_get_current_win(), "new split")
			vim.cmd.close()
			api.nvim_set_current_win(origin)
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/a.txt"))
			assert(api.nvim_get_current_buf() == buf)
			assert_plain(origin, "editor after :edit")
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_picker_route_keeps_editor_options",
		function()
			local f, s, origin = fixture()
			local buf = s.right
			api.nvim_set_current_win(s.rightwin)
			api.nvim_buf_set_lines(buf, 0, -1, false, { "keep this buffer" })
			vim.wait(50)
			vim.cmd.write()
			navigate(s, "next", "b.txt")
			local shown = s.right
			-- A file picker replaces the focused pane; Compare routes the file.
			api.nvim_set_current_win(s.rightwin)
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/a.txt"))
			ctx.wait_for(function()
				return api.nvim_get_current_win() == origin and api.nvim_win_get_buf(s.rightwin) == shown
			end, "picker selection was not routed to the editor", 15000)
			assert(api.nvim_win_get_buf(origin) == buf)
			assert_plain(origin, "routed editor")
			compare.close(s)
			assert_plain(origin, "routed editor after close")
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_keeps_user_diff_windows",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			local f = h.make_git_fixture()
			h.write_file(f.root .. "/a.txt", "first\n")
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/a.txt"))
			local buf, mine = api.nvim_get_current_buf(), api.nvim_get_current_win()
			vim.cmd("diffthis")
			vim.cmd("vsplit " .. vim.fn.fnameescape(f.file))
			local other = api.nvim_get_current_win()
			vim.cmd("diffthis")
			api.nvim_set_current_win(mine)
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			assert(s.right == buf, "Compare did not borrow the user's buffer")
			-- The user's own diff window returns to the buffer Compare displays.
			api.nvim_set_current_win(mine)
			vim.cmd.buffer(api.nvim_win_get_buf(other))
			vim.cmd.buffer(buf)
			assert(vim.wo[mine].diff and vim.wo[other].diff, "Compare turned off the user's diff")
			compare.close(s)
			assert(vim.wo[mine].diff and vim.wo[other].diff, "closing Compare turned off the user's diff")
			vim.cmd("diffoff!")
		end,
	}
	-- Run in a fresh editor so the plugin's BufWinEnter handler precedes LazyVCS.
	for _, from in ipairs({ "side", "right" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_edit_from_" .. from .. "_survives_winbar_plugins",
			function()
				local repo = vim.fs.normalize(
					vim.fn.fnamemodify(
						assert(vim.api.nvim_get_runtime_file("lua/lazyvcs/compat.lua", false)[1]),
						":p:h:h:h"
					)
				)
				local output = vim.fs.normalize(vim.fn.tempname())
				local result = vim.system({
					vim.v.progpath,
					"--headless",
					"-u",
					"NONE",
					"-i",
					"NONE",
					"-l",
					repo .. "/tests/fixtures/compare_winbar_plugin.lua",
					repo,
					output,
					from,
				}, { text = true }):wait(60000)
				assert(result.code == 0, "nested editor failed: " .. tostring(result.stderr))
				local values = vim.json.decode(table.concat(vim.fn.readfile(output), "\n"))
				vim.fn.delete(output)
				assert(not values.error, values.error)
				assert(values.edit.origin, "edit did not use the editor")
				assert(values.pane.diff and values.pane.scrollbind, "edit changed the Compare pane")
				for _, step in ipairs({ "edit", "closed", "split" }) do
					local v = values[step]
					assert(
						not v.diff
							and not v.scrollbind
							and not v.cursorbind
							and v.foldmethod ~= "diff"
							and v.foldcolumn == "0",
						step .. " inherited Compare pane options: " .. vim.inspect(v)
					)
					assert(v.winbar == "%f", step .. " lost the plugin winbar: " .. vim.inspect(v.winbar))
				end
			end,
		}
	end
	return cases
end
