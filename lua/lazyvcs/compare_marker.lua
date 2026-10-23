-- Compare panes mark their window options so that a window which copies them
-- can be recognized. The mark is a suffix of four ASCII separator characters
-- (FS, GS, RS, US) on 'foldignore'. Neovim copies 'foldignore' with the other
-- window options on every path that copies them: splits, floats, the buffer's
-- saved window records, sessions and views. Only indent folding in the same
-- window reads it, as the first characters of lines that take their fold level
-- from their neighbours, and text lines do not start with these characters, so
-- the mark changes nothing anywhere. Removing it restores the exact value.
--
-- Other options do not qualify: Tree-sitter folding reads 'foldnestmax' through
-- a cache shared by every window on the buffer, any 'winhighlight' value moves
-- a window to an anonymous highlight namespace, and user values of numeric
-- options cannot be told apart from a mark.
local util = require("lazyvcs.util")
local M = {}
local suffix = "\28\29\30\31"
local panes = {}
local installed = false

local function value(win)
	return tostring(util.get_win_option(win, "foldignore"))
end

-- Compare's own writes skip OptionSet, which handles user and session writes.
local function write(win, text)
	util.set_win_option_noautocmd(win, "foldignore", text)
end

function M.marked(win)
	local current = value(win)
	return #current >= #suffix and current:sub(-#suffix) == suffix
end

local function add(win)
	if not M.marked(win) then
		write(win, value(win) .. suffix)
	end
end

function M.unmark(win)
	if M.marked(win) then
		write(win, value(win):sub(1, -#suffix - 1))
	end
end

---Mark a live Compare pane. It stays marked when its options change.
function M.mark(win)
	M.setup()
	panes[win] = true
	add(win)
end

---The window is no longer a Compare pane.
function M.release(win)
	panes[win] = nil
end

function M.is_pane(win)
	return panes[win] == true
end

---Remove marks that no live Compare pane owns, such as marks restored by a
---session saved with 'sessionoptions' "options" or "localoptions".
function M.sanitize()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if not panes[win] and M.marked(win) then
			M.unmark(win)
		end
	end
end

function M.setup()
	if installed then
		return
	end
	installed = true
	local group = vim.api.nvim_create_augroup("lazyvcs_compare_marker", { clear = true })
	-- :setlocal, :set and modelines replace the value. A live pane keeps the
	-- requested value with the mark added again. Elsewhere a marked value comes
	-- from a session, a view or the user, and no live pane owns it.
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "foldignore",
		callback = util.safe_callback(function()
			local win = vim.api.nvim_get_current_win()
			if panes[win] then
				add(win)
			elseif M.marked(win) then
				M.unmark(win)
			end
		end),
	})
	-- A session sets window options after WinNew and BufWinEnter have run.
	vim.api.nvim_create_autocmd("SessionLoadPost", {
		group = group,
		callback = util.safe_callback(M.sanitize),
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = util.safe_callback(function(args)
			local win = tonumber(args.match)
			if win then
				panes[win] = nil
			end
		end),
	})
end

---Install the handlers and remove marks no live pane owns.
function M.load()
	M.setup()
	M.sanitize()
end

return M
