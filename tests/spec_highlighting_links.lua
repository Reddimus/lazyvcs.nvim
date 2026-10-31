return function(ctx)
	local api, h = vim.api, ctx.helpers
	local function foreground(win)
		vim.cmd.redraw()
		local pos = vim.fn.screenpos(win, 1, 1)
		return api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)[2].foreground
	end
	local function exercise(global_links)
		local guard = require("lazyvcs.highlighting")
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
		vim.o.termguicolors = true
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		vim.wo[win].number, vim.wo[win].relativenumber, vim.wo[win].signcolumn, vim.wo[win].foldcolumn =
			false, false, "no", "0"
		-- Initialize the inspection grid before defining colors on 0.11.
		vim.cmd.redraw()
		api.nvim__inspect_cell(1, 0, 0)
		local ns = api.nvim_create_namespace("lazyvcs-test-link-source")
		api.nvim_set_hl(0, "LazyVCSLinkTarget", { fg = 0xf01234 })
		api.nvim_set_hl(ns, "LazyVCSLinkTarget", { fg = 0x12f034 })
		api.nvim_set_hl(
			ns,
			"LazyVCSLinkSyntax",
			global_links and { link_global = "LazyVCSLinkTarget" } or { link = "LazyVCSLinkTarget" }
		)
		api.nvim_win_set_hl_ns(win, ns)
		local marks = api.nvim_create_namespace("lazyvcs-test-link-marks")
		api.nvim_buf_set_extmark(buf, marks, 0, 0, { end_col = 3, hl_group = "LazyVCSLinkSyntax", priority = 200 })
		local original, mapping, expected = api.nvim_get_hl(ns, {}), vim.wo[win].winhighlight, foreground(win)
		assert(expected == (global_links and 0xf01234 or 0x12f034), "wrong link fixture color")
		require("lazyvcs").open()
		ctx.wait_for(function()
			return require("lazyvcs.state").get(buf) ~= nil
		end, "link diff did not open", 15000)
		assert(
			foreground(win) == expected,
			"syntax color changed during diff: " .. vim.inspect({ before = expected, during = foreground(win) })
		)
		if global_links then
			assert(
				api.nvim_get_hl_ns({ winid = win }) == ns and guard.user_winhighlight(win) == mapping,
				"ambiguous source namespace replaced"
			)
		end
		require("lazyvcs").close()
		assert(foreground(win) == expected and api.nvim_get_hl_ns({ winid = win }) == ns, "source color not restored")
		assert(vim.wo[win].winhighlight == mapping, "source mappings not restored")
		assert(vim.deep_equal(api.nvim_get_hl(ns, {}), original), "source definitions mutated")
		ns = api.nvim_create_namespace("lazyvcs-test-local-link-source")
		api.nvim_set_hl(ns, "LazyVCSLinkTarget", { fg = 0x12f034 })
		api.nvim_win_set_hl_ns(win, ns)
		-- Concrete namespaces and harmless links keep pooled semantic suppression.
		api.nvim_set_hl(ns, "LazyVCSLinkSyntax", { fg = 0xf01234 })
		api.nvim_set_hl(ns, "@lsp.type.lazyvcsLink", { fg = 0x778899 })
		api.nvim_set_hl(ns, "LazyVCSLinkSyntax", { link = "LazyVCSLinkTarget" })
		guard.apply(win, "syntax")
		assert(foreground(win) == 0x12f034, "ordinary local link changed color")
		if global_links then
			assert(api.nvim_get_hl_ns({ winid = win }) == ns, "divergent ordinary link lost its source")
			local token = api.nvim_buf_set_extmark(
				buf,
				marks,
				0,
				0,
				{ end_col = 3, hl_group = "@lsp.type.lazyvcsLink", priority = 300 }
			)
			assert(foreground(win) == 0x778899, "source-preserving mode hid semantic overlay")
			api.nvim_buf_del_extmark(buf, marks, token)
		end
		guard.release(win)
		api.nvim_set_hl(ns, "LazyVCSLinkSyntax", { fg = 0xf01234 })
		for _, mode in ipairs({ "concrete", "unmodified", "identical", "chain" }) do
			if mode ~= "concrete" then
				api.nvim_set_hl(ns, "LazyVCSLinkTarget", { fg = 0xf01234 })
				local target = mode == "unmodified" and "LazyVCSLinkGlobal" or "LazyVCSLinkTarget"
				api.nvim_set_hl(0, "LazyVCSLinkGlobal", { fg = 0xf01234 })
				api.nvim_set_hl(ns, "LazyVCSLinkSyntax", { link = target })
			end
			if mode == "chain" then
				api.nvim_set_hl(0, "LazyVCSLinkMiddle", { link = "LazyVCSLinkTarget" })
				api.nvim_set_hl(ns, "LazyVCSLinkMiddle", { link = "LazyVCSLinkTarget" })
				api.nvim_set_hl(ns, "LazyVCSLinkSyntax", { link = "LazyVCSLinkMiddle" })
			end
			guard.apply(win, "syntax")
			local pooled = api.nvim_get_hl_ns({ winid = win })
			assert(pooled ~= ns, mode .. " unnecessarily preserved source namespace")
			assert(
				next(api.nvim_get_hl(pooled, { name = "@lsp.type.lazyvcsLink" })) == nil,
				"pooled semantic overlay retained"
			)
			assert(foreground(win) == 0xf01234, "pooled link color changed")
			guard.release(win)
		end
		-- A divergent link anywhere in the chain must trigger refresh fallback.
		guard.apply(win, "syntax")
		local pooled = api.nvim_get_hl_ns({ winid = win })
		api.nvim_set_hl(ns, "LazyVCSLinkTarget", { fg = 0x12f034 })
		api.nvim_exec_autocmds("ColorScheme", {})
		vim.wait(50)
		assert(
			api.nvim_get_hl_ns({ winid = win }) == (global_links and ns or pooled),
			"refresh did not re-evaluate link ambiguity"
		)
		if global_links then
			api.nvim_exec_autocmds("LspTokenUpdate", { buffer = buf, data = { token = { type = "lazyvcsLink" } } })
			assert(
				api.nvim_get_hl(ns, { name = "@lsp.type.lazyvcsLink" }).fg == 0x778899,
				"preserved semantic group overwritten"
			)
			api.nvim_set_hl(ns, "LazyVCSLinkTarget", { fg = 0xf01234 })
			guard.refresh(win)
			assert(api.nvim_get_hl_ns({ winid = win }) == pooled, "released pool slot not reused")
			api.nvim_set_hl(ns, "LazyVCSLinkTarget", { fg = 0x12f034 })
			guard.refresh(win)
		end
		local external = api.nvim_create_namespace("lazyvcs-test-link-external")
		api.nvim_win_set_hl_ns(win, external)
		guard.refresh(win)
		guard.release(win)
		assert(api.nvim_get_hl_ns({ winid = win }) == external, "external namespace owner overwritten")
		api.nvim_win_set_hl_ns(win, ns)
		guard.apply(win, "editor")
		assert(api.nvim_get_hl_ns({ winid = win }) == ns, "editor policy replaced namespace")
		assert(foreground(win) == 0x12f034, "editor policy changed rendered color")
		api.nvim_win_set_hl_ns(win, -1)
		local compare = require("lazyvcs.compare")
		local review = assert(compare.open({ editable = false, path = f.root, base = "HEAD" }))
		ctx.wait_for(function()
			return review.preview_result ~= nil
		end, "link review did not load", 15000)
		for _, pane in ipairs({ review.leftwin, review.rightwin }) do
			guard.release(pane)
			api.nvim_win_set_hl_ns(pane, ns)
		end
		compare.refresh(review)
		ctx.wait_for(function()
			return review.preview_result ~= nil and review.preview_job == nil
		end, "link review did not refresh", 15000)
		for _, pane in ipairs({ review.leftwin, review.rightwin }) do
			assert(
				(api.nvim_get_hl_ns({ winid = pane }) == ns) == global_links,
				"Compare chose the wrong namespace mode"
			)
		end
		compare.close(review)
	end
	return {
		{
			"test_core_highlighting_global_only_links_preserve_rendered_color",
			function()
				if not vim.env.LAZYVCS_LINK_CHILD then
					local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
					local result = vim.system(
						{ vim.v.progpath, "--headless", "-u", "NONE", "-l", root .. "/tests/run.lua" },
						{
							text = true,
							env = {
								LAZYVCS_TEST_GROUP = "core",
								LAZYVCS_TEST_CASE = "test_core_highlighting_global_only_links_preserve_rendered_color",
								LAZYVCS_LINK_CHILD = "1",
							},
						}
					)
						:wait(30000)
					assert(
						result.code == 0 and (result.signal or 0) == 0,
						(result.stdout or "") .. (result.stderr or "")
					)
					return
				end
				local capability = api.nvim_create_namespace("lazyvcs-test-link-capability")
				local supported = pcall(api.nvim_set_hl, capability, "LazyVCSLinkProbe", { link_global = "Normal" })
				local ok, err = xpcall(function()
					exercise(supported)
				end, debug.traceback)
				for _, win in ipairs(api.nvim_list_wins()) do
					require("lazyvcs.highlighting").release(win)
				end
				h.cleanup()
				assert(ok, err)
			end,
		},
	}
end
