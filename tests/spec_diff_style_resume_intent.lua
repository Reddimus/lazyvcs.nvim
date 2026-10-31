return function()
	local api, util = vim.api, require("lazyvcs.util")
	local rail, highlighting = require("lazyvcs.absent_rail"), require("lazyvcs.highlighting")
	local names =
		{ "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "winfixwidth", "winfixheight" }
	local cases = {}
	for _, kind in ipairs({ "rail", "filler" }) do
		for _, mode in ipairs(kind == "rail" and { "initial", "resume", "reentrant" } or { "initial", "resume" }) do
			cases[#cases + 1] = {
				"test_core_diff_style_resume_intent_" .. kind .. "_" .. mode,
				function()
					vim.cmd.tabnew()
					local tab, win = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
					vim.cmd.vnew()
					local other = api.nvim_get_current_win()
					api.nvim_set_current_win(win)
					local session, hooks, clone = {}, {}, nil
					local armed, fired, resumed = mode == "initial", false, false
					local function hook(event, callback, pattern)
						hooks[#hooks + 1] =
							api.nvim_create_autocmd(event, { nested = true, pattern = pattern, callback = callback })
					end
					local function release()
						if kind == "rail" then
							rail.release(session)
						else
							highlighting.release(win)
						end
					end
					local function apply()
						if kind == "rail" then
							rail.apply(session, win, false)
						else
							highlighting.apply(win, "editor", "old", { enabled = true, filler = "/", removed = true })
						end
					end
					local ok, err = xpcall(function()
						util.set_win_options(win, {
							number = true,
							relativenumber = true,
							signcolumn = "yes:1",
							foldcolumn = "2",
							statuscolumn = "ORIGINAL",
							winfixwidth = false,
							winfixheight = false,
						})
						util.set_win_option(win, "fillchars", "eob:~")
						util.set_win_option(win, "winhighlight", "")
						local before = util.capture_win_options(other, names)
						hook("OptionSet", function()
							if not armed or api.nvim_get_current_win() ~= win then
								return
							end
							armed, fired = false, true
							if kind == "rail" then
								util.set_win_option(win, "signcolumn", "yes:2")
								if mode == "reentrant" then
									apply()
								end
							else
								clone = api.nvim_open_win(
									api.nvim_get_current_buf(),
									false,
									{ relative = "editor", row = 1, col = 1, width = 20, height = 3 }
								)
							end
						end, kind == "rail" and names or "fillchars")
						apply()
						if mode ~= "initial" then
							hook("BufLeave", function()
								if resumed or api.nvim_get_current_win() ~= win then
									return
								end
								resumed, armed = true, true
								if kind == "rail" then
									assert(session.rail and session.rail.suspended)
									apply()
								else
									-- Drain the real scheduled resettlement while nested BufLeave still permits OptionSet.
									vim.wait(100, function()
										return clone ~= nil
									end, 1)
								end
							end)
							api.nvim_set_current_win(other)
						end
						assert(fired, "native OptionSet callback did not run")
						if kind == "filler" then
							assert(clone, "native no-focus copy did not open")
							assert(
								api.nvim_get_option_value("fillchars", { win = clone, scope = "local" }) == "eob:~",
								"copy retained injected filler"
							)
						end
						release()
						if kind == "rail" then
							assert(
								util.get_win_option(win, "signcolumn") == "yes:2",
								"resume discarded latest user preference"
							)
						else
							assert(
								api.nvim_get_option_value("fillchars", { win = clone, scope = "local" }) == "eob:~",
								"copy retained filler after release"
							)
						end
						assert(
							vim.deep_equal(util.capture_win_options(other, names), before),
							"resume changed unrelated window options"
						)
					end, debug.traceback)
					for _, id in ipairs(hooks) do
						pcall(api.nvim_del_autocmd, id)
					end
					pcall(release)
					if clone and api.nvim_win_is_valid(clone) then
						api.nvim_win_close(clone, true)
					end
					if api.nvim_tabpage_is_valid(tab) then
						api.nvim_set_current_tabpage(tab)
						vim.cmd.tabclose({ bang = true })
					end
					assert(ok, err)
				end,
			}
		end
	end
	return cases
end
