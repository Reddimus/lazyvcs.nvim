local util = require("lazyvcs.util")
local aerial = require("lazyvcs.integrations.aerial")
local editor = require("lazyvcs.integrations.editor")
local highlighting = require("lazyvcs.highlighting")

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
	if existing == session.base_bufnr or existing <= 0 or not util.buf_is_valid(existing) then
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

local function resolve_base_width(session)
	local total = vim.api.nvim_win_get_width(session.editable_win) + vim.api.nvim_win_get_width(session.base_win)
	local width = session.opts.base_window.width
	local requested = math.floor(width <= 1 and total * width or width)
	local minimum = math.min(30, math.floor(total / 2))
	return math.max(minimum, math.min(total - minimum, requested))
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
		session.editable_prev_winbar = session.editable_prev_winbar
			or util.get_win_option(session.editable_win, "winbar")
		local right_label = session.right_label or session.base_label
		local right_role = session.readonly_comparison and "right" or "editable"
		util.set_win_option(
			session.editable_win,
			"winbar",
			string.format(" lazyvcs %s %s [%s]", session.backend, right_label:lower(), right_role)
		)
	end

	if util.win_is_valid(session.base_win) then
		session.base_prev_winbar = session.base_prev_winbar or util.get_win_option(session.base_win, "winbar")
		local left_label = session.left_label or session.base_label
		util.set_win_option(
			session.base_win,
			"winbar",
			string.format(" lazyvcs %s %s [left]", session.backend, left_label:lower())
		)
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
	if util.win_is_valid(winid) and not util.get_win_option(winid, "diff") then
		vim.api.nvim_win_call(winid, function()
			vim.cmd("silent diffthis")
		end)
	end
end

local function restore_winbar(winid, value)
	if util.win_is_valid(winid) then
		util.set_win_option(winid, "winbar", value or "")
	end
end

local function restore_window_option(winid, name, value)
	if util.win_is_valid(winid) and value ~= nil then
		util.set_win_option(winid, name, value)
	end
end

local tracked_window_options = {
	"number",
	"relativenumber",
	"cursorline",
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
	return util.capture_win_options(winid, tracked_window_options)
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
	if util.win_is_valid(winid) then
		util.diff_off(winid)
	end
end

---Restore splits that inherited this session's diff options, leaving earlier diff windows alone.
function M.release_derived_diff(session)
	if not session.tabpage or not vim.api.nvim_tabpage_is_valid(session.tabpage) then
		return
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tabpage)) do
		local buf = vim.api.nvim_win_get_buf(win)
		if
			win ~= session.editable_win
			and win ~= session.base_win
			and not (session.preexisting_diff_windows or {})[win]
			and (buf == session.editable_bufnr or buf == session.base_bufnr)
			and util.get_win_option(win, "diff")
		then
			util.diff_off(win)
		end
	end
end

function M.release_buffer_diff(session, bufnr)
	if not util.win_is_valid(session.editable_win) or not util.buf_is_valid(bufnr) then
		return
	end
	-- A pre-existing user diff window may still keep E in this tab's diff set.
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tabpage)) do
		if
			win ~= session.editable_win
			and vim.api.nvim_win_get_buf(win) == bufnr
			and util.get_win_option(win, "diff")
		then
			return
		end
	end
	vim.api.nvim_win_call(session.editable_win, function()
		vim.api.nvim_buf_call(bufnr, function()
			util.set_win_option(vim.api.nvim_get_current_win(), "diff", false)
		end)
	end)
end

local function valid_pair(session)
	return session
		and not session.closing
		and same_tab(session.editable_win, session.base_win)
		and vim.api.nvim_win_get_tabpage(session.editable_win) == session.tabpage
		and vim.api.nvim_win_get_buf(session.editable_win) == session.editable_bufnr
		and vim.api.nvim_win_get_buf(session.base_win) == session.base_bufnr
end

function M.bind_pair(session, source_win)
	if not valid_pair(session) then
		return false
	end
	for _, win in ipairs({ session.editable_win, session.base_win }) do
		apply_diff(win)
		highlighting.apply(win, session.opts.diff_highlighting)
		util.set_win_options(win, { scrollbind = true, cursorbind = session.opts.base_window.cursor_sync })
	end
	if source_win ~= session.editable_win and source_win ~= session.base_win then
		source_win = session.editable_win
	end
	vim.api.nvim_win_call(source_win, function()
		vim.cmd("silent syncbind")
	end)
	require("lazyvcs.align").apply(session)
	return true
end

