local util = require("lazyvcs.util")
local aerial = require("lazyvcs.integrations.aerial")
local editor = require("lazyvcs.integrations.editor")
local highlighting = require("lazyvcs.highlighting")

local M = {}
local departed_buffers = {}

local function sanitize_root(text)
	return (util.normalize_literal_path(text or ""):gsub("[%c]", " "))
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
		session.editable_label = string.format(" lazyvcs %s %s [%s]", session.backend, right_label:lower(), right_role)
		util.set_win_option(session.editable_win, "winbar", session.editable_label)
	end

	if util.win_is_valid(session.base_win) then
		session.base_prev_winbar = session.base_prev_winbar or util.get_win_option(session.base_win, "winbar")
		local left_label = session.left_label or session.base_label
		session.base_label_winbar = string.format(" lazyvcs %s %s [left]", session.backend, left_label:lower())
		util.set_win_option(session.base_win, "winbar", session.base_label_winbar)
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
	vim.bo[buf].undolevels = -1
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.bo[buf].filetype = vim.bo[session.editable_bufnr].filetype
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, session.base_lines)
	if session.base_text then
		vim.bo[buf].endofline = session.base_text.eol
		vim.bo[buf].fixendofline = false
	end
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

-- close_buffer saves wininfo before BufWinLeave. Clean inherited records on entry,
-- before a transfer can capture them as the next session's original options.
function M.remember_departed(session)
	departed_buffers[session.editable_bufnr] = {
		options = session.editable_window_options,
		applied = session.editable_applied_options,
		winbar = session.editable_prev_winbar,
		label = session.editable_label,
	}
end

function M.forget_departed(bufnr)
	departed_buffers[bufnr] = nil
end

local function undo_applied(win, record, bindings_only)
	if not record or not record.options or not record.applied then
		return
	end
	local current = capture_window_options(win)
	local values = vim.deepcopy(current)
	for name, value in pairs(record.options) do
		if
			(not bindings_only or name == "diff" or name == "scrollbind" or name == "cursorbind")
			and current[name] == record.applied[name]
		then
			values[name] = value
		end
	end
	if current.diff and not values.diff then
		util.diff_off(win)
	end
	-- diffoff can restore native saved options too. Preserve values the user or
	-- the incoming buffer changed since we applied the session's options.
	restore_window_options(win, values)
	if record.label and util.get_win_option(win, "winbar") == record.label then
		restore_winbar(win, record.winbar)
	end
end

function M.cleanup_buffer(bufnr, win)
	local owned = require("lazyvcs.state").for_window(win)
	if
		owned
		and not owned.closing
		and owned.phase == "active"
		and (owned.editable_bufnr == bufnr or owned.base_bufnr == bufnr)
	then
		return
	end
	undo_applied(win, departed_buffers[bufnr])
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

local function save_owned(token)
	local s = token.session
	return require("lazyvcs.state").get(token.buf) == s
		and s.id == token.id
		and s.editable_bufnr == token.buf
		and s.editable_win == token.win
		and s.base_win == token.base_win
		and s.base_bufnr == token.base_buf
		and valid_pair(s)
end

