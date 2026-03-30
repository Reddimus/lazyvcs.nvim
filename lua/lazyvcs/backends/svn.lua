local util = require("lazyvcs.util")

local M = {
	name = "svn",
}

local function get_root(path)
	local cwd = vim.fs.dirname(path)
	local result, err = util.system({ "svn", "info", "--show-item", "wc-root", path }, { cwd = cwd })
	if not result then
		return nil, err
	end
	return util.trim(result.stdout)
end

local function is_versioned(path)
	local _, err = util.system({ "svn", "info", path }, { cwd = vim.fs.dirname(path) })
	return err == nil
end

function M.probe(path)
	local root = get_root(path)
	if not root then
		return nil
	end
	return { root = root }
end

function M.load(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not an SVN working copy"
	end

	local tracked = is_versioned(path)
	---@type string[]
	local base_lines = {}
	local base_label = "EMPTY"

	if tracked then
		local loaded_lines, load_err = util.system_lines({ "svn", "cat", "-r", "BASE", path }, { cwd = root })
		if not loaded_lines then
			return nil, load_err or err
		end
		base_lines = loaded_lines
		base_label = "BASE"
	end

	return {
		name = M.name,
		root = root,
		relpath = util.relpath(root, path),
		tracked = tracked,
		base_label = base_label,
		base_lines = base_lines,
		impl = M,
	}
end

function M.revert_hunk()
	return false
end

return M
