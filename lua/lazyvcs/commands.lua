local M = {}

local function command(name, rhs, opts)
	pcall(vim.api.nvim_del_user_command, name)
	vim.api.nvim_create_user_command(name, rhs, opts or {})
end

function M.setup()
	local actions = require("lazyvcs.actions")
	local config = require("lazyvcs.config")
	local svn_ui = require("lazyvcs.svn_ui")

	command("LazyVcsDiffOpen", actions.open, { desc = "Open lazyvcs live diff view" })
	command("LazyVcsDiffClose", actions.close, { desc = "Close lazyvcs live diff view" })
	command("LazyVcsDiffToggle", actions.toggle, { desc = "Toggle lazyvcs live diff view" })
	command("LazyVcsRevertHunk", actions.revert_hunk, { desc = "Revert the current lazyvcs hunk" })
	command("LazyVcsNextHunk", actions.next_hunk, { desc = "Jump to the next lazyvcs hunk" })
	command("LazyVcsPrevHunk", actions.prev_hunk, { desc = "Jump to the previous lazyvcs hunk" })
	command("LazyVcsDiffRefresh", actions.refresh_current, { desc = "Refresh the current lazyvcs live diff view" })
	command("LazyVcsSignsRefresh", svn_ui.refresh, { desc = "Refresh lazyvcs SVN signs for the current buffer" })
	command("LazyVcsBlame", svn_ui.blame, { desc = "Toggle lazyvcs SVN blame for the current buffer" })
	command("LazyVcsBlameSplit", svn_ui.blame_split, { desc = "Toggle lazyvcs SVN full-file blame split" })
	command("LazyVcsBlameClear", svn_ui.blame_clear, { desc = "Clear lazyvcs inline SVN blame" })
	command("LazyVcsLineLog", svn_ui.line_log, { desc = "Show SVN log for the current line" })
	command("LazyVcsPreviewDiff", svn_ui.preview_diff, { desc = "Preview current SVN buffer diff" })
	command("LazyVcsRevertBuffer", svn_ui.revert_buffer, { desc = "Revert current SVN buffer" })
	command("LazyVcsFiles", svn_ui.files, { desc = "Browse modified SVN files" })

	command("VcsLiveDiffOpen", actions.open, { desc = "Alias for LazyVcsDiffOpen" })
	command("LazyVcsSourceControlOpen", function(opts)
		require("lazyvcs").source_control_open({
			path = opts.args ~= "" and opts.args or nil,
		})
	end, {
		desc = "Open lazyvcs source-control sidebar",
		nargs = "?",
		complete = "dir",
	})
	command("LazyVcsSourceControlClose", function()
		require("lazyvcs").source_control_close()
	end, { desc = "Close lazyvcs source-control sidebar" })
	command("LazyVcsSourceControlToggle", function(opts)
		require("lazyvcs").source_control_toggle({
			path = opts.args ~= "" and opts.args or nil,
		})
	end, {
		desc = "Toggle lazyvcs source-control sidebar",
		nargs = "?",
		complete = "dir",
	})
	command("LazyVcsSourceControlRefresh", function()
		require("lazyvcs").source_control_refresh()
	end, { desc = "Refresh lazyvcs source-control sidebar" })
	command("LazyVcsSourceControlProfile", function(opts)
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

	local aliases = {
		SvnBlame = svn_ui.blame,
		SvnLog = svn_ui.line_log,
		SvnPreview = svn_ui.preview_diff,
		SvnRevert = svn_ui.revert_buffer,
		SvnResetHunk = svn_ui.revert_hunk,
		SvnFiles = svn_ui.files,
	}
	for name, rhs in pairs(aliases) do
		pcall(vim.api.nvim_del_user_command, name)
		if config.get().compat.svnsigns_commands then
			vim.api.nvim_create_user_command(name, rhs, { desc = "svnsigns.nvim compatibility alias" })
		end
	end
end

return M