-- Changing diff/foldmethod can recompute folds in every diff window in the tab.
-- winsaveview does not include which folds the user opened.
local function capture_folds(win)
	return vim.api.nvim_win_call(win, function()
		local closed, line = {}, 1
		while line <= vim.api.nvim_buf_line_count(0) do
			local first = vim.fn.foldclosed(line)
			if first == -1 then
				line = line + 1
			else
				closed[#closed + 1] = first
				line = vim.fn.foldclosedend(line) + 1
			end
		end
		return closed
	end)
end

local function restore_folds(win, closed)
	vim.api.nvim_win_call(win, function()
		local line = 1
		while line <= vim.api.nvim_buf_line_count(0) do
			if vim.fn.foldclosed(line) == -1 then
				line = line + 1
			else
				vim.api.nvim_win_set_cursor(win, { line, 0 })
				vim.cmd("silent! noautocmd keepjumps normal! zO")
			end
		end
		for _, first in ipairs(closed) do
			vim.api.nvim_win_set_cursor(win, { first, 0 })
			vim.cmd("silent! noautocmd keepjumps normal! zc")
		end
	end)
end

function M.prepare_session_save(session, tokens)
	if session.phase ~= "active" or session.readonly_comparison or not valid_pair(session) then
		return
	end
	local token = {
		session = session,
		id = session.id,
		win = session.editable_win,
		buf = session.editable_bufnr,
		base_win = session.base_win,
		base_buf = session.base_bufnr,
		windows = {},
		views = {},
		changedtick = vim.api.nvim_buf_get_changedtick(session.editable_bufnr),
	}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tabpage)) do
		local buf = vim.api.nvim_win_get_buf(win)
		local diff = util.get_win_option(win, "diff")
		if win == session.editable_win or win == session.base_win or diff then
			token.views[win] = {
				buf = buf,
				view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
				folds = capture_folds(win),
			}
		end
		if
			win == session.editable_win
			or (buf == session.editable_bufnr and diff and not (session.preexisting_diff_windows or {})[win])
		then
			token.windows[win] = {
				options = capture_window_options(win),
				winbar = util.get_win_option(win, "winbar"),
			}
		end
	end
	tokens[#tokens + 1] = token
	session.phase = "saving"
	for win, record in pairs(token.windows) do
		for name, value in pairs(session.editable_window_options) do
			if record.options[name] == session.editable_applied_options[name] then
				util.set_win_option_noautocmd(win, name, value)
			end
		end
		if session.editable_label and record.winbar == session.editable_label then
			util.set_win_option_noautocmd(win, "winbar", session.editable_prev_winbar)
		end
	end
end

function M.finish_session_save(token)
	local session = token.session
	if not save_owned(token) then
		if session.phase == "saving" then
			session.phase = "active"
			require("lazyvcs.actions").resume_session_save(session)
		end
		return
	end
	local failure
	local function restore(fn, ...)
		local ok, err = pcall(fn, ...)
		if not ok then
			failure = failure or err
		end
	end
	for win, record in pairs(token.windows) do
		if util.win_is_valid(win) and vim.api.nvim_win_get_buf(win) == token.buf then
			for name, value in pairs(record.options) do
				restore(util.set_win_option_noautocmd, win, name, value)
			end
			restore(util.set_win_option_noautocmd, win, "winbar", record.winbar)
		end
	end
	restore(vim.api.nvim_win_call, token.win, function()
		vim.cmd("silent! noautocmd diffupdate")
	end)
	for win, record in pairs(token.views) do
		if util.win_is_valid(win) and vim.api.nvim_win_get_buf(win) == record.buf then
			restore(restore_folds, win, record.folds)
		end
	end
	for win, record in pairs(token.views) do
		if util.win_is_valid(win) and vim.api.nvim_win_get_buf(win) == record.buf then
			restore(vim.api.nvim_win_call, win, function()
				vim.fn.winrestview(record.view)
			end)
		end
	end
	session.phase = "active"
	if vim.api.nvim_buf_get_changedtick(session.editable_bufnr) ~= token.changedtick then
		require("lazyvcs.actions").resume_session_save(session)
	end
	if failure then
		error(failure)
	end
end

function M.bind_pair(session, source_win)
	if not valid_pair(session) or session.phase == "saving" then
		return false
	end
	for _, win in ipairs({ session.editable_win, session.base_win }) do
		apply_diff(win)
		highlighting.apply(win, session.opts.diff_highlighting)
		util.set_win_options(win, { scrollbind = true, cursorbind = session.opts.base_window.cursor_sync })
	end
	session.editable_applied_options = capture_window_options(session.editable_win)
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
		"base_prev_winfixwidth",
		"aerial_base_state",
		"owned_editor_win",
	}) do
		replacement[key] = old[key]
	end
	-- The target is now displayed in EW. Its FileType/window settings belong to
	-- this session; restoring the previous buffer's snapshot would overwrite them.
	util.diff_off(replacement.editable_win)
	M.forget_departed(replacement.editable_bufnr)
	replacement.editable_window_options = capture_window_options(replacement.editable_win)
	replacement.editable_prev_winbar = util.get_win_option(replacement.editable_win, "winbar")
	replacement.editable_had_diff = util.get_win_option(replacement.editable_win, "diff")
	util.diff_off(replacement.base_win)
	local buf = replacement.base_bufnr
	vim.bo[buf].modifiable = true
	vim.bo[buf].readonly = false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, replacement.base_lines)
	if replacement.base_text then
		vim.bo[buf].endofline = replacement.base_text.eol
		vim.bo[buf].fixendofline = false
	end
	vim.bo[buf].filetype = vim.bo[replacement.editable_bufnr].filetype
	local old_name = vim.api.nvim_buf_get_name(buf)
	local new_name = resolve_base_buffer_name(replacement)
	vim.api.nvim_buf_set_name(buf, new_name)
	-- Renaming a named buffer creates an unlisted alternate with the old name.
	if old_name ~= "" and old_name ~= new_name then
		local alternate = vim.fn.bufnr(old_name)
		if alternate > 0 and alternate ~= buf and #vim.fn.win_findbuf(alternate) == 0 then
			pcall(vim.api.nvim_buf_delete, alternate, { force = true })
		end
	end
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	set_window_labels(replacement)
end

