local util = require("lazyvcs.util")
local M = {}

---@class lazyvcs.BlameContext
---@field bufnr integer
---@field winid integer
---@field name string
---@field changedtick integer
---@field fileformat string

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
		fileformat = vim.bo[bufnr].fileformat,
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
		-- Changing 'fileformat' changes the bytes sent to the backend but not the tick.
		and vim.bo[captured.bufnr].fileformat == captured.fileformat
		and (
			not require_window
			or (util.win_is_valid(captured.winid) and vim.api.nvim_win_get_buf(captured.winid) == captured.bufnr)
		)
end

---@param captured lazyvcs.BlameContext
---@param max_bytes integer
---@return string? contents
---@return string? error
function M.contents(captured, max_bytes)
	if not M.valid(captured, true) then
		return nil, "Blame source changed"
	end
	if util.buffer_size(captured.bufnr) > max_bytes then
		return nil, "Blame source exceeds the file size limit"
	end
	return util.join_lines(util.get_buf_lines(captured.bufnr))
end
return M
