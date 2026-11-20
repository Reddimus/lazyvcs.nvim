-- A window highlight namespace belongs to the window, so a buffer switch keeps it.
-- Release must restore a pooled namespace even when the window shows another buffer.
return function(ctx)
	local api, h = vim.api, ctx.helpers
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = {
			name,
			function()
				local global_ns, hidden = api.nvim_get_hl_ns({}), vim.o.hidden
				local ok, err = xpcall(fn, debug.traceback)
				api.nvim_set_hl_ns(global_ns)
				vim.o.hidden = true
				h.cleanup()
				vim.cmd("silent! tabonly!")
				vim.cmd("silent! only!")
				api.nvim_win_set_hl_ns(0, -1)
				vim.wo.winhighlight = ""
				vim.o.hidden = hidden
				assert(ok, err)
			end,
		}
	end
	local function pool_name(win)
		local ns = api.nvim_get_hl_ns({ winid = win })
		for name, id in pairs(api.nvim_get_namespaces()) do
			if id == ns then
				return name:match("^lazyvcs%-diff%-highlighting%-%d+$")
			end
		end
	end
	local function describe(win)
		return pool_name(win) or tostring(api.nvim_get_hl_ns({ winid = win }))
	end
	-- A named namespace is an explicit theme, so Diff highlighting uses its pool.
	local function theme(name)
		local ns = api.nvim_create_namespace(name)
		api.nvim_set_hl(ns, "Comment", { fg = 0x00ff00 })
		return ns
	end
	local function scratch(text)
		local buf = api.nvim_create_buf(true, false)
		api.nvim_buf_set_lines(buf, 0, -1, false, { text })
		return buf
	end

	add("test_core_highlighting_release_after_buffer_switch_restores_window_namespace", function()
		local guard = require("lazyvcs.highlighting")
		vim.o.hidden = true
		local win = api.nvim_get_current_win()
		local global, explicit = theme("lazyvcs-test-release-global"), theme("lazyvcs-test-release-window")
		local function applied(owner)
			api.nvim_set_hl_ns(owner == "global" and global or 0)
			api.nvim_win_set_hl_ns(win, owner == "window" and explicit or -1)
			local previous = api.nvim_get_hl_ns({ winid = win })
			local source, target = scratch("source"), scratch("target")
			api.nvim_win_set_buf(win, source)
			guard.apply(win, "syntax", "new")
			assert(pool_name(win), owner .. ": explicit theme did not use a pooled namespace")
			return previous, target
		end
		for _, owner in ipairs({ "global", "window" }) do
			-- With autocmds, BufWinEnter releases the departed state. Without them,
			-- nothing observes the switch before the caller's release.
			for _, prefix in ipairs({ "", "noautocmd " }) do
				local label = owner .. "/" .. (prefix == "" and "autocmd" or "noautocmd")
				local previous, target = applied(owner)
				vim.cmd(prefix .. "buffer " .. target)
				guard.release(win)
				assert(
					api.nvim_get_hl_ns({ winid = win }) == previous,
					label .. ": window kept namespace " .. describe(win) .. ", expected " .. previous
				)
			end
		end
		-- A namespace set after the switch belongs to its new owner.
		local _, target = applied("global")
		vim.cmd("noautocmd buffer " .. target)
		local external = theme("lazyvcs-test-release-external")
		api.nvim_win_set_hl_ns(win, external)
		guard.release(win)
		assert(
			api.nvim_get_hl_ns({ winid = win }) == external,
			"release replaced a later namespace owner with " .. describe(win)
		)
	end)

	add("test_live_diff_close_after_transfer_restores_window_namespace", function()
		local state = require("lazyvcs.state")
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, debounce_ms = 10 })
		vim.o.hidden = true
		local global = theme("lazyvcs-test-release-live")
		-- The control transfer releases on BufWinLeave while the source is still shown.
		for _, shared in ipairs({ false, true }) do
			local label = shared and "source kept visible" or "control"
			local f = h.make_git_transfer_fixture()
			api.nvim_set_hl_ns(global)
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			local win, source = api.nvim_get_current_win(), api.nvim_get_current_buf()
			require("lazyvcs.util").editor_window(win)
			api.nvim_win_set_hl_ns(win, -1)
			vim.cmd("LazyVCS diff open")
			ctx.wait_for(function()
				return state.get(source) ~= nil
			end, label .. ": live diff did not open", 15000)
			local s = assert(state.get(source))
			assert(s.editable_win == win and pool_name(win), label .. ": live diff did not use a pooled namespace")
			if shared then
				-- A second view of the source suppresses BufWinLeave in the diff window.
				local tab = api.nvim_get_current_tabpage()
				vim.cmd("tabnew " .. vim.fn.fnameescape(f.file1))
				api.nvim_set_current_tabpage(tab)
				api.nvim_set_current_win(win)
			end
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			local target = api.nvim_get_current_buf()
			ctx.wait_for(function()
				local live = state.for_window(win)
				return live ~= nil and live ~= s and live.editable_bufnr == target and live.phase == "active"
			end, label .. ": transfer did not settle", 15000)
			vim.cmd("LazyVCS diff close")
			assert(
				api.nvim_get_hl_ns({ winid = win }) == -1,
				label .. ": closed diff window kept namespace " .. describe(win)
			)
			h.cleanup()
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
		end
	end)

	return cases
end
