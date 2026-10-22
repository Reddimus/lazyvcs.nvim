-- Compare panes mark their window options so that a window which copies them
-- can be recognized. Neovim copies 'foldnestmax' with the other window options
-- (diff, bindings, folds, winbar) on every path that copies them. Fold nesting
-- stops at 20 levels, so values above 20 change nothing; the mark adds `offset`
-- to the window's own value, and removing it restores that value.
-- 'winhighlight' would also travel, but any value moves the window to an
-- anonymous highlight namespace and drops a global nvim_set_hl_ns() theme.
local util = require("lazyvcs.util")
local M = {}
local offset = 100
local installed = false

local function value(win)
	return tonumber(util.get_win_option(win, "foldnestmax")) or 20
end

function M.marked(win)
	return value(win) >= offset
end

function M.mark(win)
	local current = value(win)
	if current < offset then
		util.set_win_option(win, "foldnestmax", offset + math.max(0, current))
	end
end

function M.unmark(win)
	local current = value(win)
	if current >= offset then
		util.set_win_option(win, "foldnestmax", current - offset)
	end
end

---Remove marks that no live Compare pane owns, such as marks restored by a
---session saved with 'sessionoptions' "options" or "localoptions".
function M.sanitize()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if not vim.w[win].lazyvcs_compare and M.marked(win) then
			M.unmark(win)
		end
	end
end

function M.setup()
	M.sanitize()
	if installed then
		return
	end
	installed = true
	local group = vim.api.nvim_create_augroup("lazyvcs_compare_marker", { clear = true })
	-- A session sets window options after WinNew and BufWinEnter have run.
	vim.api.nvim_create_autocmd("SessionLoadPost", {
		group = group,
		callback = util.safe_callback(M.sanitize),
	})
end

return M
