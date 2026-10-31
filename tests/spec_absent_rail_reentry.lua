return function()
	local api, util = vim.api, require("lazyvcs.util")
	local rail = require("lazyvcs.absent_rail")
	local names = { "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "winfixwidth" }
	local function preferences(label)
		return {
			number = true,
			relativenumber = true,
			signcolumn = "yes:1",
			foldcolumn = "2",
			statuscolumn = label,
			winfixwidth = false,
		}
	end
	local function capture(win)
		return util.capture_win_options(win, names)
	end
	local function guarded(fn)
		return function()
			vim.cmd.tabnew()
			local tab = api.nvim_get_current_tabpage()
			local hooks, owners = {}, {}
			local function own(s)
				owners[#owners + 1] = { session = s, record = s.rail }
			end
			local ok, err = xpcall(function()
				fn(hooks, own)
			end, debug.traceback)
			for _, id in ipairs(hooks) do
				pcall(api.nvim_del_autocmd, id)
			end
			for i = #owners, 1, -1 do
				local item = owners[i]
				-- A red baseline can strand a live record after dropping its pointer.
				-- Reattach only this known private fixture record to settle cleanup.
				if not item.session.rail then
					item.session.rail = item.record
				end
				pcall(rail.release, item.session)
			end
			if api.nvim_tabpage_is_valid(tab) then
				api.nvim_set_current_tabpage(tab)
				vim.cmd.tabclose()
			end
			assert(ok, err)
		end
	end
	local cases = {}
	for _, same_session in ipairs({ true, false }) do
		for _, same_window in ipairs({ true, false }) do
			cases[#cases + 1] = {
				"test_core_absent_rail_release_reentry_"
					.. (same_session and "same" or "new")
					.. "_session_"
					.. (same_window and "same" or "new")
					.. "_window",
				guarded(function(hooks, own)
					api.nvim_buf_set_lines(0, 0, -1, false, { "original" })
					local oldwin = api.nvim_get_current_win()
					vim.cmd.vsplit()
					local other = api.nvim_get_current_win()
					api.nvim_win_set_buf(other, api.nvim_create_buf(false, true))
					api.nvim_buf_set_lines(0, 0, -1, false, { "replacement" })
					vim.cmd.vsplit()
					local focused = api.nvim_get_current_win()
					local newwin = same_window and oldwin or other
					local source, target = {}, nil
					target = same_session and source or {}
					util.set_win_options(oldwin, preferences("OLD"))
					rail.apply(source, oldwin, false)
					own(source)
					local old = source.rail
					for name, value in pairs(old.before) do
						assert(value ~= old.written[name], "all restore fields must differ")
					end
					local armed, fired, replacement = true, 0, nil
					hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", {
						pattern = names,
						nested = true,
						callback = function()
							if armed and api.nvim_get_current_win() == oldwin then
								armed, fired = false, fired + 1
								rail.release(source)
								assert(not source.rail, "inner release did not settle")
								util.set_win_options(newwin, preferences("NEW"))
								rail.apply(target, newwin, false)
								replacement = target.rail
								own(target)
							end
						end,
					})
					rail.release(source)
					assert(fired == 1 and replacement, "native restore callback did not run once")
					assert(replacement.slot == old.slot, "fixture did not reuse the released slot")
					assert(target.rail == replacement, "outer release cleared a replacement session pointer")
					for name, value in pairs(replacement.written) do
						assert(util.get_win_option(newwin, name) == value, "old restore clobbered new " .. name)
					end
					api.nvim_set_option_value("number", false, { win = newwin, scope = "local" })
					api.nvim_set_option_value("statuscolumn", "LATEST", { win = newwin, scope = "local" })
					assert(
						not replacement.before.number and replacement.before.statuscolumn == "LATEST",
						"replacement lost latest preferences"
					)
					local clone
					api.nvim_win_call(newwin, function()
						clone = api.nvim_open_win(
							api.nvim_get_current_buf(),
							false,
							{ relative = "editor", row = 1, col = 1, width = 12, height = 2 }
						)
					end)
					assert(
						vim.deep_equal(capture(clone), replacement.before),
						"replacement slot no longer cleans native copies"
					)
					assert(api.nvim_get_current_win() == focused)
					api.nvim_win_close(clone, true)
					rail.release(target)
					assert(
						not target.rail and vim.deep_equal(capture(newwin), replacement.before),
						"replacement did not restore its own preferences"
					)
				end),
			}
		end
	end
	for _, close in ipairs({ true, false }) do
		cases[#cases + 1] = {
			"test_core_absent_rail_restore_stops_after_" .. (close and "window_close" or "buffer_replacement"),
			guarded(function(hooks, own)
				local win = api.nvim_get_current_win()
				api.nvim_buf_set_lines(0, 0, -1, false, { "owned" })
				vim.cmd.vsplit()
				util.set_win_options(win, preferences("OLD"))
				local s = {}
				rail.apply(s, win, false)
				own(s)
				local armed, fired, after = true, 0, nil
				hooks[#hooks + 1] = api.nvim_create_autocmd("OptionSet", {
					pattern = names,
					nested = true,
					callback = function()
						if armed and api.nvim_get_current_win() == win then
							armed, fired = false, fired + 1
							if close then
								api.nvim_win_close(win, true)
							else
								api.nvim_win_set_buf(win, api.nvim_create_buf(false, true))
								util.set_win_options(win, preferences("UNRELATED"))
								util.set_win_options(win, {
									number = false,
									relativenumber = false,
									signcolumn = "no",
									foldcolumn = "0",
									winfixwidth = true,
								})
								after = capture(win)
							end
						end
					end,
				})
				rail.release(s)
				assert(fired == 1 and not s.rail, "restore callback did not settle")
				if not close then
					assert(vim.deep_equal(capture(win), after), "old restore altered the unrelated buffer")
				end
			end),
		}
	end
	cases[#cases + 1] = {
		"test_core_absent_rail_release_skips_copy_closed_by_restore_callback",
		guarded(function(hooks, own)
			local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
			api.nvim_buf_set_lines(buf, 0, -1, false, { "origin" })
			vim.cmd.vsplit()
			util.set_win_options(origin, preferences("ORIGINAL"))
			local s = {}
			rail.apply(s, origin, false)
			own(s)
			local record, clones, armed = s.rail, {}, true
			hooks[#hooks + 1] = api.nvim_create_autocmd("WinNew", {
				callback = function()
					if armed then
						armed = false
						-- A normal non-nested user hook defers nested clone cleanup.
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
			assert(
				#clones == 2
					and vim.wo[clones[1]].statuscolumn == record.token
					and vim.wo[clones[2]].statuscolumn == record.token
			)
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
				pattern = names,
				nested = true,
				callback = function()
					if fired == 0 and api.nvim_get_current_win() == first then
						fired = fired + 1
						api.nvim_win_close(later, true)
					end
				end,
			})
			rail.release(s)
			assert(fired == 1 and not api.nvim_win_is_valid(later), "native callback did not close a later listed copy")
			assert(not s.rail, "release did not settle after a captured copy closed")
			assert(vim.deep_equal(capture(first), record.before) and vim.deep_equal(capture(origin), record.before))
		end),
	}
	cases[#cases + 1] = {
		"test_core_absent_rail_partial_apply_still_restores_registered_writes",
		guarded(function(_, own)
			local win = api.nvim_get_current_win()
			local before = preferences("PARTIAL")
			util.set_win_options(win, before)
			local original, writes = util.set_win_option, 0
			---@diagnostic disable-next-line: duplicate-set-field
			util.set_win_option = function(target, name, value)
				writes = writes + 1
				if writes == 3 then
					error("partial rail write failure")
				end
				return original(target, name, value)
			end
			local s = {}
			local ok = pcall(rail.apply, s, win, false)
			util.set_win_option = original
			assert(not ok and s.rail and writes == 3)
			own(s)
			rail.release(s)
			assert(not s.rail and vim.deep_equal(capture(win), before), "unpublished rail writes were not restored")
		end),
	}
	return cases
end
