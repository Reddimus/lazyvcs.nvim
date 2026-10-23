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
		-- Hidden diff folds would close on zi; a plain window has none.
		local closed = api.nvim_win_call(win, function()
			local enabled = vim.wo.foldenable
			vim.cmd("normal! zi")
			local found = {}
			for line = 1, api.nvim_buf_line_count(0) do
				if vim.fn.foldclosed(line) ~= -1 then
					found[#found + 1] = line
				end
			end
			vim.wo.foldenable = enabled
			return found
		end)
		assert(#closed == 0, context .. " kept Compare's diff folds: " .. vim.inspect(closed))
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
	local function plugin_fixture(from, scenario)
		local repo = vim.fs.normalize(
			vim.fn.fnamemodify(assert(vim.api.nvim_get_runtime_file("lua/lazyvcs/compat.lua", false)[1]), ":p:h:h:h")
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
			scenario,
		}, { text = true }):wait(60000)
		assert(result.code == 0, "nested editor failed: " .. tostring(result.stderr))
		local values = vim.json.decode(table.concat(vim.fn.readfile(output), "\n"))
		vim.fn.delete(output)
		assert(not values.error, values.error)
		assert(values.pane.diff and values.pane.scrollbind, "the Compare pane lost its diff")
		return values
	end
	local function assert_copied_clean(v, step)
		assert(
			not v.diff and not v.scrollbind and not v.cursorbind and v.foldmethod ~= "diff" and v.foldcolumn == "0",
			step .. " inherited Compare pane options: " .. vim.inspect(v)
		)
		assert(v.winbar == "%f", step .. " lost the plugin winbar: " .. vim.inspect(v.winbar))
	end
	for _, variant in ipairs({ { "side", "edit" }, { "right", "edit" }, { "side", "peer" } }) do
		local from, scenario = variant[1], variant[2]
		cases[#cases + 1] = {
			"test_core_compare_worktree_edit_from_"
				.. from
				.. (scenario == "peer" and "_beside_user_diff" or "")
				.. "_survives_winbar_plugins",
			function()
				local values = plugin_fixture(from, scenario)
				assert(values.edit.origin, "edit did not use the editor")
				for _, step in ipairs({ "edit", "closed", "split" }) do
					assert_copied_clean(values[step], step)
				end
				if scenario == "peer" then
					assert(vim.deep_equal(values.peers, { true, true }), "edit changed the user's diff pair")
				end
			end,
		}
	end
	-- Floats copy the pane's options too, minimal floats included on Neovim 0.11.
	for _, scenario in ipairs({ "float", "minimal" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_" .. scenario .. "_float_copy_survives_winbar_plugins",
			function()
				assert_copied_clean(plugin_fixture("right", scenario).target, "new window")
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_worktree_keeps_single_window_user_diff_after_close",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			local f = h.make_git_fixture()
			h.write_file(f.root .. "/a.txt", "first\n")
			h.write_file(f.root .. "/b.txt", "second\n")
			-- An existing buffer, so it survives Compare closing.
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/a.txt"))
			local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			assert(s.right == buf, "Compare did not show the existing buffer")
			compare.close(s)
			api.nvim_set_current_win(origin)
			vim.cmd.buffer(buf)
			-- A deliberate diff with no peer window in this tab.
			vim.cmd("diffthis")
			assert(vim.wo[origin].diff, "diffthis failed")
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/b.txt"))
			vim.cmd.buffer(buf)
			assert(vim.wo[origin].diff, "returning to the buffer turned off the user's diff")
			vim.cmd("diffoff")
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_keeps_single_window_user_diff_while_open",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			local f = h.make_git_fixture()
			h.write_file(f.root .. "/a.txt", "first\n")
			h.write_file(f.root .. "/b.txt", "second\n")
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/a.txt"))
			local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
			-- A deliberate diff with no peer window, kept while Compare shows the buffer.
			vim.cmd("diffthis")
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			assert(s.right == buf and vim.wo[s.rightwin].diff, "Compare did not show the existing buffer")
			api.nvim_set_current_win(origin)
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/b.txt"))
			vim.cmd.buffer(buf)
			assert(vim.wo[origin].diff, "returning to the buffer turned off the user's diff")
			compare.close(s)
			assert(vim.wo[origin].diff, "closing Compare turned off the user's diff")
			vim.cmd("diffoff")
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_reloading_keeps_user_diff",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
			local f = h.make_git_fixture()
			h.write_file(f.root .. "/z.txt", "later\n")
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			assert(s.right == buf, "Compare did not show the editor's buffer")
			-- The pane leaves the buffer and returns; the editor never switches.
			navigate(s, "next", "z.txt")
			navigate(s, "prev", "sample.txt")
			api.nvim_set_current_win(origin)
			vim.cmd("diffthis")
			vim.cmd.edit()
			assert(vim.wo[origin].diff, "reloading the buffer turned off the user's diff")
			assert(vim.wo[origin].scrollbind, "reloading the buffer cleared the user's diff binding")
			compare.close(s)
			vim.cmd("diffoff")
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_marker_reset_keeps_user_options",
		function()
			local _, s = fixture()
			navigate(s, "next", "b.txt")
			navigate(s, "prev", "a.txt")
			local pane = s.rightwin
			api.nvim_set_current_win(pane)
			-- The user's own values in the pane, set while it is marked.
			util.set_win_option(pane, "winhighlight", "Normal:NormalFloat")
			util.set_win_option(pane, "foldnestmax", 3)
			util.set_win_option(pane, "foldignore", "#;")
			assert(require("lazyvcs.compare_marker").marked(pane), "the pane lost its mark")
			vim.cmd("split")
			local copy = api.nvim_get_current_win()
			assert(not vim.wo[copy].diff and not vim.wo[copy].scrollbind, "copied pane options survived")
			local value = util.get_win_option(copy, "winhighlight")
			assert(value == "Normal:NormalFloat", "marker cleanup changed user highlights: " .. vim.inspect(value))
			local depth = util.get_win_option(copy, "foldnestmax")
			assert(depth == 3, "marker cleanup changed the fold depth: " .. vim.inspect(depth))
			local ignored = util.get_win_option(copy, "foldignore")
			assert(ignored == "#;", "marker cleanup changed foldignore: " .. vim.inspect(ignored))
			api.nvim_win_close(copy, true)
			compare.close(s)
		end,
	}
	-- Same-buffer windows copy a pane's options without BufWinEnter.
	local creators = {
		split = function()
			vim.cmd("split")
			return api.nvim_get_current_win()
		end,
		tab_split = function()
			vim.cmd("tab split")
			return api.nvim_get_current_win()
		end,
		float = function()
			return api.nvim_open_win(0, true, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
		end,
		unfocused_float = function()
			return api.nvim_open_win(0, false, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
		end,
	}
	for name, create in pairs(creators) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_pane_" .. name .. "_drops_pane_options",
			function()
				local _, s = fixture()
				navigate(s, "next", "b.txt")
				navigate(s, "prev", "a.txt")
				local buf = s.right
				api.nvim_set_current_win(s.rightwin)
				local win = create()
				assert(api.nvim_win_get_buf(win) == buf)
				assert(not require("lazyvcs.compare_marker").marked(win), "new window kept the pane marker")
				assert_plain(win, name)
				assert(vim.wo[s.rightwin].diff and vim.wo[s.rightwin].scrollbind, "the Compare pane lost its diff")
				if api.nvim_win_is_valid(win) then
					api.nvim_win_close(win, true)
				end
				compare.close(s)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_worktree_pane_tab_split_keeps_later_user_diff",
		function()
			local _, s = fixture()
			navigate(s, "next", "b.txt")
			navigate(s, "prev", "a.txt")
			api.nvim_set_current_win(s.rightwin)
			vim.cmd("tab split")
			local win = api.nvim_get_current_win()
			-- The user replaces the copied state with a diff of their own, then reloads.
			vim.cmd("diffoff")
			vim.cmd("diffthis")
			vim.cmd.edit()
			assert(vim.wo[win].diff, "reloading turned off the user's diff")
			vim.cmd("diffoff")
			api.nvim_win_close(win, true)
			compare.close(s)
		end,
	}
	return cases
end
