local util = require("lazyvcs.util")
local api = vim.api
local M = {}

---@class LazyVcsClosedFold
---@field first integer
---@field last integer
---@field depth integer
---@field close_at integer?

---@class LazyVcsFoldState
---@field closed LazyVcsClosedFold[]
---@field line_count integer
---@field method string

local function replay(win, closed)
	for i = #closed, 1, -1 do
		local fold = closed[i]
		assert(fold.close_at, "could not locate fold closure")
		api.nvim_win_set_cursor(win, { fold.close_at, 0 })
		vim.cmd("silent noautocmd keepjumps normal! zc")
		assert(
			vim.fn.foldclosed(fold.first) == fold.first
				and vim.fn.foldclosedend(fold.first) == fold.last
				and tonumber(vim.fn.foldtextresult(fold.first)) == fold.depth,
			"could not restore fold closure"
		)
	end
end

local function inspect(win, closed)
	local stack, line = {}, 1
	while line <= api.nvim_buf_line_count(0) do
		while #stack > 0 and stack[#stack].last < line do
			table.remove(stack)
		end
		local first, parent = vim.fn.foldclosed(line), stack[#stack]
		if first == -1 then
			if parent and vim.fn.foldlevel(line) == parent.depth then
				parent.close_at = parent.close_at or line
			end
			line = line + 1
		else
			local fold = {
				first = first,
				last = vim.fn.foldclosedend(line),
				depth = assert(tonumber(vim.fn.foldtextresult(first)), "could not read fold depth"),
			}
			assert(not parent or fold.depth > parent.depth, "fold inspection made no progress")
			if parent and fold.depth == parent.depth + 1 then
				parent.close_at = parent.close_at or first
			end
			closed[#closed + 1], stack[#stack + 1] = fold, fold
			api.nvim_win_set_cursor(win, { line, 0 })
			vim.cmd("silent noautocmd keepjumps normal! zo")
		end
	end
end

local function with_options(win, callback)
	return api.nvim_win_call(win, function()
		local view = vim.fn.winsaveview()
		local options = util.capture_win_options(win, { "foldtext", "foldminlines", "scrollbind", "cursorbind" })
		local ok, result = pcall(function()
			-- Inspection must not move other bound windows.
			util.set_win_option_noautocmd(win, "scrollbind", false)
			util.set_win_option_noautocmd(win, "cursorbind", false)
			util.set_win_option_noautocmd(win, "foldtext", "v:foldlevel")
			util.set_win_option_noautocmd(win, "foldminlines", 0)
			return callback()
		end)
		local failure
		local function restore(fn, ...)
			local restored, err = pcall(fn, ...)
			if not restored then
				failure = failure or err
			end
		end
		for _, name in ipairs({ "foldtext", "foldminlines" }) do
			restore(util.set_win_option_noautocmd, win, name, options[name])
		end
		restore(vim.fn.winrestview, view)
		for _, name in ipairs({ "scrollbind", "cursorbind" }) do
			restore(util.set_win_option_noautocmd, win, name, options[name])
		end
		if not ok then
			error(result)
		end
		if failure then
			error(failure)
		end
		return result
	end)
end

---@param win integer
---@return LazyVcsFoldState?
function M.capture(win)
	if not util.get_win_option(win, "foldenable") then
		return nil
	end
	return with_options(win, function()
		local closed = {}
		local ok, err = pcall(inspect, win, closed)
		local restored, restore_err = pcall(replay, win, closed)
		if not ok then
			error(err)
		end
		if not restored then
			error(restore_err)
		end
		return {
			closed = closed,
			line_count = api.nvim_buf_line_count(0),
			method = util.get_win_option(win, "foldmethod"),
		}
	end)
end

---@param win integer
---@param snapshot LazyVcsFoldState?
---@return boolean
function M.restore(win, snapshot)
	if not snapshot or not api.nvim_win_is_valid(win) or not util.get_win_option(win, "foldenable") then
		return false
	end
	if
		api.nvim_buf_line_count(api.nvim_win_get_buf(win)) ~= snapshot.line_count
		or util.get_win_option(win, "foldmethod") ~= snapshot.method
	then
		return false
	end
	return with_options(win, function()
		local closed = {}
		local ok, err = pcall(inspect, win, closed)
		if not ok then
			pcall(replay, win, closed)
			error(err)
		end
		replay(win, snapshot.closed)
		return true
	end)
end

return M
