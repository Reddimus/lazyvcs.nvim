return function(ctx)
	local api = vim.api
	local function sample()
		vim.cmd.enew()
		local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
		api.nvim_win_set_hl_ns(win, -1)
		vim.wo[win].winhighlight = ""
		api.nvim_buf_set_lines(buf, 0, -1, false, { "return value" })
		vim.bo[buf].filetype = "c"
		vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn = false, false, "no"
		vim.wo[win].foldcolumn = "0"
		api.nvim_set_hl(0, "LazyVCSTestSyntax", { fg = "#ff0000" })
		api.nvim_set_hl(0, "@lsp.type.comment.c", { fg = "#777777", italic = true })
		local marks = api.nvim_create_namespace("lazyvcs-test-semantic")
		api.nvim_buf_set_extmark(buf, marks, 0, 0, { end_col = 6, hl_group = "LazyVCSTestSyntax", priority = 100 })
		return buf, win, marks
	end
	local function attr(win, foreground_only)
		vim.cmd.redraw()
		local pos = vim.fn.win_screenpos(win)
		local attributes = api.nvim__inspect_cell(1, pos[1] - 1, pos[2] - 1)[2]
		local normal = api.nvim_get_hl(0, { name = "Normal" })
		local ns = api.nvim_get_hl_ns({ winid = win })
		local local_normal = ns > 0 and api.nvim_get_hl(ns, { name = "Normal", create = false }) or {}
		if local_normal.link then
			local_normal = api.nvim_get_hl(0, { name = local_normal.link })
		end
		-- 0.11 omits implicit window Normal colors from cell attributes.
		attributes.foreground = attributes.foreground or local_normal.fg or normal.fg
		attributes.background = attributes.background or local_normal.bg or normal.bg
		if foreground_only then
			attributes.background = nil
		end
		return vim.inspect(attributes)
	end
	local function overlay(buf, marks)
		api.nvim_buf_set_extmark(buf, marks, 0, 0, { end_col = 6, hl_group = "@lsp.type.comment.c", priority = 125 })
	end
	return {
		{
			"test_core_diff_highlighting_keeps_diff_background_and_diagnostics",
			function()
				local guard = require("lazyvcs.highlighting")
				local buf, win, marks = sample()
				api.nvim_set_hl(0, "LazyVCSTestDiff", { bg = "#112233" })
				api.nvim_set_hl(0, "LazyVCSTestDiagnostic", { undercurl = true, sp = "#00ff00" })
				api.nvim_buf_set_extmark(
					buf,
					marks,
					0,
					0,
					{ end_col = 12, hl_group = "LazyVCSTestDiff", priority = 50 }
				)
				api.nvim_buf_set_extmark(
					buf,
					marks,
					0,
					0,
					{ end_col = 6, hl_group = "LazyVCSTestDiagnostic", priority = 130 }
				)
				local expected = attr(win)
				overlay(buf, marks)
				guard.apply(win, "syntax")
				assert(attr(win) == expected, "diff background or diagnostic decoration changed")
				guard.release(win)
			end,
		},
		{
			"test_core_diff_highlighting_chained_window_mappings",
			function()
				local guard = require("lazyvcs.highlighting")
				local buf, win, marks = sample()
				local comment = api.nvim_get_hl(0, { name = "Comment" })
				local error = api.nvim_get_hl(0, { name = "ErrorMsg" })
				---@cast comment table
				---@cast error table
				api.nvim_set_hl(0, "Comment", { bg = "#ff00ff" })
				api.nvim_set_hl(0, "ErrorMsg", { bg = "#00ff00" })
				vim.wo[win].winhighlight = "Normal:Comment,Comment:ErrorMsg"
				api.nvim_win_set_hl_ns(win, api.nvim_get_hl_ns({ winid = win }))
				local expected = attr(win, true)
				overlay(buf, marks)
				guard.apply(win, "syntax")
				assert(attr(win, true) == expected, "winhighlight links changed their targets")
				assert(api.nvim_get_hl(api.nvim_get_hl_ns({ winid = win }), { name = "Normal" }).bg == 0xff00ff)
				vim.wo[win].winhighlight = "Normal:ErrorMsg"
				api.nvim_exec_autocmds("OptionSet", { pattern = "winhighlight" })
				ctx.wait_for(function()
					return api.nvim_get_hl(api.nvim_get_hl_ns({ winid = win }), { name = "Normal" }).bg == 0x00ff00
				end, "new mapping not applied")
				guard.release(win)
				assert(vim.wo[win].winhighlight == "Normal:ErrorMsg")
				vim.wo[win].winhighlight = ""
				api.nvim_set_hl(0, "Comment", comment)
				api.nvim_set_hl(0, "ErrorMsg", error)
			end,
		},
		{
			"test_core_diff_highlighting_buffer_transfer_and_editor_option",
			function()
				local guard = require("lazyvcs.highlighting")
				local _, win = sample()
				local previous = api.nvim_get_hl_ns({ winid = win })
				guard.apply(win, "syntax")
				vim.cmd.enew()
				assert(api.nvim_get_hl_ns({ winid = win }) == previous, "guard leaked into another buffer")
				guard.apply(win, "syntax")
				guard.apply(win, "editor")
				assert(api.nvim_get_hl_ns({ winid = win }) == previous)
				assert(not pcall(require("lazyvcs.config").setup, { diff_highlighting = "invalid" }))
			end,
		},
		{
			"test_core_diff_highlighting_late_tokens_theme_and_mappings",
			function()
				local guard = require("lazyvcs.highlighting")
				local buf, win, marks = sample()
				vim.wo[win].winhighlight = "Normal:LazyVCSTestSyntax"
				api.nvim_win_set_hl_ns(win, api.nvim_get_hl_ns({ winid = win }))
				local syntax = attr(win, true)
				guard.apply(win, "syntax")
				assert(attr(win, true) == syntax)
				api.nvim_set_hl(0, "@lsp.typemod.return.testLate.c", { fg = "#777777", italic = true })
				api.nvim_buf_set_extmark(buf, marks, 0, 0, {
					end_col = 6,
					hl_group = "@lsp.typemod.return.testLate.c",
					priority = 127,
				})
				api.nvim_exec_autocmds("LspTokenUpdate", {
					buffer = buf,
					data = { token = { type = "return", modifiers = { testLate = true } } },
				})
				assert(attr(win, true) == syntax, "late token was not suppressed")
				api.nvim_set_hl(0, "LazyVCSTestSyntax", { fg = "#0000ff" })
				api.nvim_exec_autocmds("ColorScheme", {})
				ctx.wait_for(function()
					return attr(win, true) ~= syntax
				end, "theme did not refresh")
				guard.release(win)
				assert(vim.wo[win].winhighlight == "Normal:LazyVCSTestSyntax")
				vim.wo[win].winhighlight = ""
			end,
		},
		{
			"test_core_diff_highlighting_compare_previews_and_resize",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				local compare = require("lazyvcs.compare")
				local s = assert(compare.open({ path = fixture.root, base = "HEAD" }))
				ctx.wait_for(function()
					return s.preview_result
				end, "comparison did not load", 15000)
				assert(api.nvim_get_hl_ns({ winid = s.leftwin }) > 0)
				assert(api.nvim_get_hl_ns({ winid = s.rightwin }) > 0)
				local width = vim.o.columns
				vim.o.columns = 65
				api.nvim_exec_autocmds("VimResized", {})
				assert(api.nvim_get_hl_ns({ winid = s.rightwin }) > 0)
				vim.o.columns = width
				api.nvim_exec_autocmds("VimResized", {})
				compare.close(s)
				assert(not api.nvim_win_is_valid(s.leftwin))
				assert(not api.nvim_win_is_valid(s.rightwin))
			end,
		},
		{
			"test_core_diff_highlighting_window_scope_and_restore",
			function()
				local guard = require("lazyvcs.highlighting")
				local buf, win, marks = sample()
				vim.cmd.vsplit()
				local other = api.nvim_get_current_win()
				local syntax = attr(win)
				overlay(buf, marks)
				local semantic = attr(win)
				local other_semantic = attr(other)
				assert(syntax ~= semantic)
				guard.apply(win, "syntax")
				assert(
					attr(win) == syntax,
					"semantic overlay remained in diff window: " .. syntax .. " vs " .. attr(win)
				)
				assert(attr(other) == other_semantic, "another window changed")
				guard.release(win)
				assert(attr(win) == semantic, "original highlight namespace was not restored")
				guard.release(win)
				vim.cmd.only()
			end,
		},
		{
			"test_core_diff_highlighting_namespace_pool_and_external_owner",
			function()
				local guard = require("lazyvcs.highlighting")
				local _, win = sample()
				local original = api.nvim_create_namespace("lazyvcs-test-original-theme")
				api.nvim_set_hl(original, "LazyVCSTestSyntax", { fg = "#00ff00" })
				api.nvim_win_set_hl_ns(win, original)
				local expected = attr(win)
				guard.apply(win, "syntax")
				assert(attr(win) == expected, "custom namespace lost")
				local pooled = api.nvim_get_hl_ns({ winid = win })
				guard.release(win)
				assert(api.nvim_get_hl_ns({ winid = win }) == original)
				api.nvim_win_set_hl_ns(win, -1)
				local global = attr(win)
				guard.apply(win, "syntax")
				assert(api.nvim_get_hl_ns({ winid = win }) == pooled, "namespace was not reused")
				assert(attr(win) == global, "pooled namespace retained an old theme")
				api.nvim_win_set_hl_ns(win, original)
				guard.release(win)
				assert(api.nvim_get_hl_ns({ winid = win }) == original, "external owner overwritten")
				guard.apply(win, "editor")
				assert(api.nvim_get_hl_ns({ winid = win }) == original)
				api.nvim_win_set_hl_ns(win, -1)
			end,
		},
		{
			"test_core_diff_highlighting_live_layout_cleanup",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(fixture.file))
				local win = api.nvim_get_current_win()
				local original = api.nvim_get_hl_ns({ winid = win })
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				require("lazyvcs").open()
				ctx.wait_for(function()
					return require("lazyvcs.state").get(api.nvim_get_current_buf())
				end, "diff did not open")
				assert(api.nvim_get_hl_ns({ winid = win }) ~= original)
				require("lazyvcs").close()
				assert(api.nvim_get_hl_ns({ winid = win }) == original)
			end,
		},
	}
end
