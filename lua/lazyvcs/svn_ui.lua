local picker = require("lazyvcs.picker")
local signs = require("lazyvcs.signs")
local svn = require("lazyvcs.backends.svn")
local util = require("lazyvcs.util")

local M = {}

local function current_path()
	local bufnr = vim.api.nvim_get_current_buf()
	if util.is_real_file_buffer(bufnr) then
		return util.buf_path(bufnr)
	end
	return vim.fn.getcwd()
end

function M.blame()
	return require("lazyvcs.blame").blame()
end

function M.blame_split()
	return require("lazyvcs.blame").blame_split()
end

function M.blame_clear()
	return require("lazyvcs.blame").blame_clear()
end

function M.line_log()
	return require("lazyvcs.blame").line_log()
end

function M.files()
	local path = current_path()
	local root, root_err = svn.root(path)
	if not root then
		util.notify(root_err or "Not an SVN working copy", vim.log.levels.WARN)
		return
	end

	local items, err = svn.changed_files(root)
	if not items then
		util.notify(err or "Unable to list SVN files", vim.log.levels.ERROR)
		return
	end
	if #items == 0 then
		util.notify("No modified SVN files", vim.log.levels.INFO)
		return
	end

	picker.select(items, {
		prompt = "SVN files",
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
	return signs.revert_buffer()
end

function M.refresh()
	require("lazyvcs.blame").refresh(vim.api.nvim_get_current_buf())
	return signs.refresh(vim.api.nvim_get_current_buf(), true)
end

function M.setup() end

function M._test_blame_views()
	return require("lazyvcs.blame")._test_blame_views()
end

function M._test_inline_state()
	return require("lazyvcs.blame")._test_inline_state()
end

function M._test_inline_enabled()
	return require("lazyvcs.blame")._test_inline_enabled()
end

return M
