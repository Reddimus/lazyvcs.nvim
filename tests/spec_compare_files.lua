return function(ctx)
	local compare = require("lazyvcs.compare")
	local api = require("lazyvcs")
	local h = ctx.helpers
	local function keys(text)
		text = text:gsub("<leader>", function()
			return vim.g.mapleader or "\\"
		end)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end
	local function ready(s, path)
		ctx.wait_for(function()
			return s.preview_result and (not path or s.shown_item.relpath == path)
		end, "file preview did not load", 15000)
	end
	local function fixture(vcs)
		require("lazyvcs.commands").setup()
		local f = vcs == "svn" and h.make_svn_fixture() or h.make_git_fixture()
		local lines = {}
		for i = 1, 60 do
			lines[i] = "line " .. i
		end
		for _, path in ipairs({ "a.txt", "b.txt", "c.txt" }) do
			h.write_file(f.root .. "/" .. path, table.concat(lines, "\n") .. "\n")
		end
		h.exec(vcs == "svn" and { "svn", "add", "a.txt", "b.txt", "c.txt" } or { "git", "add", "." }, f.root)
		h.exec({ vcs, "commit", "-m", "file navigation base" }, f.root)
		if vcs == "svn" then
			h.exec({ "svn", "update" }, f.root)
		end
		lines[8], lines[30], lines[50] = "changed eight", "changed thirty", "changed fifty"
		for _, path in ipairs({ "a.txt", "b.txt", "c.txt" }) do
			h.write_file(f.root .. "/" .. path, table.concat(lines, "\n") .. "\n")
		end
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local s = assert(compare.open({ path = f.root, base = vcs == "svn" and h.file_url(f.repo) .. "@2" or "HEAD" }))
		ready(s)
		assert(#s.items == (vcs == "svn" and 4 or 3), vim.inspect(s.items))
		vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["a.txt"], 0 })
		if s.shown_item.relpath ~= "a.txt" then
			keys("P")
			ready(s, "a.txt")
		end
		return f, s
	end
	local function cursor(s, side)
		return vim.api.nvim_win_get_cursor(side == "base" and s.leftwin or s.rightwin)[1]
	end
	local function at(s, path, side, line)
		ready(s, path)
		assert(vim.api.nvim_get_current_win() == (side == "base" and s.leftwin or s.rightwin))
		assert(cursor(s, side) == line, "unexpected review line: " .. cursor(s, side))
		assert(s.rows[vim.api.nvim_win_get_cursor(s.sidewin)[1]].relpath == path)
		assert(not vim.bo[s.left].modifiable and not vim.bo[s.right].modifiable)
	end
	local function edited(s, path, line, column)
		ctx.wait_for(function()
			return vim.api.nvim_get_current_win() == s.origin_edit_win
				and vim.api.nvim_buf_get_name(0) == s.root .. "/" .. path
		end, "file did not open in the editing window")
		assert(vim.api.nvim_win_get_cursor(0)[1] == line)
		if column then
			assert(vim.api.nvim_win_get_cursor(0)[2] == column)
		end
		assert(s.shown_item.relpath == "a.txt", "file opening changed the review selection")
		assert(vim.api.nvim_win_get_buf(s.sidewin) == s.sidebar)
		assert(vim.api.nvim_win_get_buf(s.leftwin) == s.left)
		assert(vim.api.nvim_win_get_buf(s.rightwin) == s.right)
	end

	local cases = {}
	for _, vcs in ipairs({ "git", "svn" }) do
		cases[#cases + 1] = {
			"test_" .. vcs .. "_comparison_files_wrap_counts_restore_and_preserve_buffers",
			function()
				local f, s = fixture(vcs)
				local before = h.exec({ vcs, "diff" }, f.root)
				local listed = vim.fn.getbufinfo({ buflisted = 1 })
				keys("<CR>]v")
				at(s, "a.txt", "saved", 30)
				keys("]b")
				at(s, "b.txt", "saved", 8)
				keys("[b")
				at(s, "a.txt", "saved", 30)
				keys("]v")
				at(s, "a.txt", "saved", 50)
				keys("2]b")
				at(s, "c.txt", "saved", 8)
				vim.api.nvim_set_current_win(s.leftwin)
				keys(vcs == "svn" and "2]b" or "]b")
				at(s, "a.txt", "base", 50)
				keys(tostring(#s.items * 2 + (vcs == "svn" and 2 or 1)) .. "[b")
				at(s, "c.txt", "base", 8)
				vim.cmd("LazyVCS compare next")
				if vcs == "svn" then
					ready(s, ".")
					assert(vim.api.nvim_get_current_win() == s.leftwin and #s.navigation.saved == 0)
					vim.cmd("LazyVCS compare next")
				end
				at(s, "a.txt", "base", 50)
				assert(api.compare_prev(#s.items - 1))
				at(s, "b.txt", "base", 8)
				assert(h.exec({ vcs, "diff" }, f.root) == before)
				local after = vim.fn.getbufinfo({ buflisted = 1 })
				assert(#after == #listed)
				for i, info in ipairs(listed) do
					assert(after[i].bufnr == info.bufnr)
				end
				compare.close(s)
				assert(api.compare_next() == false)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_comparison_file_views_survive_sidebar_metadata_resize_and_refresh",
		function()
			local width = vim.o.columns
			local f, s = fixture("git")
			keys("<CR>]v<leader>vf")
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["b.txt"], 0 })
			keys("P")
			ready(s, "b.txt")
			keys("<CR>]v]v")
			at(s, "b.txt", "saved", 50)
			keys(":LazyVCS compare metadata<CR>[b")
			at(s, "a.txt", "saved", 30)
			keys("]b")
			at(s, "b.txt", "saved", 50)
			keys(":LazyVCS compare metadata<CR>")
			compare.refresh(s)
			ready(s)
			at(s, "b.txt", "saved", 50)
			vim.o.columns = 100
			vim.api.nvim_exec_autocmds("VimResized", {})
			keys("[b")
			at(s, "a.txt", "saved", 30)
			compare.refresh(s)
			ready(s)
			keys("]b")
			at(s, "b.txt", "saved", 50)
			h.write_file(f.root .. "/b.txt", "shortened\n")
			keys("[b]b")
			at(s, "b.txt", "saved", 1)
			h.exec({ "git", "restore", "c.txt" }, f.root)
			compare.refresh(s)
			ready(s)
			assert(#s.items == 2 and s.file_views["c.txt"] == nil)
			compare.close(s)
			vim.o.columns = width
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_navigation_delayed_latest_request_and_cancellation",
		function()
			local _, s = fixture("git")
			keys("<CR>]v")
			local provider, requests = s.provider.preview, {}
			s.provider.preview = function(_, item, callback)
				requests[#requests + 1] = { item = item, callback = callback, killed = false }
				local request = requests[#requests]
				return {
					kill = function()
						request.killed = true
					end,
				}
			end
			keys("]b]b[b")
			assert(#requests == 3 and requests[1].killed and requests[2].killed)
			local result = { left = { "before" }, right = { "after" }, left_label = "BASE", right_label = "SAVED" }
			requests[2].callback(result)
			assert(s.preview_result == nil and s.shown_item.relpath == "b.txt")
			requests[3].callback(result)
			at(s, "b.txt", "saved", 1)
			requests[1].callback(result)
			at(s, "b.txt", "saved", 1)
			keys("]b")
			local late = requests[#requests]
			vim.api.nvim_set_current_tabpage(s.origin_tab)
			late.callback(result)
			assert(vim.api.nvim_get_current_tabpage() == s.origin_tab and not s.navigation_intent)
			vim.api.nvim_set_current_tabpage(s.tab)
			vim.api.nvim_set_current_win(s.rightwin)
			keys("[b")
			local closed = requests[#requests]
			compare.close(s)
			closed.callback(result)
			s.provider.preview = provider
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_navigation_zero_single_and_unavailable_entries",
		function()
			local f = h.make_git_fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			keys("]b")
			assert(vim.api.nvim_get_current_win() == s.rightwin)
			local original, calls = s.provider.preview, 0
			s.provider.preview = function(...)
				calls = calls + 1
				return original(...)
			end
			keys("99]b[b")
			assert(calls == 0)
			keys(":LazyVCS compare metadata<CR>]b")
			assert(s.mode == "metadata" and calls == 0)
			keys(":LazyVCS compare metadata<CR>")
			local binary = assert(io.open(f.root .. "/binary.txt", "wb"))
			binary:write("binary\0data\n")
			binary:close()
			vim.fn.writefile({}, f.root .. "/empty.txt")
			h.write_file(f.root .. "/large.txt", string.rep("x", 1024 * 1024 + 1))
			compare.refresh(s)
			ready(s)
			vim.api.nvim_set_current_win(s.sidewin)
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["sample.txt"], 0 })
			keys("]b")
			ctx.wait_for(function()
				return s.shown_item.relpath == "binary.txt" and not s.preview_job
			end, nil, 15000)
			assert(not s.preview_result and not s.navigation_intent)
			assert(vim.api.nvim_get_current_win() == s.sidewin)
			keys("]b")
			ready(s, "empty.txt")
			assert(vim.api.nvim_get_current_win() == s.sidewin)
			keys("]b")
			ctx.wait_for(function()
				return s.shown_item.relpath == "large.txt" and not s.preview_job
			end, nil, 15000)
			assert(not s.preview_result)
			keys("]b")
			ready(s, "sample.txt")
			assert(vim.api.nvim_get_current_win() == s.rightwin)
			s.provider.preview = original
			h.exec({ "git", "restore", "sample.txt" }, f.root)
			for _, path in ipairs({ "binary.txt", "empty.txt", "large.txt" }) do
				vim.fn.delete(f.root .. "/" .. path)
			end
			compare.refresh(s)
			ctx.wait_for(function()
				return s.snapshot ~= nil and #s.items == 0
			end, nil, 15000)
			assert(api.compare_next() and next(s.file_views) == nil)
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_keys_validation_disabled_commands_and_counts",
		function()
			local config = require("lazyvcs.config")
			for _, key in ipairs({ "q", "b", "<Return>", "<leader>vf", "]v" }) do
				assert(not pcall(config.setup, { keymaps = { next_file = key } }))
			end
			for _, count in ipairs({ 0, -1, 1.5, math.huge, 0 / 0, "2", false }) do
				assert(not pcall(api.compare_next, count))
			end
			for _, opts in ipairs({ { keymaps = { next_file = "]x", prev_file = false } }, { session_keymaps = false } }) do
				api.setup(opts)
				local _, s = fixture("git")
				for _, buf in ipairs({ s.sidebar, s.left, s.right }) do
					vim.api.nvim_buf_call(buf, function()
						assert(vim.fn.maparg("]b", "n", false, true).buffer ~= 1)
						assert(vim.fn.maparg("[b", "n", false, true).buffer ~= 1)
						if opts.keymaps then
							assert(vim.fn.maparg("]x", "n") ~= "")
						end
					end)
				end
				if opts.keymaps then
					keys("]x")
				else
					vim.cmd("LazyVCS compare next")
				end
				at(s, "b.txt", "saved", 8)
				compare.close(s)
			end
			api.setup({})
			assert(vim.tbl_contains(require("lazyvcs.commands")._complete("n", "LazyVCS compare n"), "next"))
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_history_base_identity_includes_svn_url_and_rename_source",
		function()
			local navigation = require("lazyvcs.compare_navigation")
			local s = { file_views = { ["a.txt"] = { old_path = "old.txt" }, ["b.txt"] = {} } }
			local snapshot = { vcs = "svn", root = "/wc", revision = "42", url = "svn://repo/trunk" }
			navigation.reconcile(s, snapshot, { { relpath = "a.txt", old_path = "other.txt" }, { relpath = "b.txt" } })
			assert(s.file_views["a.txt"] == nil and s.file_views["b.txt"])
			s.restore = { views = {}, reviewed = true }
			snapshot.url = "svn://repo/branches/feature"
			navigation.reconcile(s, snapshot, { { relpath = "b.txt" } })
			assert(next(s.file_views) == nil and s.restore.views == nil and s.restore.reviewed == nil)
			s.file_views["b.txt"] = {}
			snapshot.revision = "43"
			navigation.reconcile(s, snapshot, { { relpath = "b.txt" } })
			assert(next(s.file_views) == nil)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_navigation_deleted_renamed_literal_and_modified_editor",
		function()
			local f, s = fixture("git")
			local editor = vim.api.nvim_win_get_buf(s.origin_win)
			vim.api.nvim_buf_set_lines(editor, 0, 1, false, { "unsaved editor contents" })
			h.exec({ "git", "mv", "a.txt", "z.txt" }, f.root)
			h.exec({ "git", "rm", "-f", "b.txt" }, f.root)
			local literal = "space ☃@.txt"
			h.write_file(f.root .. "/" .. literal, "literal path\n")
			compare.refresh(s)
			ready(s)
			assert(s.items[s.rows_cache.by_path["z.txt"]].old_path == "a.txt")
			vim.api.nvim_set_current_win(s.sidewin)
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["z.txt"], 0 })
			keys("P")
			ready(s, "z.txt")
			keys("<CR>]b")
			at(s, "b.txt", "base", 1)
			keys("]b")
			at(s, "c.txt", "base", 8)
			keys("]b")
			at(s, literal, "saved", 1)
			assert(
				vim.bo[editor].modified
					and vim.api.nvim_buf_get_lines(editor, 0, 1, false)[1] == "unsaved editor contents"
			)
			compare.close(s)
			vim.bo[editor].modified = false
		end,
	}
	cases[#cases + 1] = {
		"test_svn_comparison_file_navigation_includes_directory_properties",
		function()
			local f, s = fixture("svn")
			h.exec({ "svn", "propset", "svn:ignore", "ignored-file", "." }, f.root)
			compare.refresh(s)
			ready(s)
			vim.api.nvim_set_current_win(s.sidewin)
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["c.txt"], 0 })
			keys("]b")
			ready(s, ".")
			assert(vim.api.nvim_get_current_win() == s.sidewin and #s.navigation.saved == 0)
			assert(s.preview_result.right_label == "PROPERTY PATCH")
			keys("]b")
			at(s, "a.txt", "saved", 8)
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_views_are_isolated_between_sessions",
		function()
			local _, first = fixture("git")
			keys("<CR>]v")
			vim.api.nvim_set_current_tabpage(first.origin_tab)
			local _, second = fixture("git")
			keys("<CR>]v]v")
			keys("]b")
			at(second, "b.txt", "saved", 8)
			vim.api.nvim_set_current_tabpage(first.tab)
			vim.api.nvim_set_current_win(first.rightwin)
			keys("]b")
			at(first, "b.txt", "saved", 8)
			keys("[b")
			at(first, "a.txt", "saved", 30)
			compare.close(first)
			vim.api.nvim_set_current_tabpage(second.tab)
			vim.api.nvim_set_current_win(second.rightwin)
			keys("[b")
			at(second, "a.txt", "saved", 50)
			compare.close(second)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_pane_actions_survive_filetype_plugins_and_metadata_refresh",
		function()
			local shadowed = 0
			local group = vim.api.nvim_create_augroup("lazyvcs_test_pane_filetype", { clear = true })
			vim.api.nvim_create_autocmd("FileType", {
				group = group,
				callback = function(args)
					if vim.api.nvim_buf_get_name(args.buf):match("^lazyvcs://compare/") then
						for _, key in ipairs({ "\\ve", "\\v?", "]b", "]v" }) do
							vim.keymap.set("n", key, function()
								shadowed = shadowed + 1
							end, { buffer = args.buf })
						end
					end
				end,
			})
			local f, s = fixture("git")
			h.write_file(f.root .. "/" .. string.rep("long-name-", 8) .. ".cpp", "new file\n")
			compare.refresh(s)
			ready(s)
			keys("<CR>")
			for _, win in ipairs({ s.leftwin, s.rightwin }) do
				vim.api.nvim_set_current_win(win)
				local width = vim.api.nvim_win_get_width(s.sidewin)
				keys(":LazyVCS compare width<CR>")
				assert(s.auto_width and vim.api.nvim_win_get_width(s.sidewin) > width)
				assert(vim.api.nvim_get_current_win() == win)
				keys(":LazyVCS compare width<CR><leader>v?")
				assert(vim.api.nvim_get_current_win() == s.helpwin)
				keys("q")
				assert(vim.api.nvim_get_current_win() == win)
				assert(vim.api.nvim_win_get_width(s.sidewin) == width)
				keys(":LazyVCS compare metadata<CR>")
				assert(s.mode == "metadata")
				keys(":LazyVCS compare metadata<CR>:LazyVCS compare refresh<CR>")
				ready(s)
				assert(s.mode == "text" and vim.api.nvim_get_current_win() == win)
				assert(vim.fn.maparg("\\v?", "n", false, true).desc == "lazyvcs Comparison help")
			end
			assert(shadowed == 0)
			vim.api.nvim_del_augroup_by_id(group)
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_opening_routes_search_positions_from_each_owned_window",
		function()
			local f, s = fixture("git")
			keys("<CR>]v")
			for _, win in ipairs({ s.sidewin, s.leftwin, s.rightwin }) do
				vim.api.nvim_set_current_win(win)
				local buf = vim.fn.bufadd(f.root .. "/b.txt")
				vim.fn.bufload(buf)
				vim.api.nvim_win_set_buf(win, buf)
				vim.api.nvim_win_set_cursor(win, { 30, 3 })
				edited(s, "b.txt", 30, 3)
				vim.api.nvim_set_current_win(s.rightwin)
				keys(":LazyVCS compare width<CR>")
				assert(s.auto_width)
				keys(":LazyVCS compare width<CR>")
				at(s, "a.txt", "saved", 30)
			end
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/c.txt"))
			edited(s, "c.txt", 1)
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_opening_preserves_unsaved_origin_and_search_line_clamps",
		function()
			local f, s = fixture("git")
			keys("<CR>]v")
			local origin = vim.api.nvim_win_get_buf(s.origin_win)
			local hidden = vim.o.hidden
			vim.o.hidden = false
			vim.api.nvim_buf_set_lines(origin, 0, -1, false, { "unsaved editor" })
			local outside = f.root .. "/outside.txt"
			h.write_file(outside, "outside one\nother line\n")
			vim.cmd.edit(vim.fn.fnameescape(outside))
			vim.api.nvim_win_set_cursor(0, { 2, 3 })
			ctx.wait_for(function()
				return vim.api.nvim_get_current_tabpage() == s.origin_tab
			end, "outside file did not open")
			assert(vim.api.nvim_win_get_buf(s.origin_win) == origin)
			assert(vim.bo[origin].modified and vim.api.nvim_buf_get_lines(origin, 0, -1, false)[1] == "unsaved editor")
			assert(vim.api.nvim_buf_get_name(0) == outside and vim.api.nvim_win_get_cursor(0)[1] == 2)
			vim.api.nvim_set_current_win(s.rightwin)
			assert(cursor(s, "saved") == 30)
			local buf = vim.fn.bufadd(f.root .. "/b.txt")
			vim.fn.bufload(buf)
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn["repeat"]({ "unsaved search text" }, 100))
			vim.api.nvim_win_set_buf(s.rightwin, buf)
			vim.api.nvim_win_set_cursor(s.rightwin, { 100, 10 })
			edited(s, "b.txt", 100, 10)
			assert(vim.bo[buf].modified and vim.api.nvim_buf_line_count(buf) == 100)
			vim.bo[buf].modified, vim.bo[origin].modified = false, false
			vim.o.hidden = hidden
			compare.close(s)
			vim.cmd.only()
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_opening_latest_selection_leave_close_and_explicit_split",
		function()
			local f, s = fixture("git")
			keys("<CR>]v")
			for _, path in ipairs({ "b.txt", "c.txt" }) do
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/" .. path))
			end
			edited(s, "c.txt", 1)
			vim.api.nvim_set_current_win(s.rightwin)
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/b.txt"))
			vim.api.nvim_set_current_win(s.origin_win)
			ctx.wait_for(function()
				return vim.api.nvim_win_get_buf(s.rightwin) == s.right
			end, "unfocused pane not restored")
			assert(s.shown_item.relpath == "a.txt" and vim.api.nvim_get_current_win() == s.origin_win)
			vim.api.nvim_set_current_win(s.rightwin)
			vim.cmd("split " .. vim.fn.fnameescape(f.root .. "/b.txt"))
			local extra = vim.api.nvim_get_current_win()
			vim.wait(50)
			assert(vim.api.nvim_get_current_win() == extra and vim.api.nvim_buf_get_name(0) == f.root .. "/b.txt")
			assert(s.shown_item.relpath == "a.txt")
			vim.api.nvim_win_close(extra, true)
			vim.api.nvim_set_current_win(s.rightwin)
			vim.cmd.edit(vim.fn.fnameescape(f.root .. "/b.txt"))
			compare.close(s)
			vim.wait(50)
			assert(s.closed and vim.api.nvim_get_current_win() == s.origin_win)
		end,
	}

	cases[#cases + 1] = {
		"test_comparison_file_opening_quickfix_lsp_first_line_and_window_options",
		function()
			local f, s = fixture("git")
			keys("<CR>")
			vim.fn.setqflist({ { filename = f.root .. "/b.txt", lnum = 30, col = 4 } })
			vim.cmd("cfirst")
			edited(s, "b.txt", 30, 3)
			vim.api.nvim_set_current_win(s.sidewin)
			assert(vim.lsp.util.show_document({
				uri = vim.uri_from_fname(f.root .. "/c.txt"),
				range = { start = { line = 0, character = 2 }, ["end"] = { line = 0, character = 4 } },
			}, "utf-8", { focus = true }))
			edited(s, "c.txt", 1, 2)
			assert(vim.wo[s.leftwin].diff and vim.wo[s.rightwin].diff)
			assert(not vim.wo[s.sidewin].diff and vim.wo[s.sidewin].winfixwidth and not vim.wo[s.sidewin].wrap)
			compare.close(s)
			vim.fn.setqflist({})
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_file_opening_waits_for_focused_picker_preview",
		function()
			local f, s = fixture("git")
			keys("<CR>]v")
			local prompt = vim.api.nvim_create_buf(false, true)
			local floating = vim.api.nvim_open_win(prompt, true, {
				relative = "editor",
				row = 1,
				col = 1,
				width = 20,
				height = 4,
			})
			vim.api.nvim_win_call(s.rightwin, function()
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/b.txt"))
				vim.api.nvim_win_set_cursor(0, { 30, 0 })
			end)
			vim.wait(50)
			assert(vim.api.nvim_win_get_buf(s.rightwin) ~= s.right)
			assert(vim.api.nvim_get_current_win() == floating and s.shown_item.relpath == "a.txt")
			vim.api.nvim_set_current_win(s.rightwin)
			edited(s, "b.txt", 30)
			vim.api.nvim_win_close(floating, true)
			vim.api.nvim_buf_delete(prompt, { force = true })
			compare.close(s)
		end,
	}

	cases[#cases + 1] = {
		"test_comparison_file_opening_resize_preserves_unsaved_wipe_buffer",
		function()
			local width = vim.o.columns
			vim.o.columns = 160
			local f, s = fixture("git")
			keys("<CR>")
			local buf = vim.fn.bufadd(f.root .. "/b.txt")
			vim.fn.bufload(buf)
			vim.api.nvim_win_set_buf(s.rightwin, buf)
			vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved selected file" })
			vim.api.nvim_win_set_cursor(s.rightwin, { 30, 0 })
			vim.bo[buf].bufhidden = "wipe"
			vim.o.columns = 80
			vim.api.nvim_exec_autocmds("VimResized", {})
			assert(vim.api.nvim_buf_is_valid(buf), "resize deleted unsaved picker buffer")
			assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "unsaved selected file")
			edited(s, "b.txt", 30)
			assert(s.stacked and vim.bo[buf].modified and vim.bo[buf].bufhidden == "wipe")
			vim.bo[buf].bufhidden, vim.bo[buf].modified = "", false
			compare.close(s)
			vim.o.columns = width
		end,
	}

	cases[#cases + 1] = {
		"test_comparison_special_buffer_opening_restores_layout_and_preserves_contents",
		function()
			local _, s = fixture("git")
			keys("<CR>]v")
			for _, kind in ipairs({ "nofile", "acwrite" }) do
				vim.api.nvim_set_current_win(s.rightwin)
				local buf = vim.api.nvim_create_buf(false, true)
				vim.bo[buf].buftype, vim.bo[buf].bufhidden = kind, "wipe"
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "selected special buffer" })
				vim.api.nvim_win_set_buf(s.rightwin, buf)
				ctx.wait_for(function()
					return vim.api.nvim_get_current_tabpage() == s.origin_tab
				end, "special buffer not routed")
				assert(vim.api.nvim_get_current_buf() == buf)
				assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "selected special buffer")
				assert(vim.api.nvim_win_get_buf(s.rightwin) == s.right)
				vim.bo[buf].modified, vim.bo[buf].bufhidden = false, "hide"
				vim.api.nvim_set_current_win(s.rightwin)
				keys(":LazyVCS compare width<CR>")
				assert(s.auto_width)
				keys(":LazyVCS compare width<CR>")
			end
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_metadata_only_revisit_keeps_remembered_review",
		function()
			local _, s = fixture("git")
			keys("<CR>]v]v]b<leader>vf")
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["a.txt"], 0 })
			keys(":LazyVCS compare metadata<CR>")
			ready(s, "a.txt")
			assert(s.mode == "metadata")
			keys("]b[b")
			at(s, "a.txt", "saved", 50)
			keys("]b<leader>vf")
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["a.txt"], 0 })
			keys(":LazyVCS compare metadata<CR>")
			ready(s, "a.txt")
			keys("p<CR>")
			at(s, "a.txt", "saved", 50)
			compare.close(s)
		end,
	}

	cases[#cases + 1] = {
		"test_comparison_terminal_opening_keeps_review_panes",
		function()
			local _, s = fixture("git")
			keys("<CR>")
			vim.cmd.enew()
			local buf = vim.api.nvim_get_current_buf()
			-- Test terminal-buffer routing without a nested process or ConPTY.
			local channel = vim.api.nvim_open_term(buf, {})
			vim.api.nvim_chan_send(channel, "terminal output\r\n")
			ctx.wait_for(function()
				return vim.api.nvim_get_current_tabpage() == s.origin_tab
			end, "terminal not routed")
			assert(vim.api.nvim_get_current_buf() == buf and vim.bo[buf].buftype == "terminal")
			assert(vim.api.nvim_win_get_buf(s.rightwin) == s.right and vim.bo[s.right].buftype == "nofile")
			ctx.wait_for(function()
				return table
					.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
					:find("terminal output", 1, true)
			end, "terminal output was lost")
			vim.api.nvim_set_current_win(s.rightwin)
			keys(":LazyVCS compare width<CR>")
			assert(s.auto_width)
			compare.close(s)
			vim.api.nvim_buf_delete(buf, { force = true })
		end,
	}

	return cases
end
