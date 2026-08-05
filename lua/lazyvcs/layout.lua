local util = require("lazyvcs.util")
local aerial = require("lazyvcs.integrations.aerial")
local editor = require("lazyvcs.integrations.editor")

local M = {}

local function sanitize_root(text)
	return (vim.fs.normalize(text or ""):gsub("[%c]", " "))
end

local function sanitize_relative(text)
	return (tostring(text or ""):gsub("[/\\]+", "/"):gsub("[%c]", " "))
end

local function base_buffer_name(session)
	local root = sanitize_root(session.root)
	local relpath = sanitize_relative(session.relpath)
	return string.format("lazyvcs://%s/%s//%s", session.backend, root, relpath)
end

local function resolve_base_buffer_name(session)
	local canonical = base_buffer_name(session)
	local existing = vim.fn.bufnr(canonical)
	if existing <= 0 or not util.buf_is_valid(existing) then
		return canonical
	end

	-- Reuse the canonical name when the previous scratch buffer is stale and hidden.
	if #vim.fn.win_findbuf(existing) == 0 then
		pcall(vim.api.nvim_buf_delete, existing, { force = true })
		if vim.fn.bufnr(canonical) <= 0 then
			return canonical
		end
	end

	local suffix = 2
	while true do
		local candidate = string.format("%s [%d]", canonical, suffix)
		local candidate_buf = vim.fn.bufnr(candidate)
		if candidate_buf <= 0 or not util.buf_is_valid(candidate_buf) then
			return candidate
		end
		suffix = suffix + 1
	end
end

local function resolve_base_width(width)
	if width <= 1 then
		return math.max(math.floor(vim.o.columns * width), 30)
	end

	return math.max(width, 30)
end

local function same_tab(win_a, win_b)
	return util.win_is_valid(win_a)
		and util.win_is_valid(win_b)
		and vim.api.nvim_win_get_tabpage(win_a) == vim.api.nvim_win_get_tabpage(win_b)
end

local function set_window_labels(session)
	if not session.opts.set_winbar then
		return
	end

	if util.win_is_valid(session.editable_win) then
		session.editable_prev_winbar = session.editable_prev_winbar or vim.wo[session.editable_win].winbar
		local right_label = session.right_label or session.base_label
		local right_role = session.readonly_comparison and "right" or "editable"
		vim.wo[session.editable_win].winbar =
			string.format(" lazyvcs %s %s [%s]", session.backend, right_label:lower(), right_role)
	end

	if util.win_is_valid(session.base_win) then
		session.base_prev_winbar = session.base_prev_winbar or vim.wo[session.base_win].winbar
		local left_label = session.left_label or session.base_label
		vim.wo[session.base_win].winbar = string.format(" lazyvcs %s %s [left]", session.backend, left_label:lower())
	end
end

local function configure_base_buffer(session)
	local buf = vim.api.nvim_create_buf(false, true)
	session.base_bufnr = buf
	session.aerial_base_state = aerial.disable_buffer(buf)
	editor.guard_scratch_buffer(buf)

	vim.api.nvim_buf_set_name(buf, resolve_base_buffer_name(session))
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].buflisted = false
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.bo[buf].filetype = vim.bo[session.editable_bufnr].filetype
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, session.base_lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
end

local function apply_diff(winid)
	if util.win_is_valid(winid) then
		vim.api.nvim_win_call(winid, function()
			vim.cmd("silent diffthis")
		end)
	end
end

local function restore_winbar(winid, value)
	if util.win_is_valid(winid) then
		vim.wo[winid].winbar = value or ""
	end
end

local function restore_window_option(winid, name, value)
	if util.win_is_valid(winid) and value ~= nil then
		vim.wo[winid][name] = value
	end
end

local tracked_window_options = {
	"diff",
	"scrollbind",
	"cursorbind",
	"smoothscroll",
	"foldenable",
	"foldmethod",
	"foldcolumn",
	"wrap",
	"linebreak",
	"breakindent",
}

local function capture_window_options(winid)
	local values = {}
	for _, name in ipairs(tracked_window_options) do
		values[name] = vim.wo[winid][name]
	end
	return values
end

