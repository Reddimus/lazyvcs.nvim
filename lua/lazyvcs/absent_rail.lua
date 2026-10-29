-- Window presentation only. The comparison owners decide eligibility and size.
local util = require("lazyvcs.util")
local api = vim.api
local M = {}
local busy = 0
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
	if not r or not api.nvim_win_is_valid(r.win) or api.nvim_win_get_buf(r.win) ~= r.buf then
		return
	end
	for name, value in pairs(r.before) do
		if util.get_win_option(r.win, name) == r.written[name] then
			util.set_win_option(r.win, name, value)
		end
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
