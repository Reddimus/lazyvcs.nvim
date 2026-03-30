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
end

return M
