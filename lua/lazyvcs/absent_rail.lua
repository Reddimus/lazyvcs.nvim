-- Window presentation only. The comparison owners decide eligibility and size.
local util = require("lazyvcs.util")
local api = vim.api
local M = {}
local busy = 0
local windows, slots = {}, {}
local writing = 0

local function write(win, name, value)
	writing = writing + 1
	local ok, err = pcall(util.set_win_option, win, name, value)
	writing = writing - 1
	if not ok then
		error(err)
	end
end

local function restore(win, record, preserve, owner)
	owner = owner or { window = windows[record.win], slot = slots[record.slot] }
	local target = windows[win]
	for name, value in pairs(record.before) do
		-- Setters can run user callbacks which replace this lifetime or buffer.
		-- Snapshot bindings also permit cleanup of an unpublished partial apply.
		if
			not api.nvim_win_is_valid(win)
			or api.nvim_win_get_buf(win) ~= record.buf
			or record.session.rail ~= record
			or windows[record.win] ~= owner.window
			or slots[record.slot] ~= owner.slot
			or windows[win] ~= target
		then
			return
		end
		if name ~= preserve and util.get_win_option(win, name) == record.written[name] then
			write(win, name, value)
		end
	end
end

local function copied_record(win, token)
	token = token or util.get_win_option(win, "statuscolumn")
	---@cast token string
	local id = token:match("^%%#LazyVcsRailOwner(%d+)#%%%*$")
	local r = id and slots[tonumber(id)]
	if
		r
		and r.token == token
		and windows[r.win] == r
		and r.session.rail == r
		and api.nvim_win_get_buf(win) == r.buf
	then
		return r
	end
end

local function strip_window(win)
	local buf = api.nvim_win_get_buf(win)
	if windows[win] and windows[win].buf == buf then
		return
	end
	local r = copied_record(win)
	if r then
		restore(win, r)
	end
end

local function resume(r)
	if
		windows[r.win] == r
		and api.nvim_win_is_valid(r.win)
		and api.nvim_win_get_buf(r.win) == r.buf
		and r.suspended
	then
		for name, value in pairs(r.written) do
			write(r.win, name, value)
		end
		r.suspended = nil
	end
end

local cleanup_group = api.nvim_create_augroup("LazyVCSAbsentRailCleanup", { clear = true })
api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinNew" }, {
	group = cleanup_group,
	callback = util.safe_callback(function()
		local win = api.nvim_get_current_win()
		strip_window(win)
		local r = windows[win]
		if r then
			resume(r)
		end
	end),
})
api.nvim_create_autocmd("BufLeave", {
	group = cleanup_group,
	callback = util.safe_callback(function(event)
		local r = windows[api.nvim_get_current_win()]
		if r and r.buf == event.buf then
			-- Restore before Neovim caches this window's per-buffer options. A
			-- zero-width statuscolumn token also follows no-focus native clones.
			restore(r.win, r)
			r.suspended = true
			if not r.pending then
				r.pending = true
				vim.schedule(util.safe_callback(function()
					r.pending = nil
					resume(r)
				end))
			end
		end
	end),
})
api.nvim_create_autocmd("WinLeave", {
	group = cleanup_group,
	callback = util.safe_callback(function()
		local r = windows[api.nvim_get_current_win()]
		if r then
			resume(r)
		end
	end),
})
api.nvim_create_autocmd("OptionSet", {
	group = cleanup_group,
	pattern = { "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "winfixwidth", "winfixheight" },
	callback = util.safe_callback(function(event)
		if writing > 0 or vim.v.option_command == "setglobal" then
			return
		end
		local win = api.nvim_get_current_win()
		local r = windows[win]
		if r and api.nvim_win_get_buf(win) == r.buf and r.written[event.match] ~= nil then
			-- An equal write still expresses user intent. Keep the latest preference
			-- underneath the collapsed presentation, including raw statuscolumn.
			r.before[event.match] = util.get_win_option(win, event.match)
			if not r.suspended then
				write(win, event.match, r.written[event.match])
			end
		elseif not r or api.nvim_win_get_buf(win) ~= r.buf then
			-- A user WinNew hook may run before our clone cleanup. Preserve this
			-- edit while removing the remaining copied presentation immediately.
			local copied = copied_record(win, event.match == "statuscolumn" and vim.v.option_old or nil)
			if copied then
				restore(win, copied, event.match)
			end
		end
	end),
})
api.nvim_create_autocmd("BufWipeout", {
	group = cleanup_group,
	callback = util.safe_callback(function(event)
		local release = {}
		for _, record in pairs(windows) do
			if record.buf == event.buf then
				release[#release + 1] = record.session
			end
		end
		for _, s in ipairs(release) do
			M.release(s)
		end
	end),
})
api.nvim_create_autocmd("WinClosed", {
	group = cleanup_group,
	callback = util.safe_callback(function(event)
		local r = windows[tonumber(event.match)]
		if r then
			M.release(r.session)
		end
	end),
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
	if not r then
		return
	end
	local owner = { window = windows[r.win], slot = slots[r.slot] }
	-- Resolve visible native copies while the originating lifetime is live.
	for _, win in ipairs(api.nvim_list_wins()) do
		if api.nvim_win_is_valid(win) then
			strip_window(win)
		end
	end
	if api.nvim_win_is_valid(r.win) and api.nvim_win_get_buf(r.win) == r.buf then
		restore(r.win, r, nil, owner)
	end
	if windows[r.win] == r then
		windows[r.win] = nil
	end
	if slots[r.slot] == r then
		slots[r.slot] = nil
	end
	if s.rail == r then
		s.rail = nil
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
		resume(r)
		return
	end
	strip_window(win)
	local values = {
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		[stacked and "winfixheight" or "winfixwidth"] = true,
	}
	local id = 1
	while slots[id] do
		id = id + 1
	end
	local token = "%#LazyVcsRailOwner" .. id .. "#%*"
	values.statuscolumn = token
	r = {
		win = win,
		buf = api.nvim_win_get_buf(win),
		stacked = stacked,
		before = {},
		written = values,
		token = token,
		slot = id,
		session = s,
	}
	s.rail = r
	for name, value in pairs(values) do
		r.before[name] = util.get_win_option(win, name)
		write(win, name, value)
	end
	windows[win] = r
	slots[id] = r
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
