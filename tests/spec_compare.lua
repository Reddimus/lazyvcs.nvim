return function(ctx)
	local compare = require("lazyvcs.compare")
	local function ready(s)
		ctx.wait_for(function()
			return s.snapshot and s.preview_result or s.message == "Comparison unavailable"
		end, "comparison did not load", 15000)
		assert(s.preview_result, s.message)
	end
	return {
		{
			"test_svn_blame_new_unsaved_file_is_ineligible",
			function()
				local fixture = ctx.helpers.make_svn_fixture()
				local done, blame, blame_err = false, nil, nil
				local util = require("lazyvcs.util")
				local original, calls = util.system_start, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(...)
					calls = calls + 1
					return original(...)
				end
				require("lazyvcs.backends.svn").blame_lines_async(fixture.root .. "/.config", function(lines, err)
					done, blame, blame_err = true, lines, err
				end, { root = fixture.root, contents = "unsaved\n" })
				ctx.wait_for(function()
					return done
				end, "new SVN file blame", 15000)
				util.system_start = original
				assert(blame == nil and blame_err == nil, tostring(blame_err))
				assert(calls == 0, "unsaved new file launched SVN commands")
			end,
		},
		{
			"test_source_control_comparison_generic_row_asks_for_repository",
			function()
				local fixture = ctx.helpers.make_mixed_source_control_fixture()
				local native = require("lazyvcs.source_control.native")
				local state = native.open({ path = fixture.root })
				ctx.wait_for(function()
					return not state.lazyvcs_discovering and state.lazyvcs_line_nodes
				end, "workspace discovery", 15000)
				vim.api.nvim_win_set_cursor(state.winid, { 1, 0 })
				local context = assert(native.comparison_context())
				assert(not context.path and #context.repos >= 2)
				local picker = require("lazyvcs.picker")
				local original, picked = picker.select, false
				---@diagnostic disable-next-line: duplicate-set-field
				picker.select = function(items, _, done)
					picked = true
					for _, item in ipairs(items) do
						if item.root == fixture.git_dirty then
							return done(item)
						end
					end
					error("visible repository missing")
				end
				local ok, err = pcall(compare.open, { base = "HEAD" })
				picker.select = original
				assert(ok, err)
				assert(picked, "generic row silently chose the focused repository")
				local session = assert(compare.current())
				ready(session)
				assert(session.root == fixture.git_dirty)
				compare.close(session)
				native.close()
			end,
		},
		{
			"test_comparison_edit_recovers_after_origin_tab_closes",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				vim.cmd.tabnew(vim.fn.fnameescape(fixture.file))
				local origin = vim.api.nvim_get_current_tabpage()
				local s = assert(compare.open({ path = fixture.root, base = "HEAD" }))
				ready(s)
				vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(origin))
				vim.api.nvim_set_current_win(s.sidewin)
				vim.api.nvim_feedkeys("o", "x", false)
				assert(vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) == fixture.file)
				assert(vim.api.nvim_tabpage_is_valid(s.tab))
				compare.close(s)
				vim.cmd.tabclose()
			end,
		},
		{
			"test_blame_selection_rejects_stale_results_and_cancels_closed_window",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(fixture.file))
				local source = vim.api.nvim_get_current_buf()
				local loader = require("lazyvcs.backends.blame_selection")
				local original, callback, killed = loader.load, nil, false
				---@diagnostic disable-next-line: duplicate-set-field
				loader.load = function(_, _, done)
					callback = done
					return {
						kill = function()
							killed = true
						end,
					}
				end
				local ok, err = pcall(function()
					local request = require("lazyvcs").blame_selection(1, 2)
					vim.api.nvim_buf_set_lines(source, 0, 1, false, { "new content" })
					assert(callback)({ { author = "stale" } })
					assert(vim.api.nvim_buf_get_lines(request.buf, 0, 1, false)[1]:find("Source changed", 1, true))
					vim.api.nvim_feedkeys("q", "x", false)
					request = require("lazyvcs").blame_selection(1, 2)
					vim.api.nvim_win_close(request.win, true)
					assert(killed and request.closed)
					assert(callback)({ { author = "late" } })
					assert(not vim.api.nvim_buf_is_valid(request.buf))
				end)
				loader.load = original
				vim.bo[source].modified = false
				assert(ok, err)
			end,
		},
		{
			"test_comparison_resolved_reopen_honors_untracked_option",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				ctx.helpers.write_file(fixture.root .. "/new.txt", "new\n")
				local origin = vim.api.nvim_get_current_win()
				local s = assert(compare.open({ path = fixture.root, base = "HEAD" }))
				ready(s)
				assert(s.row_by_path["new.txt"])
				vim.api.nvim_set_current_win(origin)
				compare.open({ path = fixture.file, include_untracked = false })
				ctx.wait_for(function()
					return compare.current() == s
						and s.include_untracked == false
						and s.snapshot
						and not s.row_by_path["new.txt"]
				end, "resolved reopen did not apply the option", 15000)
				assert(vim.api.nvim_get_current_win() == s.sidewin)
				compare.close(s)
			end,
		},
		{
			"test_comparison_sidebar_presentation_and_width",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				vim.fn.mkdir(fixture.root .. "/deep/path", "p")
				ctx.helpers.write_file(fixture.root .. "/deep/path/recognizable_filename.txt", "new\n")
				local s = assert(compare.open({ path = fixture.root, base = "HEAD" }))
				ready(s)
				local text = table.concat(vim.api.nvim_buf_get_lines(s.sidebar, 0, -1, false), "\n")
				assert(text:find("recognizable_filename.txt  deep/path", 1, true), text)
				local width = vim.api.nvim_win_get_width(s.sidewin)
				local result = s.preview_result
				vim.api.nvim_feedkeys("e", "x", false)
				assert(vim.api.nvim_get_current_win() == s.sidewin, "e must not edit")
				assert(s.auto_width and s.preview_result == result)
				vim.api.nvim_feedkeys("e", "x", false)
				assert(vim.api.nvim_win_get_width(s.sidewin) == width)
				compare.close(s)
			end,
		},
		{
			"test_comparison_does_not_leak_listed_buffers",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				local before = #vim.fn.getbufinfo({ buflisted = 1 })
				local s = assert(compare.open({ path = fixture.root, base = "HEAD" }))
				ready(s)
				compare.close(s)
				assert(#vim.fn.getbufinfo({ buflisted = 1 }) == before, "comparison leaked a listed buffer")
			end,
		},
		{
			"test_comparison_source_control_navigation_reuses_tab_and_edits_in_editor",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(fixture.file))
				local editor, tab = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
				local native = require("lazyvcs.source_control.native")
				local state = native.open({ path = fixture.root })
				ctx.wait_for(function()
					return not state.lazyvcs_discovering and state.lazyvcs_line_nodes
				end, "discovery", 15000)
				local row
				for line, node in pairs(state.lazyvcs_line_nodes) do
					if node.extra and node.extra.repo_root == fixture.root then
						row = line
						break
					end
				end
				assert(row, "repository row missing")
				vim.api.nvim_win_set_cursor(state.winid, { row, 0 })
				local s = assert(compare.open({ base = "HEAD" }))
				ready(s)
				assert(s.root == fixture.root and s.origin_edit_win == editor)
				local review_tab = s.tab
				native.toggle()
				assert(vim.api.nvim_get_current_tabpage() == tab)
				assert(vim.api.nvim_get_current_win() == state.winid)
				assert(vim.api.nvim_win_get_buf(state.winid) == state.bufnr)
				local again = assert(compare.open({ base = "HEAD" }))
				assert(again == s and again.tab == review_tab)
				ready(s)
				vim.api.nvim_feedkeys("o", "x", false)
				assert(vim.api.nvim_get_current_win() == editor)
				assert(vim.api.nvim_win_get_buf(state.winid) == state.bufnr)
				compare.close(s)
				native.close()
			end,
		},
		{
			"test_comparison_help_and_metadata_preserve_preview",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				local s = assert(compare.open({ path = fixture.root, base = "HEAD" }))
				ready(s)
				local content = vim.api.nvim_buf_get_lines(s.right, 0, -1, false)
				vim.api.nvim_feedkeys("?", "x", false)
				assert(vim.api.nvim_get_current_win() == s.helpwin)
				assert(vim.deep_equal(content, vim.api.nvim_buf_get_lines(s.right, 0, -1, false)))
				vim.api.nvim_feedkeys("q", "x", false)
				assert(compare.current() == s)
				vim.api.nvim_set_current_win(s.sidewin)
				vim.api.nvim_feedkeys("p", "x", false)
				assert(s.mode == "metadata" and not vim.wo[s.leftwin].diff and not vim.wo[s.rightwin].diff)
				vim.api.nvim_set_current_win(s.rightwin)
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
				assert(s.mode == "text" and vim.wo[s.leftwin].diff and vim.wo[s.rightwin].diff)
				assert(vim.deep_equal(content, vim.api.nvim_buf_get_lines(s.right, 0, -1, false)))
				compare.close(s)
			end,
		},
		{
			"test_blame_selection_maps_unsaved_lines_and_accepts_command_range",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(fixture.file))
				local source = vim.api.nvim_get_current_buf()
				vim.api.nvim_buf_set_lines(source, 0, 0, false, { "unsaved new line" })
				local request = require("lazyvcs").blame_selection(1, 2)
				ctx.wait_for(function()
					return request.entries
				end, "selection blame", 15000)
				assert(request.entries[1].uncommitted)
				assert(request.entries[2] and not request.entries[2].uncommitted)
				local text = table.concat(vim.api.nvim_buf_get_lines(request.buf, 0, -1, false), "\n")
				assert(text:find("unsaved new line", 1, true))
				assert(vim.api.nvim_win_get_height(request.win) >= vim.api.nvim_buf_line_count(request.buf) + 1)
				vim.api.nvim_feedkeys("q", "x", false)
				assert(vim.api.nvim_get_current_buf() == source and vim.bo.modified)
				require("lazyvcs.commands").setup()
				vim.cmd("1,2LazyVCS blame")
				assert(vim.bo.filetype == "lazyvcs-blame-selection")
				vim.api.nvim_feedkeys("q", "x", false)
				vim.bo[source].modified = false
			end,
		},
		{
			"test_blame_selection_comparison_pins_git_history",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				local s = assert(compare.open({ path = fixture.root, base = "HEAD" }))
				ready(s)
				local revision = s.snapshot.revision
				ctx.helpers.exec({ "git", "add", "sample.txt" }, fixture.root)
				ctx.helpers.exec({ "git", "commit", "-m", "later commit" }, fixture.root)
				for _, side in ipairs({ s.leftwin, s.rightwin }) do
					vim.api.nvim_set_current_win(side)
					local request = require("lazyvcs").blame_selection(2, 2)
					ctx.wait_for(function()
						return request.entries
					end, "pinned blame", 15000)
					assert(request.entries[1] == nil)
					if side == s.leftwin then
						assert(request.entries[2].full_revision == revision)
					else
						assert(request.entries[2].uncommitted)
					end
					vim.api.nvim_feedkeys("q", "x", false)
				end
				compare.close(s)
			end,
		},
		{
			"test_svn_blame_selection_editor_and_pinned_comparison",
			function()
				local fixture = ctx.helpers.make_svn_fixture()
				vim.cmd.edit(vim.fn.fnameescape(fixture.file))
				local request = require("lazyvcs").blame_selection(2, 3)
				ctx.wait_for(function()
					return request.entries
				end, "svn selection", 15000)
				assert(request.entries[2].uncommitted and request.entries[3].revision == "1")
				vim.api.nvim_feedkeys("q", "x", false)
				local s =
					assert(compare.open({ path = fixture.root, base = ctx.helpers.file_url(fixture.repo) .. "@1" }))
				ready(s)
				vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["sample.txt"], 0 })
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
				ready(s)
				vim.api.nvim_set_current_win(s.leftwin)
				request = require("lazyvcs").blame_selection(2, 2)
				ctx.wait_for(function()
					return request.entries
				end, "svn pinned selection", 15000)
				assert(request.entries[2].revision == "1" and not request.entries[2].uncommitted)
				vim.api.nvim_feedkeys("q", "x", false)
				compare.close(s)
			end,
		},
		{
			"test_comparison_refresh_preserves_selected_identity",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				ctx.helpers.write_file(fixture.root .. "/z.txt", "new file\n")
				local s = assert(compare.open({ path = fixture.root, base = "HEAD" }))
				ready(s)
				vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["z.txt"], 0 })
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
				ready(s)
				assert(s.shown_item.relpath == "z.txt")
				ctx.helpers.write_file(fixture.root .. "/a.txt", "other\n")
				compare.refresh(s)
				ready(s)
				assert(s.shown_item.relpath == "z.txt")
				assert(vim.api.nvim_win_get_cursor(s.sidewin)[1] == s.row_by_path["z.txt"])
				vim.fn.delete(fixture.root .. "/z.txt")
				compare.refresh(s)
				ready(s)
				assert(s.shown_item.relpath == "sample.txt")
				compare.close(s)
			end,
		},
		{
			"test_comparison_width_theme_and_search_preserve_preview",
			function()
				local columns = vim.o.columns
				vim.o.columns = 180
				local fixture = ctx.helpers.make_git_fixture()
				vim.fn.mkdir(fixture.root .. "/long-directory/another-directory", "p")
				ctx.helpers.write_file(
					fixture.root .. "/long-directory/another-directory/recognizable_filename.txt",
					"new\n"
				)
				local s = assert(compare.open({ path = fixture.root, base = "HEAD" }))
				ready(s)
				local result = s.preview_result
				vim.api.nvim_win_set_width(s.sidewin, 45)
				vim.api.nvim_feedkeys("e", "x", false)
				local width = vim.api.nvim_win_get_width(s.sidewin)
				assert(width > 45 and width <= 90)
				vim.api.nvim_exec_autocmds("TabEnter", {})
				assert(vim.api.nvim_win_get_width(s.sidewin) == width)
				vim.cmd.colorscheme("default")
				assert(vim.api.nvim_get_hl(0, { name = "LazyVcsCompareAdd" }).link == "Added")
				assert(vim.fn.search("recognizable_filename", "w") > 0)
				assert(s.preview_result == result)
				vim.api.nvim_feedkeys("e", "x", false)
				assert(vim.api.nvim_win_get_width(s.sidewin) == 45)
				vim.o.columns = 80
				vim.api.nvim_exec_autocmds("VimResized", {})
				assert(s.stacked and vim.wo[s.leftwin].diff and vim.wo[s.rightwin].diff)
				compare.close(s)
				vim.o.columns = columns
			end,
		},
		{
			"test_comparison_cancel_initial_base_prompt_closes_tab",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				local input, count = vim.ui.input, #vim.api.nvim_list_tabpages()
				---@diagnostic disable-next-line: duplicate-set-field
				vim.ui.input = function(_, callback)
					callback(nil)
				end
				local s = assert(compare.open({ path = fixture.root }))
				ctx.wait_for(function()
					return s.closed
				end, "cancel initial base", 15000)
				vim.ui.input = input
				assert(#vim.api.nvim_list_tabpages() == count)
			end,
		},
		{
			"test_comparison_presentation_preserves_unicode_and_literal_paths",
			function()
				local view = require("lazyvcs.compare_view")
				local path = "目錄/náme%\t.txt"
				local rows = view.build({ { status = "M", relpath = path, properties = true } })
				assert(rows.entries[1].relpath == path and rows.by_path[path] == 1)
				assert(rows.lines[1]:find("\\x09", 1, true) and not rows.lines[1]:find("\t", 1, true))
				assert(rows.width == vim.api.nvim_strwidth(rows.lines[1]))
				assert(rows.lines[1]:find(" [props]", 1, true))
			end,
		},
	}
end
