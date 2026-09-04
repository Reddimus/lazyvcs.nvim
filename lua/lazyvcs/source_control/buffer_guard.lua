local util = require("lazyvcs.util")

local M = {}

local function path_is_in_root(root, path)
	if root == path then
		return true
	end
	return vim.fs.relpath(root, path) ~= nil
end

function M.modified(repo_root, paths)
	local root = util.canonical_path(repo_root)
	local selected_entries
	local selected_files
	if paths then
		selected_entries = {}
		selected_files = {}
		for _, path in ipairs(paths) do
			selected_entries[util.canonical_entry_path(path)] = true
			selected_files[util.canonical_path(path)] = true
		end
	end

	local found = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified and util.is_real_file_buffer(bufnr) then
			local buffer_path = util.buf_path(bufnr)
			local entry_path = util.canonical_entry_path(buffer_path)
			local file_path = util.canonical_path(buffer_path)
			local entry_in_root = path_is_in_root(root, entry_path)
			local file_in_root = path_is_in_root(root, file_path)
			local is_selected = not selected_entries or selected_entries[entry_path] or selected_files[file_path]
			if (entry_in_root or file_in_root) and is_selected then
				found[#found + 1] = {
					bufnr = bufnr,
					path = entry_in_root and entry_path or file_path,
				}
			end
		end
	end
	table.sort(found, function(left, right)
		return left.path < right.path
	end)
	return found
end

function M.error(repo_root, paths)
	local modified = M.modified(repo_root, paths)
	if #modified == 0 then
		return nil
	end

	local suffix = #modified > 1 and string.format(" and %d more", #modified - 1) or ""
	return string.format(
		"Save or discard modified buffers before changing the repository: %s%s",
		modified[1].path,
		suffix
	)
end

function M.check(repo_root, paths)
	local err = M.error(repo_root, paths)
	if not err then
		return true
	end
	util.notify(err, vim.log.levels.WARN)
	return false
end

return M
