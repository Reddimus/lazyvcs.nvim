local util = require("lazyvcs.util")
local api = vim.api
local M = {}

---@class LazyVcsClosedFold
---@field first integer
---@field last integer

---@class LazyVcsFoldState
---@field closed LazyVcsClosedFold[]
---@field line_count integer
---@field method string

---@param win integer
---@return LazyVcsFoldState?
function M.capture(win)
	local ok, snapshot = pcall(function()
		-- Only diff folds can be recomputed by the save projection. Other methods
		-- and disabled folds must not be inspected or have their closures changed.
		if util.get_win_option(win, "foldmethod") ~= "diff" or not util.get_win_option(win, "foldenable") then
			return nil
		end
		return api.nvim_win_call(win, function()
			local closed, line = {}, 1
			local line_count = api.nvim_buf_line_count(0)
			while line <= line_count do
				local first = vim.fn.foldclosed(line)
				if first == -1 then
					line = line + 1
				else
					local last = vim.fn.foldclosedend(line)
					closed[#closed + 1] = { first = first, last = last }
					line = last + 1
				end
			end
			return { closed = closed, line_count = line_count, method = "diff" }
		end)
	end)
	return ok and snapshot or nil
end

---@param win integer
---@param snapshot LazyVcsFoldState?
---@return boolean
function M.restore(win, snapshot)
	local ok, restored = pcall(function()
		if
			not snapshot
			or snapshot.method ~= "diff"
			or util.get_win_option(win, "foldmethod") ~= "diff"
			or not util.get_win_option(win, "foldenable")
			or api.nvim_buf_line_count(api.nvim_win_get_buf(win)) ~= snapshot.line_count
		then
			return false
		end
		return api.nvim_win_call(win, function()
			local view = vim.fn.winsaveview()
			local options = util.capture_win_options(win, { "foldminlines", "scrollbind", "cursorbind" })
			local replayed = true
			local success = pcall(function()
				util.set_win_option_noautocmd(win, "scrollbind", false)
				util.set_win_option_noautocmd(win, "cursorbind", false)
				util.set_win_option_noautocmd(win, "foldminlines", 0)
				-- Unlike zR, foldopen leaves foldlevel unchanged. Diff folds have
				-- one level, so closing from the first line restores each range.
				vim.cmd("silent! noautocmd keepjumps %foldopen!")
				for _, fold in ipairs(snapshot.closed) do
					local closed = pcall(function()
						api.nvim_win_set_cursor(win, { fold.first, 0 })
						vim.cmd("silent noautocmd keepjumps normal! zc")
						if
							vim.fn.foldclosed(fold.first) ~= fold.first
							or vim.fn.foldclosedend(fold.first) ~= fold.last
						then
							vim.cmd("silent! noautocmd keepjumps normal! zo")
						end
					end)
					replayed = closed and replayed
				end
			end)
			success = success and replayed
			-- Cleanup is independent of replay, including partially failed writes.
			local function cleanup(fn, ...)
				local clean = pcall(fn, ...)
				success = clean and success
			end
			cleanup(util.set_win_option_noautocmd, win, "foldminlines", options.foldminlines)
			cleanup(vim.fn.winrestview, view)
			cleanup(util.set_win_option_noautocmd, win, "scrollbind", options.scrollbind)
			cleanup(util.set_win_option_noautocmd, win, "cursorbind", options.cursorbind)
			return success
		end)
	end)
	return ok and restored or false
end

return M
