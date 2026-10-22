local util = require("lazyvcs.util")
local Task = require("lazyvcs.backends.task")
local M = {}

function M.classify(path)
	local stat, err, code = vim.uv.fs_lstat(path)
	if stat then
		return stat.type == "link" and "symlink" or stat.type == "file" and "regular" or stat.type
	end
	if code == "ENOENT" then
		return "missing"
	end
	return nil, err or "Unable to classify repository entry"
end

---@param path string
---@param callback fun(kind: string?, err: string?): any
---@return table task
function M.classify_async(path, callback)
	local task = Task.new(callback)
	vim.uv.fs_lstat(path, function(err, stat)
		vim.schedule(util.safe_callback(function()
			if stat then
				task:finish(stat.type == "link" and "symlink" or stat.type == "file" and "regular" or stat.type)
			elseif err and err:match("ENOENT") then
				task:finish("missing")
			else
				task:finish(nil, err or "Unable to classify repository entry")
			end
		end))
	end)
	return task
end

function M.editable(kind, err)
	if kind == "regular" or kind == "missing" then
		return true
	end
	return false,
		err or "Editable hunks require a regular file; symlink bases are unsupported",
		{ code = "unsupported_entry", kind = kind }
end

return M
