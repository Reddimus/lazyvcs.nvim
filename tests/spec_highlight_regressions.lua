return function(ctx)
	local api, h = vim.api, ctx.helpers
	local guard = require("lazyvcs.highlighting")
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = {
			"test_core_highlighting_" .. name,
			function()
				local names =
					{ "Normal", "@lsp.type.liveRegression", "LazyVCSRegressionTarget", "LazyVCSRegressionAlias" }
				local definitions = {}
				for _, group in ipairs(names) do
					definitions[group] = api.nvim_get_hl(0, { name = group, create = false })
				end
				local ok, err = xpcall(fn, debug.traceback)
				for _, group in ipairs(names) do
					api.nvim_set_hl(0, group, definitions[group])
				end
				assert(ok, err)
			end,
		}
	end
	local function sample()
		vim.cmd.enew()
		vim.wo.number = false
		vim.wo.relativenumber = false
		vim.wo.signcolumn = "no"
		vim.wo.foldcolumn = "0"
		vim.wo.winhighlight = ""
		vim.o.termguicolors = true
		local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		api.nvim_buf_set_lines(buf, 0, -1, false, { "token" })
		vim.cmd.redraw()
		api.nvim__inspect_cell(1, 0, 0)
		api.nvim_set_hl(0, "Normal", { fg = 0x123456 })
		api.nvim_set_hl(0, "@lsp.type.liveRegression", { fg = 0xff1122, italic = true })
		local marks = api.nvim_create_namespace("lazyvcs-regression-marks")
		api.nvim_buf_set_extmark(
			buf,
			marks,
			0,
			0,
			{ end_col = 5, hl_group = "@lsp.type.liveRegression", priority = 200 }
		)
		return win, buf, marks
	end
	local function color(win)
		vim.cmd.redraw()
		local p = vim.fn.screenpos(win, 1, 1)
		return api.nvim__inspect_cell(1, p.row - 1, p.col - 1)[2].foreground
	end

	add("release_restores_inherited_namespace", function()
		local win = sample()
		local before = api.nvim_get_hl_ns({ winid = win })
		assert(before == -1, "fixture must inherit global namespace")
		guard.apply(win, "syntax")
		guard.release(win)
		assert(api.nvim_get_hl_ns({ winid = win }) == before, "release lost namespace inheritance")
		local ns = api.nvim_create_namespace("lazyvcs-regression-global")
		api.nvim_set_hl(ns, "@lsp.type.liveRegression", { fg = 0x11ff22 })
		api.nvim_set_hl_ns(ns)
		local actual = color(win)
		api.nvim_set_hl_ns(0)
		assert(actual == 0x11ff22, "released window ignored global theme")
	end)
	for _, method in ipairs({ "set", "opt", "local", "replace" }) do
		add("global_mapping_" .. method .. "_stays_clean", function()
			local win = sample()
			local global = api.nvim_get_option_value("winhighlight", { scope = "global" })
			local ok, err = xpcall(function()
				guard.apply(win, "syntax")
				if method == "set" then
					vim.cmd("set winhighlight+=Normal:ErrorMsg")
				elseif method == "opt" then
					vim.opt.winhighlight:append("Normal:ErrorMsg")
				elseif method == "local" then
					vim.cmd("setlocal winhighlight+=Normal:ErrorMsg")
				else
					vim.cmd("set winhighlight=Normal:ErrorMsg")
				end
				api.nvim_exec_autocmds("OptionSet", { pattern = "winhighlight" })
				vim.wait(30)
				guard.release(win)
				assert(
					not api.nvim_get_option_value("winhighlight", { scope = "global" })
						:find("LazyVcsSemanticHidden", 1, true),
					"global default contains private overlay"
				)
				vim.cmd("setlocal winhighlight<")
				assert(
					not vim.wo.winhighlight:find("LazyVcsSemanticHidden", 1, true),
					"ordinary window inherited private overlay"
				)
			end, debug.traceback)
			guard.release(win)
			api.nvim_set_option_value("winhighlight", global, { scope = "global" })
			vim.wo.winhighlight = ""
			assert(ok, err)
		end)
	end
	add("theme_cycle_keeps_semantic_suppression", function()
		local win = sample()
		local ns = api.nvim_create_namespace("lazyvcs-regression-cycle")
		api.nvim_set_hl(ns, "Normal", { fg = 0x123456 })
		api.nvim_set_hl_ns(ns)
		guard.apply(win, "syntax")
		guard.release(win)
		api.nvim_set_hl_ns(0)
		guard.apply(win, "syntax")
		local actual = color(win)
		guard.release(win)
		assert(actual ~= 0xff1122, "semantic suppression stopped after theme cycle")
	end)
	add("self_links_keep_rendered_syntax", function()
		local win, buf, marks = sample()
		api.nvim_buf_clear_namespace(buf, marks, 0, -1)
		local ns = api.nvim_create_namespace("lazyvcs-regression-self")
		api.nvim_set_hl(0, "LazyVCSRegressionTarget", { fg = 0xff1122 })
		api.nvim_set_hl(0, "LazyVCSRegressionAlias", { link = "LazyVCSRegressionTarget" })
		api.nvim_set_hl(ns, "LazyVCSRegressionAlias", { link = "LazyVCSRegressionAlias" })
		api.nvim_win_set_hl_ns(win, ns)
		api.nvim_buf_set_extmark(buf, marks, 0, 0, { end_col = 5, hl_group = "LazyVCSRegressionAlias" })
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		buf = api.nvim_get_current_buf()
		api.nvim_buf_set_extmark(buf, marks, 0, 0, { end_col = 3, hl_group = "LazyVCSRegressionAlias" })
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
		for _, definition in ipairs({
			{ link = "LazyVCSRegressionTarget" },
			{ fg = 0x22aa44, bold = true },
			{ link = "LazyVCSRegressionTarget", fg = 0x22aa44, bold = true },
		}) do
			api.nvim_set_hl(0, "LazyVCSRegressionAlias", definition)
			local before = color(win)
			require("lazyvcs").open()
			ctx.wait_for(function()
				return require("lazyvcs.state").get(buf)
			end, "diff not open")
			local during = color(win)
			require("lazyvcs").close()
			assert(during == before and color(win) == before, "self-link changed rendered color")
		end
		api.nvim_win_set_hl_ns(win, -1)
	end)
	return cases
end
