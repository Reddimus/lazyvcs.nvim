-- Buffer-scoped VCS operations: changed-file picker, diff preview, revert, refresh.
--
-- Replaces the old `svn_ui` module, which hardcoded Subversion and so silently
-- did nothing in a Git repository. Everything here dispatches through
-- `lazyvcs.backends`, so the same commands work in both VCSes.
local backends = require("lazyvcs.backends")
local picker = require("lazyvcs.picker")
local signs = require("lazyvcs.signs")
local util = require("lazyvcs.util")

local M = {}

local function current_path()
	local bufnr = vim.api.nvim_get_current_buf()
	if util.is_real_file_buffer(bufnr) then
		return util.buf_path(bufnr)
	end
	return vim.fs.normalize(vim.fn.getcwd())
end

function M.files()
	local path = current_path()
	local items, err = backends.changed_files(path)
	if not items then
		return util.notify(err or "Unable to list changed files", vim.log.levels.WARN)
	end
	if #items == 0 then
		return util.notify("No changed files", vim.log.levels.INFO)
	end

	local backend_name = backends.name_for(path) or "vcs"
	picker.select(items, {
		prompt = string.format("%s changed files", backend_name:upper()),
		format_item = function(item)
			return string.format("%s %s", item.status, item.path)
		end,
	}, function(item)
		if not item then
			return
		end
		vim.cmd.edit(vim.fn.fnameescape(item.absolute_path))
	end)
end

function M.preview_diff()
	return signs.preview_diff()
end

function M.revert_hunk()
	return signs.revert_hunk()
end

function M.revert_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	local path = util.is_real_file_buffer(bufnr) and util.buf_path(bufnr)
	if not path or not backends.is_versioned(path) then
		return util.notify("Current buffer is not a tracked Git or SVN file", vim.log.levels.WARN)
	end

	local backend_name = backends.name_for(path) or "VCS"
	vim.ui.select({ "No", "Yes" }, {
		prompt = string.format("Revert all %s changes in this file?", backend_name:upper()),
	}, function(choice)
		if choice ~= "Yes" then
			return
		end
		local result, err = backends.revert_file(path)
		if not result then
			return util.notify(err or "Revert failed", vim.log.levels.ERROR)
		end
		vim.cmd("checktime " .. bufnr)
		signs.refresh(bufnr, true)
	end)
end

function M.refresh()
	local bufnr = vim.api.nvim_get_current_buf()
	require("lazyvcs.blame").refresh(bufnr)
	return signs.refresh(bufnr, true)
end

return M
