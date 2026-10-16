return function(ctx)
	local h, p = ctx.helpers, require("process_helpers")
	local function shutdown(mode, sidebar)
		if vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "POSIX process groups" })
		end
		local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
		local dir = h.tempdir()
		p.guarded(dir, function()
			p.editor(root .. "/tests/fixtures/process_shutdown.lua", dir, { root, dir, mode, sidebar })
			ctx.wait_for(function()
				return p.dead(dir)
			end, "owned processes survived editor exit", 1000)
			assert(vim.fn.filereadable(dir .. "/queued") == 0, "queued command started during shutdown")
			assert(vim.fn.filereadable(dir .. "/callback") == 0, "application callback ran during shutdown")
			local state = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/shutdown.json"), "\n"))
			assert(state.closed and state.rejected, "shutdown did not reject new work")
			assert(state.preflight_settled, "completed preflight advanced instead of settling during shutdown")
			assert(state.elapsed_ms < 500, "shutdown exceeded its shared deadlines")
			local seen = {}
			for _, item in ipairs(state.history) do
				assert(not seen[item.id], "shutdown recorded a job twice")
				seen[item.id] = true
				assert(item.status == "cancelled", "shutdown did not cancel job")
			end
			assert(#state.history == (mode == "cancelled" and 1 or 9), "shutdown did not drain all queues")
		end)
	end
	return {
		{
			"test_source_control_process_exit_kills_editor_and_repository_trees",
			function()
				shutdown("running", "no")
				shutdown("running", "yes")
			end,
		},
		{
			"test_source_control_process_exit_forces_already_cancelled_tree",
			function()
				shutdown("cancelled", "yes")
			end,
		},
	}
end
