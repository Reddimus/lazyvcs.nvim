return function(ctx)
	local api, h = vim.api, ctx.helpers
	local guard = require("lazyvcs.highlighting")
	local cases, cleanups = {}, {}
	local function settle()
		vim.wait(40, function()
			return false
		end, 5)
	end
	local function wait(fn)
		ctx.wait_for(fn, "focus-resume fixture", 15000)
	end
	local function raw(win)
		return api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
	end
	local function defer_cleanup(fn)
		cleanups[#cleanups + 1] = fn
	end
	local function highlight(name, value)
		local old = api.nvim_get_hl(0, { name = name, create = false })
		defer_cleanup(function()
			-- Restore the API's original definition without changing its attributes.
			---@diagnostic disable-next-line: param-type-mismatch
			api.nvim_set_hl(0, name, old)
		end)
		api.nvim_set_hl(0, name, value)
	end
	local function add(name, fn)
		cases[#cases + 1] = {
			"test_core_diff_style_resume_" .. name,
			function()
				local anchor_tab, anchor_win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
				local anchor = {
					filler = raw(anchor_win),
					mapping = vim.wo[anchor_win].winhighlight,
					namespace = api.nvim_get_hl_ns({ winid = anchor_win }),
				}
				local get = api.nvim_get_hl
				local global = api.nvim_get_hl_ns({})
				local filler = vim.go.fillchars
				local colors = vim.o.termguicolors
				cleanups = {}
				local ok, err = xpcall(fn, function(e)
					return type(e) == "table" and e or debug.traceback(e, 2)
				end)
				api.nvim_get_hl = get
				for i = #cleanups, 1, -1 do
					pcall(cleanups[i])
				end
				api.nvim_set_hl_ns(global)
				h.cleanup()
				vim.go.fillchars = filler
				if api.nvim_tabpage_is_valid(anchor_tab) then
					api.nvim_set_current_tabpage(anchor_tab)
				end
				if api.nvim_win_is_valid(anchor_win) then
					api.nvim_set_current_win(anchor_win)
				end
				vim.cmd("silent! tabonly!")
				vim.cmd("silent! only!")
				if raw(0) ~= anchor.filler then
					vim.wo.fillchars = anchor.filler
				end
				if vim.wo.winhighlight ~= anchor.mapping then
					vim.wo.winhighlight = anchor.mapping
				end
				if api.nvim_get_hl_ns({ winid = 0 }) ~= anchor.namespace then
					api.nvim_win_set_hl_ns(0, anchor.namespace)
				end
				vim.o.termguicolors = colors
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	local function opened()
		vim.cmd.tabnew()
		api.nvim_set_hl_ns(0)
		api.nvim_win_set_hl_ns(0, -1)
		vim.wo.winhighlight = ""
		vim.go.fillchars = ""
		vim.wo.fillchars = ""
		vim.o.termguicolors = true
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
			source_control = { enabled = false },
			debounce_ms = 10,
		})
		local f = h.make_git_fixture()
		h.write_file(f.file, "one\nthree\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local buf = api.nvim_get_current_buf()
		require("lazyvcs").open()
		wait(function()
			local s = require("lazyvcs.state").get(buf)
			return s and s.phase == "active"
		end)
		local s = assert(require("lazyvcs.state").get(buf))
		settle()
		api.nvim_set_current_win(s.base_win)
		settle()
		return s
	end
	local function count_scans()
		local original, counts = api.nvim_get_hl, { full = 0 }
		---@diagnostic disable-next-line: duplicate-set-field
		api.nvim_get_hl = function(ns, opts)
			if not opts.name then
				counts.full = counts.full + 1
			end
			return original(ns, opts)
		end
		return counts
	end
	local function leave(s, fn)
		local fired = false
		local id = api.nvim_create_autocmd("BufLeave", {
			buffer = s.base_bufnr,
			nested = true,
			callback = function()
				if not fired then
					fired = true
					fn(s.base_win)
				end
			end,
		})
		defer_cleanup(function()
			pcall(api.nvim_del_autocmd, id)
		end)
		api.nvim_set_current_win(s.editable_win)
		settle()
		assert(fired, "actual BufLeave did not fire")
	end
	local function cell(win, line)
		vim.cmd.redraw()
		local p = vim.fn.screenpos(win, line or 2, 1)
		assert(p.row > 0 and p.col > 0, "fixture cell not visible")
		return api.nvim__inspect_cell(1, p.row - 1, p.col - 1)[2]
	end
	add("unchanged_forty_transitions_preserve_exact_overlay_without_scans", function()
		local s = opened()
		local before = {}
		for _, win in ipairs({ s.base_win, s.editable_win }) do
			before[win] = {
				mapping = vim.wo[win].winhighlight,
				namespace = api.nvim_get_hl_ns({ winid = win }),
				filler = raw(win),
			}
		end
		local scans = count_scans()
		for _ = 1, 20 do
			api.nvim_set_current_win(s.editable_win)
			api.nvim_set_current_win(s.base_win)
			settle()
		end
		assert(scans.full == 0, "unchanged focus enumerated highlight graph " .. scans.full .. " times")
		for win, old in pairs(before) do
			assert(vim.wo[win].winhighlight == old.mapping, "active overlay identity changed")
			assert(api.nvim_get_hl_ns({ winid = win }) == old.namespace, "active namespace identity changed")
			assert(raw(win) == old.filler, "active filler changed")
		end
	end)
	add("colorscheme_invalidation_updates_rendered_removed_color", function()
		local s = opened()
		highlight("DiffDelete", { fg = 0x123abc, bg = 0x654321 })
		local scans = count_scans()
		leave(s, function()
			api.nvim_exec_autocmds("ColorScheme", {})
		end)
		assert(scans.full > 0, "actual invalidation reused stale overlay")
		assert(api.nvim_get_hl(0, { name = "LazyVcsDiffRemoved", link = false }).bg == 0x654321)
		assert(cell(s.base_win).background == 0x654321, "rendered removed color stale")
	end)
	for _, event in ipairs({ "FileType", "LspAttach", "LspTokenUpdate" }) do
		add("fresh_semantic_overlay_on_" .. event, function()
			local s = opened()
			local name = "@lsp.type.focus_" .. event:lower()
			local scans = count_scans()
			leave(s, function()
				highlight(name, { fg = 0xf01234 })
				if event == "LspTokenUpdate" then
					api.nvim_exec_autocmds(event, {
						buffer = s.base_bufnr,
						data = { token = { type = "focus_" .. event:lower(), modifiers = {} } },
					})
				else
					api.nvim_exec_autocmds(
						event,
						{ buffer = s.base_bufnr, data = event == "LspAttach" and { client_id = 123456 } or nil }
					)
				end
			end)
			assert(
				vim.wo[s.base_win].winhighlight:find(name .. ":LazyVcsSemanticHidden", 1, true),
				"new semantic token not suppressed"
			)
			assert(scans.full > 0, "actual invalidation did not refresh graph")
		end)
	end
	add("raw_user_mapping_change_during_suspension_is_preserved", function()
		local s = opened()
		highlight("FocusResumeUser", { fg = 0x0a12cd, bg = 0x765432 })
		local scans = count_scans()
		leave(s, function(win)
			vim.wo[win].winhighlight = "DiffAdd:FocusResumeUser"
		end)
		assert(scans.full > 0 and guard.user_winhighlight(s.base_win) == "DiffAdd:FocusResumeUser")
		assert(cell(s.base_win).background == 0x765432, "user addition colors overwritten")
	end)
	add("external_window_namespace_takeover_is_not_overwritten", function()
		local s = opened()
		local ns = api.nvim_create_namespace("focus-resume-external")
		api.nvim_set_hl(ns, "Normal", { fg = 0x12ab34 })
		leave(s, function(win)
			api.nvim_win_set_hl_ns(win, ns)
		end)
		assert(api.nvim_get_hl_ns({ winid = s.base_win }) == ns, "external namespace overwritten")
		assert(cell(s.base_win, 1).foreground == 0x12ab34, "external namespace color stale")
	end)
	add("changed_global_namespace_updates_actual_source_colors", function()
		local s = opened()
		local ns = api.nvim_create_namespace("focus-resume-global")
		api.nvim_set_hl(ns, "Normal", { fg = 0x18ab45 })
		local scans = count_scans()
		leave(s, function()
			api.nvim_set_hl_ns(ns)
		end)
		assert(scans.full > 0 and api.nvim_get_hl_ns({}) == ns)
		assert(cell(s.base_win, 1).foreground == 0x18ab45, "global namespace source color stale")
	end)
	for _, setting in ipairs({ "local_filler", "global_filler", "style", "role" }) do
		add("changed_" .. setting .. "_rejects_cached_resettlement", function()
			local s = opened()
			local scans = count_scans()
			leave(s, function(win)
				if setting == "local_filler" then
					vim.wo[win].fillchars = "eob:!,diff:x"
				elseif setting == "global_filler" then
					vim.go.fillchars = "eob:!,diff:z"
				elseif setting == "style" then
					s.opts.diff_style.filler = "."
					s.opts.diff_style.removed = false
				else
					guard.apply(win, "syntax", "new", s.opts.diff_style)
				end
			end)
			assert(scans.full > 0, "changed state used cached overlay")
			if setting == "local_filler" then
				assert(raw(s.base_win) == "eob:!,diff:x")
			elseif setting == "global_filler" then
				assert(raw(s.base_win) == "" and vim.go.fillchars == "eob:!,diff:z")
			elseif setting == "style" then
				assert(raw(s.base_win):find("diff:.", 1, true))
				assert(not vim.wo[s.base_win].winhighlight:find("DiffAdd:LazyVcsDiffRemoved", 1, true))
			else
				assert(not vim.wo[s.base_win].winhighlight:find("DiffAdd:LazyVcsDiffRemoved", 1, true))
			end
		end)
	end
	for _, setting in ipairs({ "style", "global_namespace", "global_filler" }) do
		add("already_changed_" .. setting .. "_before_departure_is_not_cached", function()
			local s = opened()
			local scans = count_scans()
			if setting == "style" then
				s.opts.diff_style.filler = "."
				s.opts.diff_style.removed = false
			elseif setting == "global_filler" then
				vim.go.fillchars = "eob:!,diff:z"
			else
				local ns = api.nvim_create_namespace("focus-resume-global-before")
				api.nvim_set_hl(ns, "Normal", { fg = 0x19ab46 })
				api.nvim_set_hl_ns(ns)
			end
			api.nvim_set_current_win(s.editable_win)
			settle()
			assert(scans.full > 0, "already changed state was captured as an unchanged overlay")
			if setting == "style" then
				assert(raw(s.base_win):find("diff:.", 1, true))
			elseif setting == "global_filler" then
				assert(raw(s.base_win) == "" and vim.go.fillchars == "eob:!,diff:z")
			else
				assert(cell(s.base_win, 1).foreground == 0x19ab46)
			end
		end)
	end

	add("queued_resume_cannot_rebind_or_reopen_closed_owner", function()
		vim.cmd.tabnew()
		local win = api.nvim_get_current_win()
		api.nvim_win_set_hl_ns(win, -1)
		vim.wo[win].winhighlight = ""
		vim.wo[win].fillchars = ""
		guard.apply(win, "editor", "old", { enabled = true, filler = "/", removed = true })
		vim.cmd.vnew()
		guard.release(win)
		local buf = api.nvim_create_buf(false, true)
		api.nvim_win_set_buf(win, buf)
		guard.apply(win, "editor", "new", { enabled = true, filler = "x", removed = false })
		local mapping, ns = vim.wo[win].winhighlight, api.nvim_get_hl_ns({ winid = win })
		local scans = count_scans()
		settle()
		assert(scans.full == 0, "late old resume refreshed replacement owner")
		assert(
			vim.wo[win].winhighlight == mapping
				and api.nvim_get_hl_ns({ winid = win }) == ns
				and raw(win):find("diff:x", 1, true)
		)
		guard.release(win)
		api.nvim_win_close(win, true)
		settle()
		assert(not api.nvim_win_is_valid(win))
	end)
	add("multiple_pending_invalidations_coalesce_and_remain_fresh", function()
		local s = opened()
		local name = "@lsp.type.focus_coalesced"
		local scans = count_scans()
		leave(s, function()
			highlight(name, { fg = 0xc01234 })
			for _ = 1, 3 do
				api.nvim_exec_autocmds("FileType", { buffer = s.base_bufnr })
			end
		end)
		assert(scans.full > 0 and scans.full <= 4, "actual invalidations did not coalesce: " .. scans.full)
		assert(vim.wo[s.base_win].winhighlight:find(name .. ":LazyVcsSemanticHidden", 1, true))
		local before = scans.full
		for _ = 1, 3 do
			api.nvim_set_current_win(s.base_win)
			api.nvim_set_current_win(s.editable_win)
		end
		settle()
		assert(scans.full == before, "settled invalidation left focus cache unusable")
	end)
	return cases
end
