-- A child registers the user hook before the highlighting module, as in an init file.
if vim.env.LAZYVCS_FILLER_INTENT_EARLY_CHILD == "1" then
	local api = vim.api
	local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
	vim.opt.rtp:prepend(root)
	local armed, clone, observed = false, nil, 0
	api.nvim_create_autocmd("WinNew", {
		nested = true,
		callback = function()
			if armed then
				armed = false
				clone = api.nvim_get_current_win()
				local value = api.nvim_get_option_value("fillchars", { win = clone, scope = "local" })
				api.nvim_set_option_value("fillchars", value, { win = clone, scope = "local" })
			end
		end,
	})
	api.nvim_create_autocmd("OptionSet", {
		pattern = "fillchars",
		nested = true,
		callback = function()
			if clone == api.nvim_get_current_win() then
				observed = observed + 1
			end
		end,
	})
	local g = require("lazyvcs.highlighting")
	api.nvim_create_autocmd("VimEnter", {
		once = true,
		callback = function()
			vim.schedule(function()
				local ok, err = xpcall(function()
					local origin = api.nvim_get_current_win()
					vim.go.fillchars, vim.wo.fillchars, vim.wo.winhighlight = "eob:~", "", ""
					g.apply(origin, "editor", "old", { enabled = true, filler = "/", removed = true })
					local written = vim.wo[origin].fillchars
					armed = true
					vim.cmd.split()
					assert(clone and observed == 1, "early nested user OptionSet was not delivered")
					assert(vim.wo[clone].fillchars == written, "later cleanup erased observable clone intent")
					assert(g.user_fillchars(origin) == "", "clone changed origin preference")
					assert(not vim.wo[clone].winhighlight:find("LazyVcsDiffOwner", 1, true))
					g.release(origin)
					assert(
						api.nvim_get_option_value("fillchars", { win = origin, scope = "local" }) == ""
							and vim.wo[clone].fillchars == written
					)
				end, debug.traceback)
				if not ok then
					print(err)
				end
				vim.cmd(ok and "qa!" or "cquit 1")
			end)
		end,
	})
	return
end

