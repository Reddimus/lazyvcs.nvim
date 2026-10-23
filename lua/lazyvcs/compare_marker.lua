-- Compare panes carry diff mode, scroll binding, diff folds, and a winbar label
-- that Neovim copies into other windows: into a new window split or floated
-- from a pane, and into a window that shows the pane's buffer without an
-- option record of its own for it, from the pane itself or from the record the
-- pane leaves behind. This module tells such copies apart from windows whose
-- options are their own, and has Compare remove the copied state.
--
-- Provenance comes first. A new window copies the window it was created from,
-- and a window that shows a buffer for the first time copies another window or
-- record for that buffer. When the only windows in diff mode on that buffer are
-- live panes, a copied 'diff' came from a pane. Option writes cannot hide this,
-- including ftplugins and autocommands that run without OptionSet.
--
-- Records, sessions, and views outlive the panes, so a pane also marks its
-- options: exactly one suffix of four ASCII separator characters (FS, GS, RS,
-- US) on 'foldignore'. Neovim copies 'foldignore' on every path that copies
-- window options and saves it in records, sessions, and views. Only indent
-- folding in the same window reads it, for lines that start with it, and text
-- lines do not start with these characters. Removing it restores the value.
-- A mark counts only on a buffer a pane has shown, or in a window a session or
-- view just restored.
local util = require("lazyvcs.util")
local M = {}
local suffix = "\28\29\30\31"
-- Pane window -> the buffer it holds Compare state for, false while it shows
-- another buffer, such as a picker preview.
local panes = {}
-- Buffers a pane has shown during this session of Neovim.
local shown = {}
-- Window -> buffers it has shown since LazyVCS loaded. Neovim saves options per
-- window and buffer, so such a window has a record of its own for them.
local seen = {}
-- The window that was current before the newest window was created.
local current
local installed = false

local function value(win)
	return tostring(util.get_win_option(win, "foldignore"))
end

-- Compare's own writes skip OptionSet, which handles user and session writes.
local function write(win, text)
	util.set_win_option_noautocmd(win, "foldignore", text)
end

local function strip(text)
	return (text:gsub(suffix, ""))
end

---Whether the window's 'foldignore' ends with exactly one mark.
function M.marked(win)
	local text = value(win)
	local first = text:find(suffix, 1, true)
	return first ~= nil and first == #text - #suffix + 1
end

local function add(win)
	local text = value(win)
	local wanted = strip(text) .. suffix
	if text ~= wanted then
		write(win, wanted)
	end
end

---Remove every mark from the window's 'foldignore'.
function M.unmark(win)
	local text = value(win)
	local wanted = strip(text)
	if text ~= wanted then
		write(win, wanted)
	end
end

---Mark a live Compare pane for the buffer it shows now.
function M.mark(win)
	M.setup()
	local buf = vim.api.nvim_win_get_buf(win)
	panes[win], shown[buf] = buf, true
	add(win)
end

---The pane no longer holds Compare state for the buffer it shows.
function M.deactivate(win)
	if panes[win] then
		panes[win] = false
	end
end

---The window is no longer a Compare pane.
function M.release(win)
	panes[win] = nil
end

function M.is_pane(win)
	return panes[win] ~= nil
end

---Whether the pane shows the buffer it holds Compare state for.
function M.active(win)
	local buf = panes[win]
	return buf and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf or false
end

---Mark every live pane again; an ftplugin or an autocommand may have replaced
---'foldignore' without OptionSet.
function M.refresh()
	for win in pairs(panes) do
		if M.active(win) and not M.marked(win) then
			add(win)
		end
	end
end

