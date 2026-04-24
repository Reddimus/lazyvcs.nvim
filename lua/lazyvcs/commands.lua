local M = {}

function M.setup()
	local actions = require("lazyvcs.actions")

	vim.api.nvim_create_user_command("LazyVcsDiffOpen", actions.open, { desc = "Open lazyvcs live diff view" })
	vim.api.nvim_create_user_command("LazyVcsDiffClose", actions.close, { desc = "Close lazyvcs live diff view" })
	vim.api.nvim_create_user_command("LazyVcsDiffToggle", actions.toggle, { desc = "Toggle lazyvcs live diff view" })
	vim.api.nvim_create_user_command(
		"LazyVcsRevertHunk",
		actions.revert_hunk,
		{ desc = "Revert the current lazyvcs hunk" }
	)
	vim.api.nvim_create_user_command("LazyVcsNextHunk", actions.next_hunk, { desc = "Jump to the next lazyvcs hunk" })
	vim.api.nvim_create_user_command(
		"LazyVcsPrevHunk",
		actions.prev_hunk,
		{ desc = "Jump to the previous lazyvcs hunk" }
	)
	vim.api.nvim_create_user_command(
		"LazyVcsDiffRefresh",
		actions.refresh_current,
		{ desc = "Refresh the current lazyvcs live diff view" }
	)

	vim.api.nvim_create_user_command("VcsLiveDiffOpen", actions.open, { desc = "Alias for LazyVcsDiffOpen" })
	vim.api.nvim_create_user_command("LazyVcsSourceControlProfile", function(opts)
		local jobs = require("lazyvcs.source_control.jobs")
		if opts.args == "clear" then
			jobs.clear_history()
			return
		end
		local lines = {}
		for _, item in ipairs(jobs.history()) do
			lines[#lines + 1] = string.format(
				"%6dms %-9s %-7s %s %s",
				item.duration_ms or 0,
				item.status or "",
				item.vcs or "",
				item.kind or "",
				item.root or ""
			)
			if item.error and item.error ~= "" then
				lines[#lines + 1] = "  " .. item.error
			end
		end
		if #lines == 0 then
			lines[1] = "No lazyvcs source-control jobs recorded."
		end
		vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "lazyvcs source control profile" })
	end, {
		desc = "Show recent lazyvcs source-control job timings",
		nargs = "?",
		complete = function()
			return { "clear" }
		end,
	})
end

return M
