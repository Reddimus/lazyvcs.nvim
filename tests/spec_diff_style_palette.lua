return function(ctx)
	local api, h = vim.api, ctx.helpers
	local g = require("lazyvcs.highlighting")
	local cases = {}
	local function raw(win)
		return api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
	end
	local function private(value)
		return value:lower():find("lazyvcsoverlay", 1, true)
			or value:lower():find("lazyvcssemantichidden", 1, true)
			or value:lower():find("lazyvcsdiffowner", 1, true)
	end
	local function add(name, fn)
		cases[#cases + 1] = {
			"test_core_diff_style_palette_" .. name,
			function()
				local saved = {}
				for _, name in ipairs({ "Normal", "DiffAdd", "DiffDelete", "LazyVcsDiffFiller", "LazyVcsDiffRemoved" }) do
					saved[name] = api.nvim_get_hl(0, { name = name, create = false })
				end
				local filler, global, colors = vim.go.fillchars, api.nvim_get_hl_ns({}), vim.o.termguicolors
				vim.cmd.tabnew()
				local tab = api.nvim_get_current_tabpage()
				vim.wo.fillchars, vim.wo.winhighlight = "", ""
				local ok, err = xpcall(fn, debug.traceback)
				if api.nvim_tabpage_is_valid(tab) then
					for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
						pcall(g.release, win)
						if vim.wo[win].diff then
							require("lazyvcs.util").diff_off(win)
						end
					end
					api.nvim_set_current_tabpage(tab)
					vim.cmd.tabclose({ bang = true })
				end
				local defaults = false
				for name, value in pairs(saved) do
					if name:match("^LazyVcsDiff") and (value.default or not next(value)) then
						-- Recreate module-owned defaults after this test's explicit overrides.
						api.nvim_set_hl(0, name, {})
						defaults = true
					else
						---@diagnostic disable-next-line: param-type-mismatch
						api.nvim_set_hl(0, name, vim.tbl_extend("force", value, { force = true }))
					end
				end
				api.nvim_set_hl_ns(global)
				if defaults then
					api.nvim_exec_autocmds("ColorScheme", {})
				end
				vim.go.fillchars = filler
				vim.o.termguicolors = colors
				assert(ok, err)
			end,
		}
	end
	local style = { enabled = true, filler = "/", removed = true }
	local function settle()
		vim.wait(40, function()
			return false
		end, 5)
	end
	local function file()
		local path = h.tempdir() .. "/palette.txt"
		h.write_file(path, "palette contents\n")
		vim.cmd.edit(vim.fn.fnameescape(path))
		vim.bo.bufhidden = "hide"
		return path
	end
	for _, pair in ipairs({ { "DiffDelete", "LazyVcsDiffFiller" }, { "DiffAdd", "LazyVcsDiffRemoved" } }) do
		for _, when in ipairs({ "before", "during", "after" }) do
			add(pair[1] .. "_user_" .. when .. "_view", function()
				file()
				local win = api.nvim_get_current_win()
				local requested = pair[1] .. ":" .. pair[2] .. ",Normal:NormalNC"
				if when == "before" then
					vim.cmd("setlocal winhighlight=" .. requested)
				end
				g.apply(win, "editor", "old", style)
				if when == "after" then
					g.release(win)
				end
				if when ~= "before" then
					vim.cmd("setlocal winhighlight=" .. requested)
				end
				settle()
				assert(g.user_winhighlight(win) == requested, "fresh public preference lost to overlay ownership")
				g.release(win)
				assert(vim.wo[win].winhighlight == requested)
				vim.cmd.split()
				assert(vim.wo.winhighlight == requested, "native copy lost explicit public preference")
				api.nvim_set_current_win(win)
				assert(vim.wo.winhighlight == requested, "focus cleanup removed a public preference")
			end)
		end
	end
	add("public_live_close_split_and_session_projection", function()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		local session = ctx.open_diff()
		local requested = "DiffDelete:LazyVcsDiffFiller,DiffAdd:LazyVcsDiffRemoved"
		vim.cmd("setlocal winhighlight=" .. requested)
		settle()
		local layout, token = require("lazyvcs.layout"), {}
		layout.prepare_sessions_save({ session }, token)
		assert(vim.wo[win].winhighlight == requested, "session projection lost public palette")
		for _, record in pairs(token.windows) do
			assert(not private(record.projected or ""))
		end
		local _, errors = layout.finish_sessions_save(token)
		assert(#errors == 0)
		require("lazyvcs.actions").close(session)
		assert(api.nvim_win_get_buf(win) == buf and vim.bo[buf].buftype == "" and vim.bo[buf].buflisted)
		vim.cmd.split()
		assert(vim.wo.winhighlight == requested)
		api.nvim_set_current_win(win)
		assert(vim.wo.winhighlight == requested)
	end)
	add("unmarked_color_only_copy_and_hidden_restore", function()
		local path = file()
		local win = api.nvim_get_current_win()
		vim.wo.fillchars = "eob:!,diff:x"
		vim.wo.winhighlight = "Normal:NormalNC"
		g.apply(win, "editor", "old", { enabled = true, filler = "auto", removed = true })
		assert(not vim.wo[win].winhighlight:find("LazyVcsDiffOwner", 1, true), "fixture must have no filler marker")
		vim.cmd.split()
		assert(vim.wo.winhighlight == "Normal:NormalNC" and raw(0) == "eob:!,diff:x")
		api.nvim_set_current_win(win)
		api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
		g.release(win)
		vim.cmd.edit(vim.fn.fnameescape(path))
		assert(vim.wo.winhighlight == "Normal:NormalNC" and raw(win) == "eob:!,diff:x")
	end)
	add("case_insensitive_private_cleanup_and_public_preservation", function()
		file()
		local win = api.nvim_get_current_win()
		vim.wo.winhighlight = "DiffAdd:lazyvcsdiffremoved,DiffDelete:lazyvcsdifffiller,Normal:NormalNC"
		local user = vim.wo.winhighlight .. ",LazyVcsDiffOwner:WarningMsg,ErrorMsg:LazyVcsOverlayFillerCustom"
		vim.wo.winhighlight = user
		vim.cmd.split()
		local clone = api.nvim_get_current_win()
		assert(vim.wo.winhighlight == user)
		vim.wo.winhighlight = user
			.. ",ErrorMsg:lazyvcsoverlayfiller,WarningMsg:lazyvcsoverlayremoved,LineNr:lazyvcssemantichidden,lazyvcsdiffowner:lazyvcsdiffowner999999"
		api.nvim_set_current_win(win)
		api.nvim_set_current_win(clone)
		assert(vim.wo.winhighlight == user, "exact lowercase private entries survived native cleanup")
	end)
	add("public_only_focus_uses_no_namespace_graph_enumeration", function()
		file()
		vim.wo.winhighlight = "DiffDelete:LazyVcsDiffFiller,DiffAdd:LazyVcsDiffRemoved"
		local win = api.nvim_get_current_win()
		vim.cmd.split()
		local other = api.nvim_get_current_win()
		local get, scans = api.nvim_get_hl, 0
		-- Meter the real API without changing any returned definitions.
		---@diagnostic disable-next-line: duplicate-set-field
		api.nvim_get_hl = function(ns, opts)
			if not opts.name and not opts.id then
				scans = scans + 1
			end
			return get(ns, opts)
		end
		local ok, err = xpcall(function()
			for _ = 1, 3 do
				api.nvim_set_current_win(win)
				api.nvim_set_current_win(other)
			end
		end, debug.traceback)
		api.nvim_get_hl = get
		assert(ok, err)
		assert(scans == 0, "public-only mapping caused namespace graph scans")
	end)
	for _, explicit in ipairs({ false, true }) do
		for _, target in ipairs({ "LazyVcsDiffFiller", "lazyvcsdifffiller" }) do
			for _, source in ipairs({ "DiffAdd", "diffadd" }) do
				for _, role in ipairs({ "old", "new" }) do
					add(
						"user_palette_color_"
							.. (explicit and "namespace" or "global")
							.. "_"
							.. source
							.. "_"
							.. role
							.. (target == "LazyVcsDiffFiller" and "" or "_lower_target"),
						function()
							file()
							local win = api.nvim_get_current_win()
							api.nvim_buf_set_lines(0, 0, -1, false, { "anchor", "added" })
							vim.cmd.vnew()
							api.nvim_buf_set_lines(0, 0, -1, false, { "anchor" })
							vim.cmd.diffthis()
							api.nvim_win_call(win, function()
								vim.cmd.diffthis()
							end)
							vim.o.termguicolors = true
							api.nvim_set_hl(0, "LazyVcsDiffFiller", { fg = 0x2266aa })
							api.nvim_set_hl(0, "LazyVcsDiffRemoved", { fg = 0xaa4422 })
							local ns
							if explicit then
								api.nvim_set_hl(0, "LazyVcsDiffFiller", { fg = 0x885511 })
								ns = api.nvim_create_namespace("palette-explicit-user-" .. source .. role)
								api.nvim_set_hl(ns, "Normal", { fg = 0xccddee })
								api.nvim_set_hl(ns, "LazyVcsDiffFiller", { fg = 0x2266aa })
								api.nvim_set_hl(ns, "LazyVcsDiffRemoved", { fg = 0xaa4422 })
								api.nvim_win_set_hl_ns(win, ns)
							end
							local requested = source .. ":" .. target
							vim.wo[win].winhighlight = requested
							g.apply(win, "editor", role, style)
							api.nvim_win_call(win, function()
								vim.cmd.diffupdate()
							end)
							vim.cmd.redraw()
							local pos = vim.fn.screenpos(win, 2, 1)
							local color = api.nvim__inspect_cell(1, pos.row - 1, pos.col - 1)[2].foreground
							assert(
								color == 0x2266aa,
								"explicit native DiffAdd color mapping was overridden: " .. tostring(color)
							)
							g.release(win)
							assert(vim.wo[win].winhighlight == requested)
							if ns then
								assert(api.nvim_get_hl_ns({ winid = win }) == ns)
							end
						end
					)
				end
			end
		end
	end

	add("pooled_in_view_user_mapping_keeps_same_copy_marker", function()
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
			diff_highlighting = "editor",
			diff_style = style,
		})
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local win = api.nvim_get_current_win()
		vim.wo.fillchars = ""
		local ns = api.nvim_create_namespace("palette-live-pool-user")
		api.nvim_set_hl(ns, "Normal", { fg = 0xaabbcc })
		api.nvim_win_set_hl_ns(win, ns)
		local session = ctx.open_diff()
		local marker = assert(vim.wo[win].winhighlight:match("LazyVcsDiffOwner:LazyVcsDiffOwner%d+"))
		local user = "DiffAdd:LazyVcsDiffRemoved,DiffDelete:LazyVcsDiffFiller"
		vim.cmd("setlocal winhighlight=" .. user)
		settle()
		local active_marker = vim.wo[win].winhighlight:match("LazyVcsDiffOwner:LazyVcsDiffOwner%d+")
		vim.cmd.split()
		local clone = api.nvim_get_current_win()
		assert(
			raw(clone) == "" and vim.wo[clone].winhighlight == user,
			"pooled user edit leaked filler into a native copy"
		)
		assert(active_marker == marker, "refresh replaced or lost the existing filler record marker")
		local layout, token = require("lazyvcs.layout"), {}
		layout.prepare_sessions_save({ session }, token)
		assert(vim.wo[win].winhighlight == user and raw(win) == "")
		for _, record in pairs(token.windows) do
			assert(not private(record.projected or ""))
		end
		local _, errors = layout.finish_sessions_save(token)
		assert(#errors == 0)
		require("lazyvcs.actions").close(session)
		assert(raw(win) == "" and raw(clone) == "")
		assert(vim.wo[win].winhighlight == user and vim.wo[clone].winhighlight == user)
		assert(api.nvim_get_hl_ns({ winid = win }) == ns)
	end)
	for _, replace in ipairs({ false, true }) do
		add("pooled_marker_setter_" .. (replace and "replacement" or "release"), function()
			file()
			local win = api.nvim_get_current_win()
			local ns = api.nvim_create_namespace("palette-marker-setter-" .. tostring(replace))
			api.nvim_set_hl(ns, "Normal", { fg = 0xaabbcc })
			api.nvim_win_set_hl_ns(win, ns)
			g.apply(win, "editor", "old", style)
			vim.cmd("setlocal winhighlight=DiffDelete:LazyVcsDiffFiller")
			local fired = 0
			local hook = api.nvim_create_autocmd("OptionSet", {
				pattern = "winhighlight",
				nested = true,
				callback = function()
					if fired == 0 and api.nvim_get_current_win() == win then
						fired = fired + 1
						g.release(win)
						if replace then
							g.apply(win, "editor", "new", { enabled = true, filler = ".", removed = false })
						end
					end
				end,
			})
			local ok, err = xpcall(function()
				ctx.wait_for(function()
					return fired == 1
				end, "owned marker was not republished", 2000)
				settle()
				assert(g.user_fillchars(win) == "")
				if replace then
					assert(raw(win):find("diff:.", 1, true))
				end
				g.release(win)
				assert(raw(win) == "" and vim.wo[win].winhighlight == "DiffDelete:LazyVcsDiffFiller")
			end, debug.traceback)
			api.nvim_del_autocmd(hook)
			assert(ok, err)
		end)
	end

	for _, mode in ipairs({ "initial", "refresh", "public", "noop" }) do
		add("marker_overwrite_" .. mode, function()
			local win = api.nvim_get_current_win()
			local ns = api.nvim_create_namespace("palette-overwrite-" .. mode)
			api.nvim_set_hl(ns, "Normal", { fg = 0xaabbcc })
			local user = "DiffAdd:LazyVcsDiffRemoved,DiffDelete:LazyVcsDiffFiller"
			local armed, fired, hook, session = true, 0, nil, nil
			local function install()
				hook = api.nvim_create_autocmd("OptionSet", {
					pattern = "winhighlight",
					nested = true,
					callback = function()
						if
							armed
							and api.nvim_get_current_win() == win
							and vim.wo[win].winhighlight:find("LazyVcsDiffOwner:", 1, true)
						then
							armed, fired = false, fired + 1
							if mode ~= "noop" then
								vim.cmd("setlocal winhighlight=" .. user)
							end
						end
					end,
				})
			end
			local ok, err = xpcall(function()
				if mode == "public" then
					require("lazyvcs").setup({
						use_gitsigns = false,
						signs = { enabled = false },
						blame = { persist = false },
						diff_highlighting = "editor",
						diff_style = style,
					})
					local f = h.make_git_fixture()
					vim.cmd.edit(vim.fn.fnameescape(f.file))
				else
					file()
				end
				api.nvim_win_set_hl_ns(win, ns)
				vim.wo[win].fillchars = ""
				if mode ~= "refresh" then
					install()
				end
				if mode == "public" then
					session = ctx.open_diff()
				else
					g.apply(win, "editor", "old", style)
				end
				if mode == "refresh" then
					vim.cmd("setlocal winhighlight=" .. user)
					install()
					g.refresh(win)
				end
				assert(fired == 1, "native marker callback did not run")
				local clone = api.nvim_open_win(
					api.nvim_win_get_buf(win),
					false,
					{ relative = "editor", row = 1, col = 1, width = 20, height = 2 }
				)
				assert(raw(clone) == "", "overwritten marker left unowned filler in native copy")
				if mode == "noop" then
					assert(raw(win):find("diff:/", 1, true), "unmodified marker disabled active filler")
				else
					assert(g.user_winhighlight(win) == user and vim.wo[clone].winhighlight == user)
				end
				if session then
					require("lazyvcs.actions").close(session)
					session = nil
				else
					g.release(win)
				end
				settle()
				assert(raw(win) == "" and raw(clone) == "", "marker overwrite leaked after close")
				if mode ~= "noop" then
					assert(vim.wo[win].winhighlight == user)
				end
			end, debug.traceback)
			if hook then
				api.nvim_del_autocmd(hook)
			end
			if session then
				require("lazyvcs.actions").close(session)
			end
			assert(ok, err)
		end)
	end

	add("alias_links_survive_clear_and_follow_public_updates", function()
		file()
		local win = api.nvim_get_current_win()
		g.apply(win, "editor", "old", style)
		for alias, public in pairs({
			LazyVcsOverlayFiller = "LazyVcsDiffFiller",
			LazyVcsOverlayRemoved = "LazyVcsDiffRemoved",
		}) do
			assert(api.nvim_get_hl(0, { name = alias }).link == public)
			api.nvim_set_hl(0, public, { fg = 0x2244aa })
			assert(api.nvim_get_hl(0, { name = alias, link = false }).fg == 0x2244aa)
			vim.cmd("highlight clear " .. alias)
			assert(api.nvim_get_hl(0, { name = alias }).link == public, "clear dropped a private alias link")
			api.nvim_exec_autocmds("ColorScheme", {})
			settle()
			assert(api.nvim_get_hl(0, { name = alias }).link == public)
		end
	end)
	return cases
end