local function restore_window_options(winid, values)
	if not util.win_is_valid(winid) or not values then
		return
	end
	for _, name in ipairs(tracked_window_options) do
		restore_window_option(winid, name, values[name])
	end
end

---Reset diff mode in one owned window without touching unrelated diff groups.
function M.reset_tab_diff(winid)
	local target = winid
	if not util.win_is_valid(target) then
		target = vim.api.nvim_get_current_win()
	end

	if util.win_is_valid(target) then
		vim.api.nvim_win_call(target, function()
			vim.cmd("silent diffoff")
		end)
	end
end

function M.open(session)
	local current_win = vim.api.nvim_get_current_win()
	local editable_win = vim.api.nvim_win_get_buf(current_win) == session.editable_bufnr and current_win
		or vim.fn.bufwinid(session.editable_bufnr)
	if editable_win == -1 then
		vim.cmd.buffer(session.editable_bufnr)
		editable_win = vim.api.nvim_get_current_win()
	end

	session.editable_win = editable_win
	session.editable_had_diff = vim.wo[editable_win].diff
	session.editable_prev_scrollbind = vim.wo[editable_win].scrollbind
	session.editable_window_options = capture_window_options(editable_win)

	configure_base_buffer(session)
	vim.api.nvim_set_current_win(editable_win)

	-- Place the read-only base (OLD) buffer on the LEFT and keep the editable
	-- (NEW) buffer on the RIGHT, matching the universal diff convention used by
	-- git, VS Code, GitHub, and vimdiff (old -> new reads left -> right).
	vim.cmd("leftabove vsplit")
	session.base_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(session.base_win, session.base_bufnr)
	session.base_had_diff = false

	vim.cmd.wincmd("p")

	-- Captured before we change anything: if the base window cannot be closed
	-- later (`:only` from the left pane leaves it as the last window), it falls
	-- back to the user's file still carrying our settings -- most damagingly
	-- `winfixwidth`, which then silently refuses every resize for the rest of
	-- the session.
	session.base_window_options = capture_window_options(session.base_win)

	vim.wo[session.base_win].number = vim.wo[editable_win].number
	vim.wo[session.base_win].relativenumber = false
	vim.wo[session.base_win].wrap = vim.wo[editable_win].wrap
	vim.wo[session.base_win].linebreak = vim.wo[editable_win].linebreak
	vim.wo[session.base_win].breakindent = vim.wo[editable_win].breakindent
	vim.wo[session.base_win].cursorline = false
	vim.wo[session.base_win].winfixwidth = true

	local width = resolve_base_width(session.opts.base_window.width)
	pcall(vim.api.nvim_win_set_width, session.base_win, width)

	apply_diff(editable_win)
	apply_diff(session.base_win)

	-- `:diffthis` already sets 'scrollbind' and 'cursorbind' and adds "hor" to
	-- 'scrollopt' (:h diff.txt). Re-assert the two window-local ones anyway:
	-- they are reset to the global value when a window edits another file, and
	-- an ftplugin or colorscheme loaded after us can clear them, which silently
	-- unbinds the pair with no other symptom than "scrolling stopped working".
	local cursor_sync = session.opts.base_window.cursor_sync
	for _, win in ipairs({ editable_win, session.base_win }) do
		vim.wo[win].scrollbind = true
		vim.wo[win].cursorbind = cursor_sync
	end

	vim.api.nvim_win_call(editable_win, function()
		vim.cmd("silent syncbind")
	end)

	require("lazyvcs.align").apply(session)
	session.tabpage = vim.api.nvim_win_get_tabpage(editable_win)
	set_window_labels(session)
end

---True when either pane soft-wraps, so buffer lines and screen rows diverge.
function M.panes_wrap(session)
	return (util.win_is_valid(session.editable_win) and vim.wo[session.editable_win].wrap)
		or (util.win_is_valid(session.base_win) and vim.wo[session.base_win].wrap)
		or false
end

