-- Model of Neovim's per-buffer window option records (buffer.c b_wininfo).
--
-- A window saves its options for a buffer when it leaves that buffer or closes
-- while showing it, and that record moves to the front of the buffer's list
-- (buflist_setfpos). A window entering a buffer restores its own record. A
-- window without one copies options from the first usable record
-- (find_wininfo, get_winopts): the live options of that record's window while
-- it still shows the buffer, otherwise the saved copy. Saved records with
-- 'diff' from windows outside the current tab, including closed windows, are
-- skipped. Minimal-style windows contribute no options. A new buffer starts
-- with one unsaved record for the window that was current. A split that edits
-- another file at once (:new, :split {file}, :tabedit) saves no record for the
-- buffer it was split from; a later buffer change in it does.
--
-- Compare uses this to tell options copied from its panes from a window's own.
-- History from before setup() is unknown, so such records count as absent.
local util = require("lazyvcs.util")
local M = {}
-- buf -> list of { win = id|false after closing, id, saved, diff, pane }, most recent first
local records = {}
local by_win = {} -- win -> set of buffers with a record for that window
local displayed = {} -- win -> buffer shown at its last BufWinEnter
local fresh = {} -- split windows not yet past the command that created them
local listeners = {}
local markers = {}
local snapshot
local installed = false

local function tracked(win)
	return vim.api.nvim_win_is_valid(win) and vim.fn.win_gettype(win) ~= "autocmd"
end

local function minimal(win)
	return vim.api.nvim_win_get_config(win).style == "minimal"
end

-- Compare panes carry diff mode, bindings, diff folds, and a label until they
-- are reset before releasing a buffer. Markers recognize the same state copied
-- into other windows, such as a float opened from a pane.
local function pane_state(win, buf)
	if vim.w[win].lazyvcs_compare then
		local values = util.capture_win_options(win, { "diff", "scrollbind", "cursorbind", "foldmethod", "winbar" })
		if
			values.diff
			or values.scrollbind
			or values.cursorbind
			or values.foldmethod == "diff"
			or values.winbar ~= ""
		then
			return true
		end
	end
	for _, marker in ipairs(markers) do
		if marker(win, buf) then
			return true
		end
	end
	return false
end

local function state_of(win, buf)
	return { diff = util.get_win_option(win, "diff") == true, pane = pane_state(win, buf) }
end

local function remove(list, win)
	for index, entry in ipairs(list) do
		if entry.win == win then
			table.remove(list, index)
			return entry
		end
	end
end

local function save(buf, win, state)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local list = records[buf] or {}
	records[buf] = list
	remove(list, win)
	table.insert(list, 1, { win = win, id = win, saved = true, diff = state.diff, pane = state.pane })
	by_win[win] = by_win[win] or {}
	by_win[win][buf] = true
end

local function closed(win)
	for buf in pairs(by_win[win] or {}) do
		local list, kept = records[buf] or {}, false
		for index = 1, #list do
			local entry = list[index]
			if entry and entry.win == false then
				kept = true
			elseif entry and entry.win == win then
				if vim.api.nvim_win_is_valid(win) and minimal(win) then
					entry.saved = false
				end
				-- Neovim keeps only the most recent record of a closed window.
				if kept then
					table.remove(list, index)
				else
					entry.id, entry.win, kept = win, false, true
					for later = #list, index + 1, -1 do
						if list[later].win == false then
							table.remove(list, later)
						end
					end
				end
				break
			end
		end
	end
	by_win[win], displayed[win], fresh[win] = nil, nil, nil
end

---Return where Neovim takes the options of `win` entering `buf`, as get_winopts
---does: "own" record, "live" options of another window showing the buffer,
---"saved" copy, or "none" for global values; with the record used. Call it
---before this entry updates the model.
function M.origin(win, buf)
	local list = records[buf] or {}
	for _, entry in ipairs(list) do
		if entry.win == win and entry.saved then
			return "own", entry
		end
	end
	local tab = vim.api.nvim_win_get_tabpage(win)
	for _, entry in ipairs(list) do
		local open = entry.win and vim.api.nvim_win_is_valid(entry.win)
		local here = open and vim.api.nvim_win_get_tabpage(entry.win) == tab
		local live = open and vim.api.nvim_win_get_buf(entry.win) == buf
		if not (entry.saved and entry.diff and not here) and (entry.saved or live) then
			if live and entry.win ~= win and not minimal(entry.win) then
				return "live", entry
			end
			if entry.saved and (not open or entry.win == win or not minimal(entry.win)) then
				return "saved", entry
			end
			return "none"
		end
	end
	return "none"
