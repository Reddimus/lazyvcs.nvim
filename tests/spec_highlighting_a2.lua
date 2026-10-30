return function(ctx)
	local api, h = vim.api, ctx.helpers
	local guard = require("lazyvcs.highlighting")
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = {
			name,
			function()
				local ns, colors = api.nvim_get_hl_ns({}), vim.o.termguicolors
				local ok, err = xpcall(fn, function(e)
					return e
				end)
				api.nvim_set_hl_ns(ns)
				h.cleanup()
				vim.cmd("silent! only!")
				api.nvim_win_set_hl_ns(0, -1)
				vim.wo.winhighlight = ""
				vim.o.termguicolors = colors
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	local function opened()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		api.nvim_set_hl_ns(0)
		api.nvim_win_set_hl_ns(0, -1)
		api.nvim_set_hl(0, "@lsp.type.lazyvcsA2", { link = "Identifier" })
		vim.cmd.redraw()
		api.nvim__inspect_cell(1, 0, 0)
		local buf = api.nvim_get_current_buf()
		require("lazyvcs").open()
		ctx.wait_for(function()
			return require("lazyvcs.state").get(buf) ~= nil
		end, "highlight diff did not open", 15000)
		return assert(require("lazyvcs.state").get(buf))
	end
	local function foreground(win)
		vim.cmd.redraw()
		local pos = vim.fn.screenpos(win, 1, 1)
		assert(pos.row > 0 and pos.col > 0, "highlight sample is not visible")
		return api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)[2].foreground
	end
	add("test_live_diff_highlighting_inherited_theme_switch", function()
		local s = opened()
		vim.o.termguicolors = true
		local marks = api.nvim_create_namespace("lazyvcs-a2-color-marks")
		api.nvim_set_hl(0, "LazyVcsA2Syntax", { fg = 0xff0000 })
		for _, win in ipairs({ s.base_win, s.editable_win }) do
			api.nvim_buf_set_extmark(api.nvim_win_get_buf(win), marks, 0, 0, {
				end_col = 1,
				hl_group = "LazyVcsA2Syntax",
				priority = 300,
			})
			assert(foreground(win) == 0xff0000, "initial syntax color is wrong")
		end
		local theme = api.nvim_create_namespace("lazyvcs-a2-global-theme")
		api.nvim_set_hl(theme, "LazyVcsA2Syntax", { fg = 0x00ff00 })
		api.nvim_set_hl_ns(theme)
		api.nvim_exec_autocmds("ColorScheme", { pattern = "lazyvcs-a2" })
		ctx.wait_for(function()
			return foreground(s.base_win) == 0x00ff00 and foreground(s.editable_win) == 0x00ff00
		end, "active diff ignored the new inherited theme")
		-- A later namespace owner must survive refresh and release.
		local external = api.nvim_create_namespace("lazyvcs-a2-external-theme")
		api.nvim_win_set_hl_ns(s.editable_win, external)
		guard.refresh(s.editable_win)
		require("lazyvcs.actions").close(s)
		assert(api.nvim_get_hl_ns({ winid = s.editable_win }) == external)
	end)
	add("test_live_diff_highlighting_copied_overlay_restores_inheritance", function()
		local s = opened()
		api.nvim_set_current_win(s.editable_win)
		vim.cmd.split()
		local copy = api.nvim_get_current_win()
		assert(not vim.wo[copy].winhighlight:find("LazyVcsSemanticHidden", 1, true), "copy retained private mappings")
		require("lazyvcs.actions").close(s)
		if not vim.version.ge(vim.version(), { 0, 11, 7 }) then
			error({
				lazyvcs_skip = "Neovim before 0.11.7 cannot reactivate native overlays after restoring namespace inheritance",
			})
		end
		assert(api.nvim_get_hl_ns({ winid = copy }) == -1, "cleaned split retained explicit namespace zero")
		local theme = api.nvim_create_namespace("lazyvcs-a2-copy-theme")
		api.nvim_set_hl_ns(theme)
		assert(api.nvim_get_hl_ns({ winid = copy }) == -1)
	end)
	add("test_live_diff_highlighting_copied_overlay_preserves_user_owners", function()
		local s = opened()
		local mapping = "Normal:LazyVcsSemanticHidden"
		local external = api.nvim_create_namespace("lazyvcs-a2-copy-external")
		for _, owner in ipairs({ "namespace", "mapping" }) do
			local copy = api.nvim_open_win(s.editable_bufnr, false, {
				relative = "editor",
				row = 1,
				col = 1,
				width = 30,
				height = 10,
			})
			vim.wo[copy].winhighlight = mapping .. (owner == "mapping" and ",Normal:ErrorMsg" or "")
			if owner == "namespace" then
				api.nvim_win_set_hl_ns(copy, external)
			end
			api.nvim_set_current_win(copy)
			assert(not vim.wo[copy].winhighlight:find("LazyVcsSemanticHidden", 1, true))
			if owner == "namespace" then
				assert(api.nvim_get_hl_ns({ winid = copy }) == external, "cleanup replaced an external namespace")
			else
				assert(vim.wo[copy].winhighlight == "Normal:ErrorMsg", "cleanup removed user mappings")
			end
			api.nvim_win_close(copy, true)
		end
	end)
	return cases
end
