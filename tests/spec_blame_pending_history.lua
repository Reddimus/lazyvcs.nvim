return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, blame = t.api, require("lazyvcs.blame")
	return t.cases({
		{
			"test_blame_line_log_cancels_pending_cursor_move",
			function()
				for _, phase in ipairs({ "blame", "log", "guard" }) do
					local _, buf, win, backend = t.open(false)
					local pending, killed = {}, 0
					local key = phase == "log" and "revision_log_async" or "line_revision_async"
					t.patch(backend, key, function(_, _, callback)
						pending[#pending + 1] = callback
						return {
							kill = function()
								killed = killed + 1
							end,
						}
					end)
					api.nvim_win_set_cursor(win, { 1, 0 })
					assert(blame.line_log())
					t.wait(function()
						return #pending == 1
					end, "history request absent", 15000)
					local old = blame._test_line_log_views()[buf]
					-- A second window must not consume the source movement handler.
					vim.cmd.vsplit()
					api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
					assert(blame._test_line_log_views()[buf] == old)
					vim.cmd.close()
					api.nvim_set_current_win(win)
					if phase == "guard" then
						api.nvim_win_set_cursor(win, { 2, 0 })
						pending[1]("old revision")
					else
						vim.cmd("normal! j")
						api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
					end
					assert(not blame._test_line_log_views()[buf], "cursor move retained pending history")
					assert(killed == 1, "cursor move did not cancel active handle")
					api.nvim_win_set_cursor(win, { 3, 0 })
					assert(blame.line_log())
					t.wait(function()
						return #pending == 2
					end, "replacement request absent", 15000)
					local replacement = blame._test_line_log_views()[buf]
					pending[1](nil, "late old error")
					assert(blame._test_line_log_views()[buf] == replacement and not replacement.winid)
					api.nvim_exec_autocmds("TextChanged", { buffer = buf })
					local patch = table.remove(t.patches)
					patch[1][patch[2]] = patch[3]
				end
			end,
		},
	})
end