function M.rebind(old, replacement)
	for _, key in ipairs({
		"editable_win",
		"base_win",
		"base_bufnr",
		"tabpage",
		"preexisting_diff_windows",
		"base_had_diff",
		"base_window_options",
		"base_prev_winbar",
		"aerial_base_state",
		"owned_editor_win",
	}) do
		replacement[key] = old[key]
	end
	-- The target is now displayed in EW. Its FileType/window settings belong to
	-- this session; restoring the previous buffer's snapshot would overwrite them.
	util.diff_off(replacement.editable_win)
	replacement.editable_window_options = capture_window_options(replacement.editable_win)
	replacement.editable_prev_winbar = util.get_win_option(replacement.editable_win, "winbar")
	replacement.editable_had_diff = util.get_win_option(replacement.editable_win, "diff")
	util.diff_off(replacement.base_win)
	local buf = replacement.base_bufnr
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, replacement.base_lines)
	vim.bo[buf].filetype = vim.bo[replacement.editable_bufnr].filetype
	vim.api.nvim_buf_set_name(buf, resolve_base_buffer_name(replacement))
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	set_window_labels(replacement)
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
	session.tabpage = vim.api.nvim_win_get_tabpage(editable_win)
	session.preexisting_diff_windows = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tabpage)) do
		if util.get_win_option(win, "diff") then
			session.preexisting_diff_windows[win] = true
		end
	end
	session.editable_had_diff = vim.wo[editable_win].diff
	session.editable_window_options = capture_window_options(editable_win)

	configure_base_buffer(session)
	vim.api.nvim_set_current_win(editable_win)

	-- Place the read-only base (OLD) buffer on the LEFT and keep the editable
	-- (NEW) buffer on the RIGHT, matching the universal diff convention used by
	-- git, VS Code, GitHub, and vimdiff (old -> new reads left -> right).
	vim.cmd("leftabove vsplit")
	session.base_win = vim.api.nvim_get_current_win()
	session.base_window_options = capture_window_options(session.base_win)
	session.base_prev_winbar = util.get_win_option(session.base_win, "winbar")
	util.show_win_buffer(session.base_win, session.base_bufnr)
	session.base_had_diff = false

	vim.cmd.wincmd("p")

	util.set_win_option(session.base_win, "number", vim.wo[editable_win].number)
	util.set_win_option(session.base_win, "relativenumber", false)
	util.set_win_option(session.base_win, "wrap", vim.wo[editable_win].wrap)
	util.set_win_option(session.base_win, "linebreak", vim.wo[editable_win].linebreak)
	util.set_win_option(session.base_win, "breakindent", vim.wo[editable_win].breakindent)
	util.set_win_option(session.base_win, "cursorline", false)
	util.set_win_option(session.base_win, "winfixwidth", true)

	session.tabpage = vim.api.nvim_win_get_tabpage(editable_win)
	session.phase = "active"
	pcall(vim.api.nvim_win_set_width, session.base_win, resolve_base_width(session))
	M.bind_pair(session, editable_win)
	set_window_labels(session)
end

---True when either pane soft-wraps, so buffer lines and screen rows diverge.
function M.panes_wrap(session)
	return (util.win_is_valid(session.editable_win) and vim.wo[session.editable_win].wrap)
		or (util.win_is_valid(session.base_win) and vim.wo[session.base_win].wrap)
		or false
end

function M.rebalance(session)
	if not session or session.closing or session.phase ~= "active" then
		return false
	end

	if not same_tab(session.editable_win, session.base_win) then
		return false
	end

	local ep, bp = vim.api.nvim_win_get_position(session.editable_win), vim.api.nvim_win_get_position(session.base_win)
	if
		ep[1] ~= bp[1]
		or vim.api.nvim_win_get_height(session.editable_win) ~= vim.api.nvim_win_get_height(session.base_win)
		or math.abs(ep[2] - bp[2])
			~= vim.api.nvim_win_get_width(ep[2] < bp[2] and session.editable_win or session.base_win) + 1
	then
		return false
	end
	local editable_width = vim.api.nvim_win_get_width(session.editable_win)
	local base_width = vim.api.nvim_win_get_width(session.base_win)
	if editable_width <= 0 or base_width <= 0 then
		return false
	end

	-- Resize invalidates wrapped measurements even if the split ratio is unchanged. Schedule
	-- before the early return; WinScrolled may see no positional change.
	require("lazyvcs.align").schedule(session)

	local total_width = editable_width + base_width
	local target_base = resolve_base_width(session)
	local target_editable = math.max(total_width - target_base, 1)

	if math.abs(editable_width - target_editable) <= 1 and math.abs(base_width - target_base) <= 1 then
		return false
	end

	local base_fix = vim.wo[session.base_win].winfixwidth
	util.set_win_option(session.base_win, "winfixwidth", false)

	local ok = pcall(vim.api.nvim_win_set_width, session.base_win, target_base)

	util.set_win_option(session.base_win, "winfixwidth", base_fix)
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
	if
		not valid_pair(session)
		or session.phase ~= "active"
		or session.syncing_scroll
		or require("lazyvcs.state").get(session.editable_bufnr) ~= session
	then
		return false
	end

	if source_win ~= session.editable_win and source_win ~= session.base_win then
		return false
	end

	if not same_tab(session.editable_win, session.base_win) then
		return false
	end

	for _, win in ipairs({ session.editable_win, session.base_win }) do
		if not util.get_win_option(win, "diff") or not util.get_win_option(win, "scrollbind") then
			return false
		end
	end
	session.syncing_scroll = true
	local ok = pcall(vim.api.nvim_win_call, source_win, function()
		vim.cmd("silent! syncbind")
	end)

	-- Keep the flag through the next tick to suppress the deferred WinScrolled echo from
	-- this sync.
	vim.schedule(function()
		if require("lazyvcs.state").get(session.editable_bufnr) == session then
			session.syncing_scroll = false
		end
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
	local base_survived = false
	M.release_derived_diff(session)
	highlighting.release(session.editable_win)
	highlighting.release(session.base_win)

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
			base_survived = true
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

	if base_survived and util.win_is_valid(session.base_win) then
		restore_window_options(session.base_win, session.base_window_options)
		util.set_win_option(session.base_win, "winfixwidth", false)
		if session.opts.set_winbar then
			restore_winbar(session.base_win, session.base_prev_winbar)
		end
	end

	if opts.reset_tab_diff then
		M.reset_tab_diff(session.editable_win)
	end
end

return M