function M.rebalance(session)
	if not session or session.closing then
		return false
	end

	if not same_tab(session.editable_win, session.base_win) then
		return false
	end

	local editable_width = vim.api.nvim_win_get_width(session.editable_win)
	local base_width = vim.api.nvim_win_get_width(session.base_win)
	if editable_width <= 0 or base_width <= 0 then
		return false
	end

	-- Before the early return below, not after. Any width change re-wraps every
	-- line and invalidates the row measurements, but a proportional resize
	-- leaves the split still balanced -- so the early return fired and the
	-- padding kept the old width's values. Nothing else covers it either: a pure
	-- width change produces no topline/topfill/leftcol/skipcol delta, so the
	-- WinScrolled path treats it as "not a scroll" and skips alignment too.
	require("lazyvcs.align").schedule(session)

	local total_width = editable_width + base_width
	local target_base = math.max(math.floor(total_width / 2), 1)
	local target_editable = math.max(total_width - target_base, 1)

	if math.abs(editable_width - target_editable) <= 1 and math.abs(base_width - target_base) <= 1 then
		return false
	end

	local base_fix = vim.wo[session.base_win].winfixwidth
	vim.wo[session.base_win].winfixwidth = false

	local ok = pcall(vim.api.nvim_win_set_width, session.base_win, target_base)

	vim.wo[session.base_win].winfixwidth = base_fix
	session.tabpage = vim.api.nvim_win_get_tabpage(session.editable_win)
	set_window_labels(session)

	-- A width change re-wraps every line, so all row math is stale and the panes
	-- can be left offset. Re-sync rather than leaving the pair crooked until the
	-- user happens to scroll.
	M.sync_scroll(
		session,
		vim.api.nvim_get_current_win() == session.base_win and session.base_win or session.editable_win
	)
	require("lazyvcs.align").schedule(session)
	return ok
end

function M.sync_scroll(session, source_win)
	if not session or session.closing or session.syncing_scroll then
		return false
	end

	if source_win ~= session.editable_win and source_win ~= session.base_win then
		return false
	end

	if not same_tab(session.editable_win, session.base_win) then
		return false
	end

	session.syncing_scroll = true
	local ok = pcall(vim.api.nvim_win_call, source_win, function()
		vim.cmd("silent! syncbind")
	end)

	-- Clear on the next tick, not here: WinScrolled is dispatched from the main
	-- loop rather than synchronously (:h WinScrolled), so the echo event caused
	-- by the sync above arrives after this function has already returned. Held
	-- across one tick, the flag actually suppresses it.
	vim.schedule(function()
		session.syncing_scroll = false
	end)
	return ok
end

function M.refresh(session)
	set_window_labels(session)
	if util.win_is_valid(session.editable_win) then
		vim.api.nvim_win_call(session.editable_win, function()
			vim.cmd("silent diffupdate")
		end)
	end
	require("lazyvcs.align").schedule(session)
end

function M.close(session, opts)
	opts = opts or {}

	require("lazyvcs.align").clear(session)

	if util.win_is_valid(session.editable_win) then
		pcall(vim.api.nvim_win_call, session.editable_win, function()
			if not session.editable_had_diff then
				vim.cmd("silent diffoff")
			end
		end)
		if session.opts.set_winbar then
			restore_winbar(session.editable_win, session.editable_prev_winbar)
		end
		restore_window_options(session.editable_win, session.editable_window_options)
	end

	if util.win_is_valid(session.base_win) then
		pcall(vim.api.nvim_win_call, session.base_win, function()
			if not session.base_had_diff then
				vim.cmd("silent diffoff")
			end
		end)
		if session.opts.set_winbar then
			restore_winbar(session.base_win, session.base_prev_winbar)
		end
		if not pcall(vim.api.nvim_win_close, session.base_win, true) then
			-- The base window survived -- it was the last one in the tab. It now
			-- shows the user's own file, so put back everything we changed.
			restore_window_options(session.base_win, session.base_window_options)
			vim.wo[session.base_win].winfixwidth = false
		end
	end

	if util.buf_is_valid(session.base_bufnr) then
		aerial.restore_buffer(session.aerial_base_state)
		-- Skip when Neovim is already wiping this buffer (we were called from its own
		-- BufWipeout): deleting it again raises E937, which aborts the user's :q.
		if not session.base_wiping then
			pcall(vim.api.nvim_buf_delete, session.base_bufnr, { force = true })
		end
	end

	if opts.reset_tab_diff then
		M.reset_tab_diff(session.editable_win)
	end
end

return M
