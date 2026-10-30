-- Window presentation only. The comparison owners decide eligibility and size.
local util = require("lazyvcs.util")
local api = vim.api
local M = {}
local busy = 0
local windows, records = {}, {}

local function restore(win, record)
	for name, value in pairs(record.before) do
		if util.get_win_option(win, name) == record.written[name] then
			util.set_win_option(win, name, value)
		end
	end
end

local function strip_window(win)
	local buf = api.nvim_win_get_buf(win)
	if windows[win] and windows[win].buf == buf then
		return
	end
	-- Newest writes take precedence; do not interpret a restored raw value as
	-- another record's write during this cleanup.
	local restored = {}
	local saved = records[buf] or {}
	for i = #saved, 1, -1 do
		for name, value in pairs(saved[i].before) do
			if not restored[name] and util.get_win_option(win, name) == saved[i].written[name] then
				util.set_win_option(win, name, value)
				restored[name] = true
			end
		end
	end
end

local cleanup_group = api.nvim_create_augroup("LazyVCSAbsentRailCleanup", { clear = true })
api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinNew" }, {
	group = cleanup_group,
	callback = util.safe_callback(function()
		strip_window(api.nvim_get_current_win())
	end),
})
api.nvim_create_autocmd("BufWipeout", {
	group = cleanup_group,
	callback = function(event)
		records[event.buf] = nil
		for win, record in pairs(windows) do
			if record.buf == event.buf then
				windows[win] = nil
			end
		end
	end,
})
api.nvim_create_autocmd("WinClosed", {
	group = cleanup_group,
	callback = function(event)
		windows[tonumber(event.match)] = nil
	end,
})

local function pack(...)
	return { n = select("#", ...), ... }
end

function M.internal(fn, ...)
	busy = busy + 1
	local result = pack(pcall(fn, ...))
	busy = busy - 1
	if not result[1] then
		error(result[2], 0)
	end
	return unpack(result, 2, result.n)
end

function M.guard(fn)
	return function(...)
		return M.internal(fn, ...)
	end
end

-- Read-only sidebar snapshots arrive as lines rather than decoded documents.
-- Check them once at installation, never on resize or cursor events.
function M.text_lines(lines)
	local size = 0
	for _, line in ipairs(lines) do
		size = size + #line + 1
		if size > 1024 * 1024 or line:find("\0", 1, true) then
			return false
		end
	end
	return true
end

function M.identity(s, key)
	if s.rail_key ~= key then
		s.rail_key, s.rail_expanded = key, false
	end
end

-- Return uncollapsed options for session projection without changing the view.
function M.user_options(s, win, values)
	local out = vim.deepcopy(values)
	local r = s.rail
	if r and r.win == win and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == r.buf then
		for name, value in pairs(r.before) do
			if out[name] == r.written[name] then
				out[name] = value
			end
		end
	end
	return out
end

function M.release(s)
	local r = s.rail
	s.rail = nil
	if not r then
		return
	end
	if windows[r.win] == r then
		windows[r.win] = nil
	end
	if api.nvim_win_is_valid(r.win) and api.nvim_win_get_buf(r.win) == r.buf then
		restore(r.win, r)
	end
	for _, win in ipairs(api.nvim_list_wins()) do
		strip_window(win)
	end
end

function M.apply(s, win, stacked)
	local r = s.rail
	if r and (r.win ~= win or r.stacked ~= stacked or api.nvim_win_get_buf(win) ~= r.buf) then
		M.release(s)
		r = nil
	end
	if not win then
		M.release(s)
		return
	end
	if r then
		return
	end
	strip_window(win)
	local values = {
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
		[stacked and "winfixheight" or "winfixwidth"] = true,
	}
	r = { win = win, buf = api.nvim_win_get_buf(win), stacked = stacked, before = {}, written = values }
	s.rail = r
	for name, value in pairs(values) do
		r.before[name] = util.get_win_option(win, name)
		util.set_win_option(win, name, value)
	end
	windows[win] = r
	records[r.buf] = records[r.buf] or {}
	local saved = { before = r.before, written = r.written }
	for index, record in ipairs(records[r.buf]) do
		if vim.deep_equal(record, saved) then
			table.remove(records[r.buf], index)
			records[r.buf][#records[r.buf] + 1] = saved
			return
		end
	end
	records[r.buf][#records[r.buf] + 1] = saved
end

-- Sample WinEnter synchronously, then verify after temporary window calls and
-- picker routing have settled. Internal moves never enqueue an expansion.
function M.focus(s, blocked, expand)
	local r = s.rail
	if busy > 0 or not r or api.nvim_get_current_win() ~= r.win or blocked() then
		return
	end
	vim.schedule(util.safe_callback(function()
		if
			s.rail ~= r
			or busy > 0
			or blocked()
			or api.nvim_get_current_win() ~= r.win
			or not api.nvim_win_is_valid(r.win)
			or api.nvim_win_get_buf(r.win) ~= r.buf
		then
			return
		end
		s.rail_expanded = true
		M.internal(function()
			M.release(s)
			expand()
		end)
	end))
end

return M
