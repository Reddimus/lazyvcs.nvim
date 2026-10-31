local util = require("lazyvcs.util")
local text = require("lazyvcs.compare_text")
local M = {}

-- Blame follows the text Neovim read through a filesystem link.
function M.path(path)
	local stat = path and vim.uv.fs_lstat(path)
	if not stat or stat.type ~= "link" then
		return path
	end
	local resolved = vim.uv.fs_realpath(path)
	local target = resolved and vim.uv.fs_stat(resolved)
	if not target or target.type ~= "file" then
		return nil, "Symlink target is not a tracked file"
	end
	return util.normalize_literal_path(assert(resolved))
end

M.options = { "fileencoding", "fileformat", "bomb", "endofline", "endoffile", "fixendofline", "binary" }

---@class lazyvcs.BlameContext
---@field bufnr integer
---@field winid integer
---@field name string
---@field changedtick integer
---@field identity LazyVcsTextIdentity

---@param bufnr integer
---@param winid integer
---@return lazyvcs.BlameContext?
function M.capture(bufnr, winid)
	if
		not util.buf_is_valid(bufnr)
		or not vim.api.nvim_buf_is_loaded(bufnr)
		or not util.win_is_valid(winid)
		or vim.api.nvim_win_get_buf(winid) ~= bufnr
	then
		return nil
	end
	return {
		bufnr = bufnr,
		winid = winid,
		name = vim.api.nvim_buf_get_name(bufnr),
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
		identity = text.identity(bufnr),
	}
end

---@param captured lazyvcs.BlameContext
---@param require_window? boolean
---@return boolean
function M.valid(captured, require_window)
	return util.buf_is_valid(captured.bufnr)
		and vim.api.nvim_buf_is_loaded(captured.bufnr)
		and vim.api.nvim_buf_get_name(captured.bufnr) == captured.name
		and vim.api.nvim_buf_get_changedtick(captured.bufnr) == captured.changedtick
		and vim.deep_equal(text.identity(captured.bufnr), captured.identity)
		and (
			not require_window
			or (util.win_is_valid(captured.winid) and vim.api.nvim_win_get_buf(captured.winid) == captured.bufnr)
		)
end

---@param captured lazyvcs.BlameContext
---@param max_bytes integer
---@return string? contents
---@return string? error
---@return LazyVcsBufferCapture? capture
function M.contents(captured, max_bytes)
	if not M.valid(captured, true) then
		return nil, "Blame source changed"
	end
	local capture, err = text.capture_file(captured.bufnr, max_bytes)
	if not capture then
		return nil, err
	end
	if not M.valid(captured, true) then
		return nil, "Blame source changed"
	end
	return capture.bytes, nil, capture
end
return M