return function(ctx)
	local api, h = vim.api, ctx.helpers
	local g = require("lazyvcs.highlighting")
	local function raw(win)
		return api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
	end
	local function guarded(fn)
		return function()
			local global = vim.go.fillchars
			vim.cmd.tabnew()
			local tab, hooks = api.nvim_get_current_tabpage(), {}
			local ok, err = xpcall(function()
				vim.go.fillchars = "eob:~"
				vim.wo.fillchars, vim.wo.winhighlight = "", ""
				api.nvim_win_set_hl_ns(0, -1)
				fn(hooks)
			end, debug.traceback)
			for _, id in ipairs(hooks) do
				pcall(api.nvim_del_autocmd, id)
			end
			if api.nvim_tabpage_is_valid(tab) then
				for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
					pcall(g.release, win)
				end
				api.nvim_set_current_tabpage(tab)
				vim.cmd.tabclose({ bang = true })
			end
			vim.go.fillchars = global
			assert(ok, err)
		end
	end
	local style = { enabled = true, filler = "/", removed = true }
	local function apply(win)
		g.apply(win, "editor", "old", style)
		return raw(win)
	end
	local cases = {}
	for _, mode in ipairs({ "setlocal", "set", "api" }) do
		cases[#cases + 1] = {
			"test_core_diff_style_equal_user_fillchars_" .. mode,
			guarded(function(hooks)
				local win = api.nvim_get_current_win()
				local value = apply(win)
				local events = 0
				hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", {
					pattern = "fillchars",
					callback = function()
						events = events + 1
					end,
				})
				if mode == "api" then
					api.nvim_set_option_value("fillchars", value, { win = win, scope = "local" })
				else
					vim.cmd(mode .. " fillchars=" .. value)
				end
				assert(events == 1, "real OptionSet must run after VimEnter")
				-- :set writes the global default and clears the raw local override.
				local expected = mode == "set" and "" or value
				assert(g.user_fillchars(win) == expected, "equal user preference lost in session projection")
				vim.cmd.split()
				local clone = api.nvim_get_current_win()
				assert(raw(clone) == expected, "native clone lost latest user preference")
				g.release(win)
				assert(raw(win) == expected and raw(clone) == expected, "close erased explicit user intent")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_core_diff_style_fillchars_global_and_changed_raw_controls",
		guarded(function()
			local win = api.nvim_get_current_win()
			apply(win)
			for _, method in ipairs({ "command", "api" }) do
				if method == "command" then
					vim.cmd("setglobal fillchars=eob:!,diff:x")
				else
					api.nvim_set_option_value("fillchars", "eob:?,diff:z", { scope = "global" })
				end
				assert(g.user_fillchars(win) == "", "global write became a local preference")
				g.release(win)
				assert(raw(win) == "", "no local intent lost fallback sentinel")
				apply(win)
			end
			g.release(win)
			apply(win)
			vim.cmd("setlocal fillchars=eob:?,diff:+")
			assert(g.user_fillchars(win) == "eob:?,diff:+")
			g.release(win)
			assert(raw(win) == "eob:?,diff:+")
		end),
	}
	cases[#cases + 1] = {
		"test_core_diff_style_release_reentry_retains_replacement",
		guarded(function(hooks)
			local win = api.nvim_get_current_win()
			apply(win)
			local armed, fired = true, 0
			hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", {
				pattern = "fillchars",
				nested = true,
				callback = function()
					if armed then
						armed, fired = false, fired + 1
						g.release(win)
						g.apply(win, "editor", "new", { enabled = true, filler = ".", removed = false })
						assert(g.user_fillchars(win) == "")
					end
				end,
			})
			g.release(win)
			assert(fired == 1)
			assert(g.user_fillchars(win) == "", "old release dropped replacement ownership")
			assert(vim.wo[win].winhighlight:find("LazyVcsDiffOwner", 1, true))
			vim.cmd.split()
			assert(raw(0) == "", "replacement slot no longer cleans native copies")
			g.release(win)
			assert(raw(win) == "", "replacement filler leaked after final release")
		end),
	}
	for _, mode in ipairs({ "release", "close", "rebind" }) do
		cases[#cases + 1] = {
			"test_core_diff_style_initial_fill_write_" .. mode,
			guarded(function(hooks)
				local win = api.nvim_get_current_win()
				vim.cmd.vsplit()
				local fired, armed, replacement = 0, true, nil
				hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", {
					pattern = "fillchars",
					nested = true,
					callback = function()
						if armed and api.nvim_get_current_win() == win then
							armed, fired = false, fired + 1
							if mode == "release" then
								g.release(win)
							elseif mode == "close" then
								api.nvim_win_close(win, true)
							else
								api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
								vim.wo[win].fillchars = "eob:!,diff:x"
								replacement = raw(win)
							end
						end
					end,
				})
				g.apply(win, "editor", "old", style)
				assert(fired == 1)
				if mode == "release" then
					assert(raw(win) == "" and g.user_winhighlight(win) == vim.wo[win].winhighlight)
				elseif mode == "rebind" then
					assert(raw(win) == replacement and vim.wo[win].winhighlight == "")
					g.apply(win, "editor", "new", { enabled = true, filler = ".", removed = false })
					assert(raw(win):find("diff:.", 1, true), "stale buffer owner blocked replacement")
					g.release(win)
					assert(raw(win) == replacement)
				end
			end),
		}
	end
	cases[#cases + 1] = {
		"test_core_diff_style_partial_initial_write_remains_releasable",
		guarded(function()
			local win = api.nvim_get_current_win()
			local util = require("lazyvcs.util")
			local original, armed = util.set_win_option, true
			---@diagnostic disable-next-line: duplicate-set-field
			util.set_win_option = function(target, name, value)
				original(target, name, value)
				if armed and name == "fillchars" then
					armed = false
					error("intentional post-write failure")
				end
			end
			local ok = pcall(apply, win)
			util.set_win_option = original
			assert(not ok, "post-write failure must reach caller")
			g.release(win)
			assert(raw(win) == "" and vim.wo[win].winhighlight == "", "partial filler write leaked")
		end),
	}
	cases[#cases + 1] = {
		"test_core_diff_style_early_nested_clone_equal_user_intent",
		function()
			local source = debug.getinfo(1, "S").source:sub(2)
			local result = vim.system({
				vim.v.progpath,
				"--headless",
				"-u",
				"NONE",
				"-i",
				"NONE",
				"-c",
				"lua dofile(" .. string.format("%q", source) .. ")",
			}, {
				text = true,
				env = { LAZYVCS_FILLER_INTENT_EARLY_CHILD = "1" },
			}):wait(15000)
			assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
		end,
	}
	for _, mode in ipairs({ "close", "replace", "retarget", "owned" }) do
		cases[#cases + 1] = {
			"test_core_diff_style_copy_restore_" .. mode,
			guarded(function(hooks)
				local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
				api.nvim_buf_set_lines(buf, 0, -1, false, { "origin" })
				vim.cmd.vsplit()
				apply(origin)
				local clones, armed = {}, true
				hooks[#hooks + 1] = api.nvim_create_autocmd("WinNew", {
					callback = function()
						if armed then
							armed = false
							api.nvim_win_call(origin, function()
								for i = 1, 2 do
									clones[i] = api.nvim_open_win(
										buf,
										false,
										{ relative = "editor", row = i, col = 1, width = 12, height = 2 }
									)
								end
							end)
						end
					end,
				})
				api.nvim_open_win(buf, false, { relative = "editor", row = 4, col = 1, width = 12, height = 2 })
				assert(#clones == 2 and raw(clones[1]) == raw(origin) and raw(clones[2]) == raw(origin))
				local order = {}
				for i, win in ipairs(api.nvim_list_wins()) do
					order[win] = i
				end
				local first, later = clones[1], clones[2]
				if order[first] > order[later] then
					first, later = later, first
				end
				local fired = 0
				hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", {
					pattern = "fillchars",
					nested = true,
					callback = function()
						if fired == 0 and api.nvim_get_current_win() == first then
							fired = fired + 1
							if mode == "replace" then
								g.release(origin)
								g.apply(origin, "editor", "new", { enabled = true, filler = ".", removed = false })
							elseif mode == "retarget" then
								api.nvim_win_set_buf(later, api.nvim_create_buf(false, true))
								vim.wo[later].fillchars = "eob:?,diff:x"
								vim.wo[later].winhighlight = "Normal:WarningMsg"
							elseif mode == "owned" then
								g.apply(later, "editor", "new", { enabled = true, filler = ".", removed = false })
							else
								api.nvim_win_close(later, true)
							end
						end
					end,
				})
				g.release(origin)
				assert(fired == 1)
				if mode == "replace" then
					assert(g.user_fillchars(origin) == "", "replacement adopted the old injected filler")
					assert(raw(first) == "" and raw(later) == "", "slot reuse lost an original copy")
					g.release(origin)
				elseif mode == "retarget" then
					assert(raw(later) == "eob:?,diff:x" and vim.wo[later].winhighlight == "Normal:WarningMsg")
				elseif mode == "owned" then
					assert(raw(later):find("diff:.", 1, true) and g.user_fillchars(later) == "")
					g.release(later)
					assert(raw(later) == "")
				else
					assert(not api.nvim_win_is_valid(later))
				end
				assert(raw(first) == "" and raw(origin) == "", "release stopped before remaining owner restored")
			end),
		}
	end

	cases[#cases + 1] = {
		"test_core_diff_style_equal_intent_live_session_projection_and_hidden_return",
		guarded(function()
			require("lazyvcs").setup({
				use_gitsigns = false,
				signs = { enabled = false },
				blame = { persist = false },
				diff_style = style,
				base_window = { collapse_absent = false },
			})
			local f = h.make_git_fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			vim.bo.bufhidden = "hide"
			local win = api.nvim_get_current_win()
			vim.wo[win].fillchars = ""
			local session = ctx.open_diff()
			local value = raw(win)
			api.nvim_set_current_win(win)
			vim.cmd("setlocal fillchars=" .. value)
			local layout, token = require("lazyvcs.layout"), {}
			layout.prepare_sessions_save({ session }, token)
			assert(token.windows[win].projected_fillchars == value and raw(win) == value)
			local resumed, errors = layout.finish_sessions_save(token)
			assert(
				#errors == 0 and #resumed == 0 and session.phase == "active",
				vim.inspect({ errors = errors, resumed = #resumed })
			)
			for _, s in ipairs(resumed) do
				require("lazyvcs.actions").resume_session_save(s)
			end
			require("lazyvcs.actions").close(session)
			assert(raw(win) == value, "public close erased user preference")
			api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			assert(raw(win) == value, "hidden buffer revived the prior raw preference")
		end),
	}

	return cases
end
