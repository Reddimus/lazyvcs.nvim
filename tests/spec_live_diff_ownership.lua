return function(ctx)
	local api, h = vim.api, ctx.helpers
	local function replacement(immediate)
		local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
		for _, side in ipairs({ "editable", "base" }) do
			local f = h.make_git_transfer_fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			h.exec({ "git", "add", "alpha.txt" }, f.root)
			local comparison
			require("lazyvcs.backends").load_diff_target_async(
				{ vcs = "git", root = f.root, path = f.file1, relpath = "alpha.txt", section = "staged" },
				function(value, err)
					assert(value, err)
					comparison = value
				end
			)
			ctx.wait_for(function()
				return comparison ~= nil
			end, "staged comparison did not load", 15000)
			local s = assert(actions.open_target(comparison))
			assert(s.readonly_comparison)
			vim.wait(30)
			assert(state.get(s.editable_bufnr) == s, "untouched readonly pair closed")
			local win = s[side .. "_win"]
			api.nvim_set_current_win(win)
			vim.cmd.split()
			api.nvim_set_current_win(win)
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			local buf = api.nvim_get_current_buf()
			local lines, tick = api.nvim_buf_get_lines(buf, 0, -1, false), api.nvim_buf_get_changedtick(buf)
			if immediate then
				actions.open()
			else
				ctx.wait_for(function()
					return state.get(s.editable_bufnr) == nil
				end, "displaced readonly session retained ownership")
			end
			assert(not state.get(s.editable_bufnr), "immediate open returned stale readonly owner")
			assert(
				not state.for_window(s.editable_win) and not state.for_window(s.base_win),
				"old window indexes retained"
			)
			assert(api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf, "cleanup replaced destination")
			assert(
				vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), lines)
					and api.nvim_buf_get_changedtick(buf) == tick,
				"cleanup edited replacement"
			)
			if not immediate then
				actions.open()
			end
			ctx.wait_for(function()
				return state.get(buf) ~= nil
			end, "replacement live diff did not open", 15000)
			local live = assert(state.get(buf))
			assert(not live.readonly_comparison and live.editable_win == win)
			-- Editable right panes retain their transfer behavior.
			api.nvim_set_current_win(win)
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			local target = api.nvim_get_current_buf()
			ctx.wait_for(function()
				return state.get(target) and state.get(target) ~= live
			end, "editable pair did not transfer", 15000)
			assert(state.get(target).base_win == live.base_win, "editable transfer replaced base pane")
			h.cleanup()
			vim.cmd("silent! only!")
		end
	end
	local function guarded(immediate)
		return function()
			local hidden = vim.o.hidden
			vim.o.hidden = true
			local ok, err = xpcall(function()
				replacement(immediate)
			end, debug.traceback)
			h.cleanup()
			vim.cmd("silent! only!")
			vim.o.hidden = hidden
			assert(ok, err)
		end
	end
	return {
		{ "test_live_diff_readonly_replacement_releases_owner", guarded(false) },
		{ "test_live_diff_readonly_replacement_open_before_schedule", guarded(true) },
	}
end