---Whether a window that is not a pane holds pane state it copied. `created`
---means the window is new: it copied the window it was created from.
function M.copied(win, created)
	if panes[win] ~= nil or not vim.api.nvim_win_is_valid(win) then
		return false
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if M.marked(win) and shown[buf] then
		return true
	end
	if created and current ~= win and current and M.active(current) and vim.api.nvim_win_get_buf(current) == buf then
		return true
	end
	-- A window with a record of its own for the buffer uses that record; a
	-- window in diff mode beside the user's own diff windows may copy theirs.
	if not util.get_win_option(win, "diff") or (not created and seen[win] and seen[win][buf]) then
		return false
	end
	local from_pane = false
	for _, other in ipairs(vim.fn.win_findbuf(buf)) do
		if other ~= win and util.get_win_option(other, "diff") then
			if not M.active(other) then
				return false
			end
			from_pane = true
		end
	end
	return from_pane
end

local function cleaner()
	return require("lazyvcs.compare_worktree").clean_copy
end

local function check(win, created)
	if vim.api.nvim_win_is_valid(win) then
		if M.copied(win, created) then
			cleaner()(win)
		end
		local buf = vim.api.nvim_win_get_buf(win)
		seen[win] = seen[win] or {}
		seen[win][buf] = true
	end
end

---Reset windows that a session or view restored with a mark and a pane's diff
---folds or diff mode: no live pane owns them. Elsewhere only remove the mark.
function M.sanitize()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if not panes[win] and M.marked(win) then
			if util.get_win_option(win, "diff") or util.get_win_option(win, "foldmethod") == "diff" then
				cleaner()(win)
			else
				M.unmark(win)
			end
		end
	end
end

function M.setup()
	if installed then
		return
	end
	installed = true
	current = vim.api.nvim_get_current_win()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		seen[win] = { [vim.api.nvim_win_get_buf(win)] = true }
	end
	local group = vim.api.nvim_create_augroup("lazyvcs_compare_marker", { clear = true })
	vim.api.nvim_create_autocmd("WinEnter", {
		group = group,
		callback = function()
			current = vim.api.nvim_get_current_win()
		end,
	})
	-- A new window copies the options of the window it was created from, and a
	-- window copies options for a buffer it shows without a record of its own:
	-- before BufEnter, which runs before BufWinEnter and the :loadview there, or
	-- before BufWinEnter alone for nvim_open_win() without focus.
	vim.api.nvim_create_autocmd({ "WinNew", "BufEnter", "BufWinEnter" }, {
		group = group,
		callback = util.safe_callback(function(args)
			check(vim.api.nvim_get_current_win(), args.event == "WinNew")
		end),
	})
	-- Neovim copies a pane's options when another window enters its buffer.
	-- Mark panes again before that copy, and after events that may replace
	-- 'foldignore' in a pane without OptionSet.
	vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
		group = group,
		callback = util.safe_callback(M.refresh),
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "FileType", "OptionSet" }, {
		group = group,
		callback = util.safe_callback(function()
			M.refresh()
			if next(panes) then
				vim.schedule(util.safe_callback(M.refresh))
			end
		end),
	})
	-- :setlocal, :set, and modelines replace the value. A live pane keeps the
	-- requested value with the mark added again. Elsewhere, a mark set outside a
	-- session or view on a buffer a pane showed is pane state; leave the reset to
	-- the next turn, after a session that is still loading has finished.
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "foldignore",
		callback = util.safe_callback(function()
			local win = vim.api.nvim_get_current_win()
			if M.active(win) then
				add(win)
			elseif not panes[win] and M.marked(win) and shown[vim.api.nvim_win_get_buf(win)] then
				vim.schedule(util.safe_callback(function()
					check(win, false)
				end))
			end
		end),
	})
	-- A session or view sets window options after WinNew and BufEnter have run;
	-- views end with this event too.
	vim.api.nvim_create_autocmd("SessionLoadPost", {
		group = group,
		callback = util.safe_callback(M.sanitize),
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = util.safe_callback(function(args)
			local win = tonumber(args.match)
			if win then
				-- Neovim saves the closing window's options for its buffer next.
				if M.active(win) then
					require("lazyvcs.compare_worktree").reset_pane(win)
				end
				panes[win], seen[win] = nil, nil
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			shown[args.buf] = nil
		end,
	})
end

---Install the handlers and reset windows that a session restored with a mark.
function M.load()
	M.setup()
	M.sanitize()
end

return M
