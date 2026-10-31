return function()
	local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
	local function check(lowercase)
		-- Highlight IDs keep their first spelling process-wide. The source palette
		-- must therefore be registered before the module creates global defaults.
		local channel = vim.fn.jobstart(
			{ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" },
			{ rpc = true }
		)
		assert(channel > 0)
		local ok, result = pcall(function()
			vim.rpcrequest(channel, "nvim_ui_attach", 120, 36, { rgb = true })
			assert(
				vim.wait(2000, function()
					return vim.rpcrequest(channel, "nvim_eval", "v:vim_did_enter") == 1
				end, 10),
				"palette child did not finish startup"
			)
			return vim.rpcrequest(
				channel,
				"nvim_exec_lua",
				[[
				local root, lowercase = ...
				local api = vim.api
				vim.opt.runtimepath:prepend(root)
				package.path = root .. "/lua/?.lua;" .. package.path
				vim.o.termguicolors = true
				vim.cmd.tabnew()
				local ns = api.nvim_create_namespace("lazyvcs-test-first-public-palette")
				local name = lowercase and "lazyvcsdiffremoved" or "LazyVcsDiffRemoved"
				api.nvim_set_hl(ns, name, { fg = 0x2266aa })
				api.nvim_set_hl(ns, "Normal", { fg = 0xccddee })
				api.nvim_set_hl(0, "DiffDelete", { fg = 0xaa4422 })
				api.nvim_set_hl(0, "DiffAdd", { fg = 0x668899 })
				assert(api.nvim_get_hl(ns, {})[name].fg == 0x2266aa, "first palette spelling was not retained")
				local highlighting = require("lazyvcs.highlighting")
				local win = api.nvim_get_current_win()
				vim.wo.number, vim.wo.relativenumber, vim.wo.signcolumn, vim.wo.foldcolumn = false, false, "no", "0"
				api.nvim_set_option_value("fillchars", "eob:~", { win = win, scope = "local" })
				api.nvim_set_option_value("winhighlight", "", { win = win, scope = "local" })
				api.nvim_buf_set_lines(0, 0, -1, false, { "anchor", "added" })
				vim.cmd.vnew()
				api.nvim_buf_set_lines(0, 0, -1, false, { "anchor" })
				vim.cmd.diffthis()
				api.nvim_win_call(win, function() vim.cmd.diffthis() end)
				api.nvim_win_set_hl_ns(win, ns)
				highlighting.apply(win, "editor", "old", { enabled = true, filler = "/", removed = true })
				api.nvim_win_call(win, function() vim.cmd.diffupdate() end)
				vim.cmd.redraw()
				local active = api.nvim_get_hl_ns({ winid = win })
				local definition = api.nvim_get_hl(active, {})["DiffAdd"]
				assert(api.nvim_get_hl(ns, {})[name].fg == 0x2266aa, "apply changed the source palette")
				local pos = vim.fn.screenpos(win, 2, 1)
				local color = api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)[2].foreground
				highlighting.release(win)
				assert(api.nvim_get_hl_ns({ winid = win }) == ns, "release changed the explicit source namespace")
				assert(api.nvim_get_option_value("winhighlight", { win = win, scope = "local" }) == "", "release left an owned mapping")
				assert(api.nvim_get_option_value("fillchars", { win = win, scope = "local" }) == "eob:~", "release changed the original filler")
				assert(definition.fg == 0x2266aa, "derived default replaced namespace palette: " .. tostring(definition.fg) .. ", pixel: " .. tostring(color))
				assert(color == 0x2266aa, "rendered old-side line lost namespace palette: " .. tostring(color))
				return color
			]],
				{ root, lowercase }
			)
		end)
		pcall(vim.rpcnotify, channel, "nvim_command", "qall!")
		local status = vim.fn.jobwait({ channel }, 5000)[1]
		if status == -1 then
			vim.fn.jobstop(channel)
		end
		assert(status ~= -1, "palette child did not exit normally")
		assert(ok, result)
	end
	return {
		{
			"test_core_palette_source_case_canonical_first",
			function()
				check(false)
			end,
		},
		{
			"test_core_palette_source_case_lowercase_first",
			function()
				check(true)
			end,
		},
	}
end
