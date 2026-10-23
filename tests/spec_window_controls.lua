return function()
	local api = vim.api
	local function scenario(run)
		vim.cmd.tabnew()
		local tab = api.nvim_get_current_tabpage()
		local buf = api.nvim_create_buf(false, true)
		api.nvim_win_set_buf(0, buf)
		local first = api.nvim_get_current_win()
		vim.cmd.vsplit()
		local second = api.nvim_get_current_win()
		local owner = {}
		local controls = require("lazyvcs.window_controls")
		local ok, err = xpcall(function()
			run(controls, owner, first, second, buf)
		end, debug.traceback)
		controls.unregister(owner)
		if api.nvim_tabpage_is_valid(tab) then
			vim.cmd("tabclose! " .. api.nvim_tabpage_get_number(tab))
		end
		if api.nvim_buf_is_valid(buf) then
			api.nvim_buf_delete(buf, { force = true })
		end
		assert(ok, err)
	end
	return {
		{
			"test_core_window_controls_restore_shared_buffer_maps_on_focus",
			function()
				scenario(function(controls, owner, first, second, buf)
					local original, controlled = function() end, function() end
					vim.keymap.set("n", "q", original, { buffer = buf, desc = "user close", nowait = true })
					controls.register(owner, function(win)
						return win == first and { { key = "q", callback = controlled } } or nil
					end)
					assert(vim.fn.maparg("q", "n", false, true).callback == original)
					api.nvim_set_current_win(first)
					assert(vim.fn.maparg("q", "n", false, true).callback == controlled)
					api.nvim_set_current_win(second)
					local restored = vim.fn.maparg("q", "n", false, true)
					assert(restored.callback == original and restored.desc == "user close" and restored.nowait == 1)
				end)
			end,
		},
		{
			"test_core_window_controls_preserve_later_user_remaps",
			function()
				scenario(function(controls, owner, first, second, buf)
					api.nvim_set_current_win(first)
					controls.register(owner, function(win)
						return win == first and { { key = "]b", callback = function() end } } or nil
					end)
					local later = function() end
					vim.keymap.set("n", "]b", later, { buffer = buf })
					api.nvim_set_current_win(second)
					assert(vim.fn.maparg("]b", "n", false, true).callback == later)
				end)
			end,
		},
		{
			"test_core_window_controls_restore_global_and_native_fallbacks",
			function()
				scenario(function(controls, owner, first, second, buf)
					local previous = api.nvim_get_keymap("n")
					local global = function() end
					vim.keymap.set("n", "<F19>", global)
					api.nvim_set_current_win(first)
					controls.register(owner, function(win)
						return win == first
								and {
									{ key = "<F19>", callback = function() end },
									{ key = "q", callback = function() end },
								}
							or nil
					end)
					api.nvim_set_current_win(second)
					assert(vim.fn.maparg("<F19>", "n", false, true).callback == global)
					for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
						assert(map.lhs ~= "q" and map.lhs ~= "<F19>", "controls leaked into ordinary editor")
					end
					vim.keymap.del("n", "<F19>")
					for _, map in ipairs(previous) do
						if map.lhs == "<F19>" then
							vim.fn.mapset("n", false, map)
						end
					end
				end)
			end,
		},
		{
			-- Two resolvers can claim one window at the same priority; the window's
			-- owner wins whichever registered first.
			"test_core_window_controls_prefer_the_window_owner_on_ties",
			function()
				scenario(function(controls, _, first)
					local x, y = {}, {}
					local picks = {}
					for _, case in ipairs({ { owner = x, order = { x, y } }, { owner = y, order = { y, x } } }) do
						for _, order in ipairs({ case.order, { case.order[2], case.order[1] } }) do
							for _, owner in ipairs(order) do
								controls.register(
									owner,
									function(win)
										return win == first
												and {
													{
														key = "]v",
														callback = function() end,
														desc = tostring(owner == x),
													},
												}
											or nil
									end,
									10,
									function(win)
										return win == first and owner == case.owner
									end
								)
							end
							api.nvim_set_current_win(first)
							vim.cmd("doautocmd WinEnter")
							picks[#picks + 1] = vim.fn.maparg("]v", "n", false, true).desc == tostring(case.owner == x)
							controls.unregister(x)
							controls.unregister(y)
						end
					end
					assert(
						not vim.tbl_contains(picks, false),
						"a tie did not prefer the window owner: " .. vim.inspect(picks)
					)
				end)
			end,
		},
	}
end