end

local function classify(kind, entry, buf)
	if kind == "own" then
		return "own"
	end
	if kind == "live" then
		return pane_state(entry.win, buf) and "pane" or "clean"
	end
	return kind == "saved" and entry.pane and "pane" or "clean"
end

---Classify the options `win` received entering `buf`: "own", "pane" when they
---came from a Compare pane, or "clean".
function M.source(win, buf)
	local kind, entry = M.origin(win, buf)
	return classify(kind, entry, buf)
end

---Add `marker(win, buf)`, true when `win` holds Compare pane state for `buf`.
function M.add_marker(marker)
	markers[#markers + 1] = marker
end

---Call `listener(win, buf, source, origin, origin_win)` after a window enters a
---buffer. Returns a function that removes the listener.
function M.on_enter(listener)
	listeners[#listeners + 1] = listener
	return function()
		for index, value in ipairs(listeners) do
			if value == listener then
				table.remove(listeners, index)
				return
			end
		end
	end
end

function M.setup()
	if installed then
		return
	end
	installed = true
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if tracked(win) then
			displayed[win] = vim.api.nvim_win_get_buf(win)
		end
	end
	local group = vim.api.nvim_create_augroup("lazyvcs_window_records", { clear = true })
	vim.api.nvim_create_autocmd("BufNew", {
		group = group,
		callback = util.safe_callback(function(args)
			local win = vim.api.nvim_get_current_win()
			-- BufNew also follows a rename, which keeps the existing records.
			if tracked(win) and not records[args.buf] then
				records[args.buf] = { { win = win, id = win, saved = false, diff = false, pane = false } }
				by_win[win] = by_win[win] or {}
				by_win[win][args.buf] = true
			end
		end),
	})
	-- A split starts on its parent's buffer without BufWinEnter. Floats change
	-- buffers like :buffer does, so they always save a record.
	vim.api.nvim_create_autocmd("WinNew", {
		group = group,
		callback = util.safe_callback(function()
			local win = vim.api.nvim_get_current_win()
			if tracked(win) and not displayed[win] then
				displayed[win] = vim.api.nvim_win_get_buf(win)
				if vim.api.nvim_win_get_config(win).relative == "" then
					fresh[win] = true
					vim.schedule(function()
						fresh[win] = nil
					end)
				end
			end
		end),
	})
	-- Window options are still the departing buffer's at BufLeave. It also fires
	-- when focus moves to another window, so BufWinEnter confirms the departure.
	vim.api.nvim_create_autocmd("BufLeave", {
		group = group,
		callback = util.safe_callback(function(args)
			local win = vim.api.nvim_get_current_win()
			if tracked(win) then
				snapshot = vim.tbl_extend("force", state_of(win, args.buf), { win = win, buf = args.buf })
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = group,
		callback = util.safe_callback(function(args)
			local win = vim.api.nvim_get_current_win()
			if not tracked(win) then
				return
			end
			local kind, entry = M.origin(win, args.buf)
			local source = classify(kind, entry, args.buf)
			local previous = displayed[win]
			if previous and previous ~= args.buf and not fresh[win] then
				local state = snapshot
				if not (state and state.win == win and state.buf == previous) then
					state = { diff = false, pane = vim.w[win].lazyvcs_compare == true }
				end
				save(previous, win, state)
			end
			displayed[win], fresh[win], snapshot = args.buf, nil, nil
			for _, listener in ipairs(listeners) do
				listener(win, args.buf, source, kind, entry and entry.id)
			end
		end),
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = util.safe_callback(function(args)
			local win = tonumber(args.match)
			if win and tracked(win) then
				local buf = vim.api.nvim_win_get_buf(win)
				save(buf, win, state_of(win, buf))
			end
			if win then
				closed(win)
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = util.safe_callback(function(args)
			for _, entry in ipairs(records[args.buf] or {}) do
				if entry.win and by_win[entry.win] then
					by_win[entry.win][args.buf] = nil
				end
			end
			records[args.buf] = nil
		end),
	})
end

return M
