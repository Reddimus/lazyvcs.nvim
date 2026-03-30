local util = require("lazyvcs.util")

local M = {
	name = "git",
}

local function get_root(path)
	local cwd = vim.fs.dirname(path)
	local result, err = util.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd })
	if not result then
		return nil, err
	end
	return util.trim(result.stdout)
end

local function is_tracked(root, relpath)
	local _, err = util.system({ "git", "ls-files", "--error-unmatch", "--", relpath }, { cwd = root })
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
		return nil, err or "Not a Git working tree"
	end

	local relpath = util.relpath(root, path)
	local tracked = is_tracked(root, relpath)
	---@type string[]
	local base_lines = {}
	local base_label = "EMPTY"

	if tracked then
		local loaded_lines, load_err = util.system_lines({ "git", "show", ":" .. relpath }, { cwd = root })
		if not loaded_lines then
			return nil, load_err or err
		end
		base_lines = loaded_lines
		base_label = "INDEX"
	end

	return {
		name = M.name,
		root = root,
		relpath = relpath,
		tracked = tracked,
		base_label = base_label,
		base_lines = base_lines,
		impl = M,
	}
end

function M.revert_hunk(session, hunk)
	if not session.tracked or session.base_label ~= "INDEX" or not session.opts.use_gitsigns then
		return false
	end

	local ok, gitsigns = pcall(require, "gitsigns")
	if not ok or vim.b[session.editable_bufnr].gitsigns_status_dict == nil then
		return false
	end

	local winid = session.editable_win
	if not util.win_is_valid(winid) then
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	local anchor = math.max(hunk.current_start, 1)
	local reset_ok = pcall(function()
		vim.api.nvim_win_call(winid, function()
			vim.api.nvim_win_set_cursor(winid, { anchor, 0 })
			gitsigns.reset_hunk()
		end)
	end)

	pcall(vim.api.nvim_win_set_cursor, winid, cursor)
	return reset_ok
end

return M
