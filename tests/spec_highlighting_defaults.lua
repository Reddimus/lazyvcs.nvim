return function()
	local api, highlighting = vim.api, require("lazyvcs.highlighting")
	local function rendered(win)
		vim.cmd.redraw()
		local pos = vim.fn.screenpos(win, 1, 1)
		return api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)[2].foreground
	end
	local function check(colorscheme)
		local termguicolors = vim.o.termguicolors
		vim.o.termguicolors = true
		vim.cmd.new()
		vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn, vim.wo.foldcolumn = false, false, "no", "0"
		local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		local first = api.nvim_create_namespace("lazyvcs-test-default-first-" .. buf)
		local second = api.nvim_create_namespace("lazyvcs-test-default-second-" .. buf)
		local group = "LazyVcsTestDefaultColor" .. buf
		local marks = api.nvim_create_namespace("lazyvcs-test-default-marks")
		local ok, err = xpcall(function()
			api.nvim_buf_set_lines(buf, 0, -1, false, { "custom" })
			api.nvim_buf_set_extmark(buf, marks, 0, 0, { end_col = 6, hl_group = group })
			api.nvim_set_hl(first, group, { fg = 0xff0000 })
			api.nvim_win_set_hl_ns(win, first)
			highlighting.apply(win, "syntax")
			local slot = api.nvim_get_hl_ns({ winid = win })
			assert(rendered(win) == 0xff0000, "initial pane color was not red")
			highlighting.release(win)
			assert(api.nvim_get_hl_ns({ winid = win }) == first)
			local source = colorscheme and 0 or second
			api.nvim_set_hl(source, group, { fg = colorscheme and 0xff0000 or 0x00ff00, default = true })
			api.nvim_win_set_hl_ns(win, second)
			highlighting.apply(win, "syntax")
			if colorscheme then
				vim.cmd("highlight clear " .. group)
				api.nvim_set_hl(0, group, { fg = 0x00ff00, default = true })
				api.nvim_exec_autocmds("ColorScheme", {})
				vim.wait(50)
			end
			assert(api.nvim_get_hl_ns({ winid = win }) == slot, "highlight pool slot was not reused")
			assert(api.nvim_get_hl(slot, { name = group }).fg == 0x00ff00, "pooled default kept stale color")
			assert(rendered(win) == 0x00ff00, "rendered cell retained stale color")
			assert(api.nvim_get_hl(source, { name = group }).default == true, "source default was changed")
			highlighting.release(win)
			assert(api.nvim_get_hl_ns({ winid = win }) == second)
		end, debug.traceback)
		highlighting.release(win)
		api.nvim_set_hl(0, group, {})
		api.nvim_win_close(win, true)
		api.nvim_buf_delete(buf, { force = true })
		vim.o.termguicolors = termguicolors
		assert(ok, err)
	end
	return {
		{
			"test_core_highlighting_defaults_update_reused_pool",
			function()
				check(false)
			end,
		},
		{
			"test_core_highlighting_defaults_update_on_colorscheme",
			function()
				check(true)
			end,
		},
	}
end