function M.open(session)
	local current_win = vim.api.nvim_get_current_win()
	local editable_win = session.editable_win
		or (
			vim.api.nvim_win_get_buf(current_win) == session.editable_bufnr and current_win
			or vim.fn.bufwinid(session.editable_bufnr)
		)
	if editable_win == -1 then
		vim.cmd.buffer(session.editable_bufnr)
		editable_win = vim.api.nvim_get_current_win()
	end

	assert(
		util.win_is_valid(editable_win) and vim.api.nvim_win_get_buf(editable_win) == session.editable_bufnr,
		"Editor destination changed while opening"
	)
	session.editable_win = editable_win
	session.tabpage = vim.api.nvim_win_get_tabpage(editable_win)
	session.preexisting_diff_windows = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tabpage)) do
		if util.get_win_option(win, "diff") then
			session.preexisting_diff_windows[win] = true
		end
	end
	M.forget_departed(session.editable_bufnr)
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
	session.base_prev_winfixwidth = util.get_win_option(session.base_win, "winfixwidth")
	session.base_prev_winbar = util.get_win_option(session.base_win, "winbar")
	util.show_win_buffer(session.base_win, session.base_bufnr)
	assert(valid_pair(session), "Comparison panes changed while opening")
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
		if vim.api.nvim_win_get_buf(session.editable_win) == session.editable_bufnr then
			if not session.editable_had_diff then
				util.diff_off(session.editable_win)
			end
			if session.opts.set_winbar then
				restore_winbar(session.editable_win, session.editable_prev_winbar)
			end
			restore_window_options(session.editable_win, session.editable_window_options)
		else
			M.remember_departed(session)
			undo_applied(session.editable_win, departed_buffers[session.editable_bufnr], true)
		end
	end

	if util.win_is_valid(session.base_win) then
		local owns_buffer = vim.api.nvim_win_get_buf(session.base_win) == session.base_bufnr
		if not session.base_had_diff then
			util.diff_off(session.base_win)
		end
		if session.opts.set_winbar and util.get_win_option(session.base_win, "winbar") == session.base_label_winbar then
			restore_winbar(session.base_win, session.base_prev_winbar)
		end
		if owns_buffer then
			if not pcall(vim.api.nvim_win_close, session.base_win, true) then
				base_survived = true
			end
		else
			util.set_win_options(session.base_win, { scrollbind = false, cursorbind = false })
			util.set_win_option(session.base_win, "winfixwidth", session.base_prev_winfixwidth or false)
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
		util.set_win_option(session.base_win, "winfixwidth", session.base_prev_winfixwidth or false)
		if session.opts.set_winbar then
			restore_winbar(session.base_win, session.base_prev_winbar)
		end
	end

	if opts.reset_tab_diff then
		M.reset_tab_diff(session.editable_win)
	end
end

return M
