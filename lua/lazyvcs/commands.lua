local M = {}

local function command(name, rhs, opts)
	pcall(vim.api.nvim_del_user_command, name)
	vim.api.nvim_create_user_command(name, rhs, opts or {})
end

local function source_control_profile(opts)
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
end

function M.setup()
	local actions = require("lazyvcs.actions")
	local blame = require("lazyvcs.blame")
	local config = require("lazyvcs.config")
	local svn_ui = require("lazyvcs.svn_ui")

	local commands = {
		DiffOpen = { actions.open, "Open lazyvcs live diff view" },
		DiffClose = { actions.close, "Close lazyvcs live diff view" },
		DiffToggle = { actions.toggle, "Toggle lazyvcs live diff view" },
		RevertHunk = { actions.revert_hunk, "Revert the current lazyvcs hunk" },
		NextHunk = { actions.next_hunk, "Jump to the next lazyvcs hunk" },
		PrevHunk = { actions.prev_hunk, "Jump to the previous lazyvcs hunk" },
		DiffRefresh = { actions.refresh_current, "Refresh the current lazyvcs live diff view" },
		SignsRefresh = { svn_ui.refresh, "Refresh lazyvcs SVN signs for the current buffer" },
		Blame = { blame.blame, "Toggle global lazyvcs inline Git/SVN blame" },
		BlameSplit = { blame.blame_split, "Toggle lazyvcs Git/SVN full-file blame split" },
		BlameClear = { blame.blame_clear, "Disable global lazyvcs inline blame" },
		LineLog = { blame.line_log, "Show Git/SVN log for the current line" },
		PreviewDiff = { svn_ui.preview_diff, "Preview current SVN buffer diff" },
		RevertBuffer = { svn_ui.revert_buffer, "Revert current SVN buffer" },
		Files = { svn_ui.files, "Browse modified SVN files" },
	}
	for suffix, item in pairs(commands) do
		command("LazyVCS" .. suffix, item[1], { desc = item[2] })
		command("LazyVcs" .. suffix, item[1], { desc = "Alias for LazyVCS" .. suffix })
	end

	command("VcsLiveDiffOpen", actions.open, { desc = "Alias for LazyVCSDiffOpen" })
	command("LazyVCSSourceControlOpen", function(opts)
		require("lazyvcs").source_control_open({
			path = opts.args ~= "" and opts.args or nil,
		})
	end, {
		desc = "Open lazyvcs source-control sidebar",
		nargs = "?",
		complete = "dir",
	})
	command("LazyVcsSourceControlOpen", function(opts)
		require("lazyvcs").source_control_open({
			path = opts.args ~= "" and opts.args or nil,
		})
	end, {
		desc = "Alias for LazyVCSSourceControlOpen",
		nargs = "?",
		complete = "dir",
	})
	command("LazyVCSSourceControlClose", function()
		require("lazyvcs").source_control_close()
	end, { desc = "Close lazyvcs source-control sidebar" })
	command("LazyVcsSourceControlClose", function()
		require("lazyvcs").source_control_close()
	end, { desc = "Alias for LazyVCSSourceControlClose" })
	command("LazyVCSSourceControlToggle", function(opts)
		require("lazyvcs").source_control_toggle({
			path = opts.args ~= "" and opts.args or nil,
		})
	end, {
		desc = "Toggle lazyvcs source-control sidebar",
		nargs = "?",
		complete = "dir",
	})
	command("LazyVcsSourceControlToggle", function(opts)
		require("lazyvcs").source_control_toggle({
			path = opts.args ~= "" and opts.args or nil,
		})
	end, {
		desc = "Alias for LazyVCSSourceControlToggle",
		nargs = "?",
		complete = "dir",
	})
	command("LazyVCSSourceControlRefresh", function()
		require("lazyvcs").source_control_refresh()
	end, { desc = "Refresh lazyvcs source-control sidebar" })
	command("LazyVcsSourceControlRefresh", function()
		require("lazyvcs").source_control_refresh()
	end, { desc = "Alias for LazyVCSSourceControlRefresh" })
	command("LazyVCSSourceControlProfile", source_control_profile, {
		desc = "Show recent lazyvcs source-control job timings",
		nargs = "?",
		complete = function()
			return { "clear" }
		end,
	})
	command("LazyVcsSourceControlProfile", source_control_profile, {
		desc = "Alias for LazyVCSSourceControlProfile",
		nargs = "?",
		complete = function()
			return { "clear" }
		end,
	})

	local aliases = {
		SvnBlame = blame.blame,
		SvnLog = blame.line_log,
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
