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

local function closure(first)
	return {
		first = vim.fn.foldclosed(first),
		last = vim.fn.foldclosedend(first),
		depth = tonumber(vim.fn.foldtextresult(first)),
	}
end

local function matches(actual, fold)
	return actual.first == fold.first and actual.last == fold.last and actual.depth == fold.depth
end

local function replay(win, closed)
	for i = #closed, 1, -1 do
		local fold = closed[i]
		api.nvim_win_set_cursor(win, { fold.close_at or fold.first, 0 })
		if fold.close_at then
			vim.cmd("silent noautocmd keepjumps normal! zc")
		else
			-- Open descendants can tile the entire parent. Closing from its first
			-- line then closes descendants before reaching the parent.
			local temporary, previous = {}, math.huge
			while true do
				vim.cmd("silent noautocmd keepjumps normal! zc")
				local actual = closure(fold.first)
				assert(actual.depth and actual.depth < previous, "fold closure made no progress")
				assert(
					actual.first == fold.first and actual.last <= fold.last and actual.depth >= fold.depth,
					"fold closure escaped range"
				)
				if actual.depth == fold.depth then
					assert(matches(actual, fold), "could not restore tiled parent")
					break
				end
				temporary[#temporary + 1], previous = actual, actual.depth
			end
			if #temporary > 0 then
				-- zc cannot close only the parent of open tiled children. Remove
				-- that boundary, undo the temporary closures, and recreate it closed.
				-- Manual mode changes the fold tree without editing marker text.
				util.set_win_option_noautocmd(win, "foldmethod", "manual")
				vim.cmd("silent noautocmd keepjumps normal! zd")
				local ok, err = pcall(function()
					for j = #temporary, 1, -1 do
						local child = temporary[j]
						child.depth = child.depth - 1
						assert(matches(closure(child.first), child), "could not locate temporary child")
						vim.cmd("silent noautocmd keepjumps normal! zo")
					end
				end)
				-- Recreate the boundary even when child inspection fails, so rollback
				-- can recover the original closure flags on an intact fold tree.
				vim.cmd(("silent noautocmd keepjumps %d,%dfold"):format(fold.first, fold.last))
				assert(ok, err)
			end
		end
		assert(matches(closure(fold.first), fold), "could not restore fold closure")
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
			local depth = vim.fn.foldlevel(line)
			if parent and depth == parent.depth then
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
			api.nvim_win_set_cursor(win, { line, 0 })
			vim.cmd("silent noautocmd keepjumps normal! zo")
			-- Roll back only folds that inspection actually opened. A failed
			-- cursor/command write leaves this fold and its hidden children intact.
			closed[#closed + 1], stack[#stack + 1] = fold, fold
		end
	end
end

local function with_options(win, callback)
	local ok, result = pcall(api.nvim_win_call, win, function()
		local view = vim.fn.winsaveview()
		local options =
			util.capture_win_options(win, { "foldtext", "foldminlines", "scrollbind", "cursorbind", "foldmethod" })
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
		for _, name in ipairs({ "foldmethod", "foldtext", "foldminlines" }) do
			if util.get_win_option(win, name) ~= options[name] then
				restore(util.set_win_option_noautocmd, win, name, options[name])
			end
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
	return ok and result or nil
end

---@param win integer
---@return LazyVcsFoldState?
function M.capture(win)
	local valid, enabled = pcall(util.get_win_option, win, "foldenable")
	if not valid or not enabled then
		return nil
	end
	return with_options(win, function()
		local method = util.get_win_option(win, "foldmethod")
		local closed = {}
		local ok = pcall(inspect, win, closed)
		local restored = pcall(replay, win, closed)
		if not restored then
			local partial = {}
			if pcall(inspect, win, partial) then
				pcall(replay, win, closed)
			end
		end
		if not ok or not restored then
			return nil
		end
		return {
			closed = closed,
			line_count = api.nvim_buf_line_count(0),
			method = method,
		}
	end)
end

---@param win integer
---@param snapshot LazyVcsFoldState?
---@return boolean
function M.restore(win, snapshot)
	if not snapshot or not api.nvim_win_is_valid(win) then
		return false
	end
	return with_options(win, function()
		if
			not util.get_win_option(win, "foldenable")
			or api.nvim_buf_line_count(api.nvim_win_get_buf(win)) ~= snapshot.line_count
			or util.get_win_option(win, "foldmethod") ~= snapshot.method
		then
			return false
		end
		local closed = {}
		if not pcall(inspect, win, closed) then
			pcall(replay, win, closed)
			return false
		end
		if not pcall(replay, win, snapshot.closed) then
			local partial = {}
			if pcall(inspect, win, partial) then
				pcall(replay, win, closed)
			end
			return false
		end
		return true
	end) or false
end

return M
