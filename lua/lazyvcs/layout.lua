local util = require("lazyvcs.util")
local aerial = require("lazyvcs.integrations.aerial")
local editor = require("lazyvcs.integrations.editor")
local highlighting = require("lazyvcs.highlighting")
local fold_state = require("lazyvcs.fold_state")
local rail = require("lazyvcs.absent_rail")

local M = {}
local departed_buffers = {}
local eof_namespace = vim.api.nvim_create_namespace("lazyvcs_snapshot_eof")

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

function M.resolve_base_width(session)
	local total = vim.api.nvim_win_get_width(session.editable_win) + vim.api.nvim_win_get_width(session.base_win)
	if session.rail then
		local size = math.max(3, vim.o.winminwidth)
		return session.rail.win == session.base_win and size or total - size
	end
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

	local left_label = (session.left_label or session.base_label):lower()
	local right_label = (session.right_label or session.base_label):lower()
	local left_document = session.base_text or { empty = #session.base_lines == 0 }
	local right_document
	if session.presence and util.buf_is_valid(session.editable_bufnr) then
		right_document = { empty = require("lazyvcs.compare_text").is_empty(session.editable_bufnr) }
	end
	left_label, right_label = require("lazyvcs.diff_labels").labels(
		left_label,
		right_label,
		session.backend == "git" and "INDEX" or "BASE",
		session.presence,
		left_document,
		right_document
	)
	if util.win_is_valid(session.editable_win) and not session.paused then
		session.editable_prev_winbar = session.editable_prev_winbar
			or util.get_win_option(session.editable_win, "winbar")
		local right_role = session.readonly_comparison and "right" or "editable"
		session.editable_label =
			string.format(" lazyvcs %s %s [%s]", session.backend, right_label:lower():gsub("%%", "%%%%"), right_role)
		util.set_win_option(session.editable_win, "winbar", session.editable_label)
	end

	if util.win_is_valid(session.base_win) then
		session.base_prev_winbar = session.base_prev_winbar or util.get_win_option(session.base_win, "winbar")
		session.base_label_winbar =
			string.format(" lazyvcs %s %s [left]", session.backend, left_label:lower():gsub("%%", "%%%%"))
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
	editor.guard_scratch_buffer(buf)
	vim.bo[buf].tabstop = vim.bo[session.editable_bufnr].tabstop
	vim.bo[buf].vartabstop = vim.bo[session.editable_bufnr].vartabstop
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
	"winfixwidth",
	"winfixheight",
	"signcolumn",
	"statuscolumn",
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
	if not util.buf_is_valid(session.editable_bufnr) then
		return
	end
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
---A paused view applies no diff, and another view's windows belong to that view.
function M.release_derived_diff(session)
	if session.paused or not session.tabpage or not vim.api.nvim_tabpage_is_valid(session.tabpage) then
		return
	end
	local state = require("lazyvcs.state")
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tabpage)) do
		local buf = vim.api.nvim_win_get_buf(win)
		local owner = state.for_window(win)
		if
			win ~= session.editable_win
			and win ~= session.base_win
			and not owner
			and buf == session.editable_bufnr
			and session.opts.set_winbar
			and util.get_win_option(win, "winbar") == session.editable_label
		then
			restore_winbar(win, session.editable_prev_winbar)
		end
		if
			win ~= session.editable_win
			and win ~= session.base_win
			and not (owner and owner ~= session)
			and not (session.preexisting_diff_windows or {})[win]
			and (buf == session.editable_bufnr or buf == session.base_bufnr)
			and util.get_win_option(win, "diff")
		then
			util.diff_off(win)
		end
	end
end

function M.release_buffer_diff(session, bufnr)
	if session.paused or not util.win_is_valid(session.editable_win) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	-- Another active view owns this buffer's diff.
	local owner = require("lazyvcs.state").get(bufnr)
	if owner and owner ~= session then
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

local function save_window_owned(win, record)
	return util.win_is_valid(win)
		and vim.api.nvim_win_get_buf(win) == record.buf
		and require("lazyvcs.state").for_window(win) == record.owner
		and (not record.owner or (record.owner.id == record.owner_id and not record.owner.closing))
		and (not record.token or save_owned(record.token))
end

function M.prepare_sessions_save(sessions, transaction)
	transaction.sessions, transaction.windows, transaction.tabs = {}, {}, {}
	local by_buffer, by_window = {}, {}
	for _, session in ipairs(sessions) do
		if session.phase == "active" and not session.readonly_comparison and valid_pair(session) then
			local token = {
				session = session,
				id = session.id,
				win = session.editable_win,
				buf = session.editable_bufnr,
				base_win = session.base_win,
				base_buf = session.base_bufnr,
				windows = {},
				changedtick = vim.api.nvim_buf_get_changedtick(session.editable_bufnr),
			}
			transaction.sessions[#transaction.sessions + 1] = token
			transaction.tabs[session.tabpage] = true
			by_buffer[token.buf] = token
			by_window[token.win], by_window[token.base_win] = token, token
		end
	end
	-- Capture every rollback record before projecting any session.
	for tab in pairs(transaction.tabs) do
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
			local buf = vim.api.nvim_win_get_buf(win)
			local diff = util.get_win_option(win, "diff")
			if by_window[win] or diff then
				local owner = require("lazyvcs.state").for_window(win)
				local record = {
					tab = tab,
					buf = buf,
					owner = owner,
					owner_id = owner and owner.id,
					changedtick = vim.api.nvim_buf_get_changedtick(buf),
					view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
					foldenable = util.get_win_option(win, "foldenable"),
					folds = fold_state.capture(win),
				}
				transaction.windows[win] = record
				local token = by_window[win] or by_buffer[buf]
				if
					token
					and tab == token.session.tabpage
					and (
						win == token.win
						or win == token.base_win
						or (diff and not (token.session.preexisting_diff_windows or {})[win])
					)
				then
					record.token = token
					record.options = capture_window_options(win)
					record.winbar = util.get_win_option(win, "winbar")
					record.fillchars = vim.api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
					record.projected_fillchars = highlighting.user_fillchars(win)
					local user = highlighting.user_winhighlight(win)
					local live = util.get_win_option(win, "winhighlight")
					if user ~= live then
						record.winhighlight, record.projected = live, user
					end
					token.windows[win] = record
				end
			end
		end
	end
	transaction.projecting = true
	for _, token in ipairs(transaction.sessions) do
		token.session.phase = "saving"
	end
	for _, token in ipairs(transaction.sessions) do
		local session = token.session
		for win, record in pairs(token.windows) do
			local base = win == token.base_win
			local original = base and session.base_window_options or session.editable_window_options
			local applied = base and session.base_applied_options or session.editable_applied_options
			local uncollapsed = rail.user_options(session, win, record.options)
			for name, value in pairs(original) do
				-- Reassigning an unchanged foldmethod recomputes non-diff folds.
				if uncollapsed[name] == (applied or {})[name] and util.get_win_option(win, name) ~= value then
					util.set_win_option_noautocmd(win, name, value)
				end
			end
			local label = base and session.base_label_winbar or session.editable_label
			local previous = base and session.base_prev_winbar or session.editable_prev_winbar
			if label and record.winbar == label then
				util.set_win_option_noautocmd(win, "winbar", previous)
			end
			if record.fillchars ~= record.projected_fillchars then
				util.set_win_option_noautocmd(win, "fillchars", record.projected_fillchars)
			end
			if record.winhighlight ~= nil then
				util.set_win_option_noautocmd(win, "winhighlight", record.projected)
			end
		end
	end
end

function M.finish_sessions_save(transaction)
	local resume, errors = {}, {}
	if transaction.finished or transaction.finishing then
		return resume, errors
	end
	transaction.finishing = true
	local function restore(fn, ...)
		local ok, err = pcall(fn, ...)
		if not ok then
			errors[#errors + 1] = tostring(err)
		end
	end
	if transaction.projecting then
		for _, token in ipairs(transaction.sessions) do
			if save_owned(token) then
				for win, record in pairs(token.windows) do
					if save_window_owned(win, record) then
						for name, value in pairs(record.options) do
							-- Reassigning foldmethod recomputes non-diff folds too.
							if name ~= "foldmethod" or util.get_win_option(win, name) ~= value then
								restore(util.set_win_option_noautocmd, win, name, value)
							end
						end
						restore(util.set_win_option_noautocmd, win, "winbar", record.winbar)
						if
							vim.api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
							== record.projected_fillchars
						then
							restore(util.set_win_option_noautocmd, win, "fillchars", record.fillchars)
						end
						restore(function()
							if
								record.winhighlight ~= nil
								and util.get_win_option(win, "winhighlight") == record.projected
							then
								util.set_win_option_noautocmd(win, "winhighlight", record.winhighlight)
							end
						end)
					end
				end
			end
		end
		for tab in pairs(transaction.tabs) do
			if vim.api.nvim_tabpage_is_valid(tab) then
				restore(vim.api.nvim_win_call, vim.api.nvim_tabpage_get_win(tab), function()
					vim.cmd("silent! noautocmd diffupdate")
				end)
			end
		end
		local changed_tabs = {}
		for _, record in pairs(transaction.windows) do
			if
				not util.buf_is_valid(record.buf)
				or vim.api.nvim_buf_get_changedtick(record.buf) ~= record.changedtick
			then
				changed_tabs[record.tab] = true
			end
		end
		for win, record in pairs(transaction.windows) do
			if save_window_owned(win, record) then
				restore(util.set_win_option_noautocmd, win, "foldenable", record.foldenable)
				if
					record.folds
					and vim.api.nvim_buf_get_changedtick(record.buf) == record.changedtick
					and not (record.folds.method == "diff" and changed_tabs[record.tab])
				then
					restore(fold_state.restore, win, record.folds)
				end
			end
		end
		for win, record in pairs(transaction.windows) do
			if save_window_owned(win, record) then
				restore(vim.api.nvim_win_call, win, function()
					vim.fn.winrestview(record.view)
				end)
			end
		end
		for _, token in ipairs(transaction.sessions) do
			local session = token.session
			if session.phase == "saving" then
				session.phase = "active"
				if
					not save_owned(token)
					or session.source_detached
					or vim.api.nvim_buf_get_changedtick(token.buf) ~= token.changedtick
				then
					resume[#resume + 1] = session
				end
			end
		end
	end
	transaction.finished, transaction.finishing = true, false
	return resume, errors
end

function M.bind_pair(session, source_win)
	if not valid_pair(session) or session.phase == "saving" then
		return false
	end
	for _, win in ipairs({ session.editable_win, session.base_win }) do
		apply_diff(win)
		highlighting.apply(
			win,
			session.opts.diff_highlighting,
			win == session.base_win and "old" or "new",
			session.opts.diff_style
		)
		util.set_win_options(win, { scrollbind = true, cursorbind = session.opts.base_window.cursor_sync })
	end
	session.editable_applied_options =
		rail.user_options(session, session.editable_win, capture_window_options(session.editable_win))
	session.base_applied_options =
		rail.user_options(session, session.base_win, capture_window_options(session.base_win))
	vim.schedule(util.safe_callback(function()
		M.rebalance(session)
	end))
	if source_win ~= session.editable_win and source_win ~= session.base_win then
		source_win = session.editable_win
	end
	vim.api.nvim_win_call(source_win, function()
		vim.cmd("silent syncbind")
	end)
	require("lazyvcs.align").apply(session)
	return true
end

-- Loading and unsupported displays need room for their messages.
function M.clear_rail(session)
	local previous = session.rail
	rail.release(session)
	if
		previous
		and same_tab(session.editable_win, session.base_win)
		and vim.api.nvim_win_get_position(session.editable_win)[1] == vim.api.nvim_win_get_position(session.base_win)[1]
		and vim.api.nvim_win_get_height(session.editable_win) == vim.api.nvim_win_get_height(session.base_win)
	then
		pcall(vim.api.nvim_win_set_width, session.base_win, M.resolve_base_width(session))
	end
end

-- Detach native diff before replacing a departed file's base.
function M.present(session, lines, filetype)
	M.clear_rail(session)
	M.reset_tab_diff(session.editable_win)
	M.reset_tab_diff(session.base_win)
	highlighting.release(session.editable_win)
	highlighting.release(session.base_win)
	local buf = session.base_bufnr
	if not util.buf_is_valid(buf) then
		return
	end
	vim.bo[buf].modifiable, vim.bo[buf].readonly = true, false
	local ok, err = pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
	vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].modified = false, true, false
	vim.bo[buf].filetype = filetype or ""
	editor.guard_scratch_buffer(buf)
	if not ok then
		error(err)
	end
end

function M.rebind(old, replacement)
	rail.release(old)
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
	vim.bo[buf].filetype = replacement.paused and "" or vim.bo[replacement.editable_bufnr].filetype
	editor.guard_scratch_buffer(buf)
	vim.bo[buf].tabstop = vim.bo[replacement.editable_bufnr].tabstop
	vim.bo[buf].vartabstop = vim.bo[replacement.editable_bufnr].vartabstop
	for _, name in ipairs({ "wrap", "linebreak", "breakindent" }) do
		util.set_win_option(replacement.base_win, name, util.get_win_option(replacement.editable_win, name))
	end
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
	pcall(vim.api.nvim_win_set_width, session.base_win, M.resolve_base_width(session))
	M.bind_pair(session, editable_win)
	set_window_labels(session)
	-- A read-only deletion opens an empty right snapshot. Place focus on its
	-- present base before the scheduled initial rail installation.
	if
		session.opts.base_window.collapse_absent
		and session.presence
		and session.presence.right == "absent"
		and (session.base_text or session.rail_text)
		and not (session.comparison and session.comparison.property_only)
		and vim.api.nvim_get_current_win() == editable_win
	then
		vim.api.nvim_set_current_win(session.base_win)
	end
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
		rail.release(session)
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
	rail.identity(
		session,
		table.concat({
			session.source_path or session.relpath,
			session.base_label or "",
			vim.inspect(session.base_identity or {}),
		}, "\0")
	)
	local absent
	if
		session.opts.base_window.collapse_absent
		and (session.base_text or session.rail_text)
		and not (session.comparison and (session.comparison.property_only or session.comparison.kind == "git_submodule"))
		and not session.paused
		and not session.capture_error
		and not session.base_invalid
		and not session.rail_expanded
		and session.presence
	then
		if session.presence.left == "absent" then
			absent = "left"
		elseif session.presence.right == "absent" then
			absent = "right"
		end
	end
	local _, _, collapsed = require("lazyvcs.compare_view").pane_sizes(total_width, false, absent, vim.o.winminwidth)
	local candidate = collapsed == "left" and session.base_win or collapsed == "right" and session.editable_win
	-- A current rail is being visited by an internal call or awaits its guarded
	-- focus handler. A newly focused pane must never be collapsed.
	if not session.rail and candidate == vim.api.nvim_get_current_win() then
		candidate = nil
	end
	rail.apply(session, candidate, false)
	local target_base = M.resolve_base_width(session)
	local target_editable = math.max(total_width - target_base, 1)

	if editable_width == target_editable and base_width == target_base then
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
	if session.readonly_comparison then
		for _, side in ipairs({
			{ session.base_bufnr, session.base_text },
			{ session.editable_bufnr, session.current_text },
		}) do
			local buf, document = side[1], side[2]
			if util.buf_is_valid(buf) then
				vim.api.nvim_buf_clear_namespace(buf, eof_namespace, 0, -1)
				if document and not document.empty and not document.eol then
					vim.api.nvim_buf_set_extmark(buf, eof_namespace, math.max(#document.lines - 1, 0), 0, {
						virt_text = { { " [No newline at end of file]", "WarningMsg" } },
						virt_text_pos = "eol",
					})
				end
			end
		end
	end
	vim.schedule(util.safe_callback(function()
		M.rebalance(session)
	end))
	set_window_labels(session)
	if util.win_is_valid(session.editable_win) then
		vim.api.nvim_win_call(session.editable_win, function()
			vim.cmd("silent diffupdate")
		end)
	end
	require("lazyvcs.align").schedule(session)
end

function M.close(session, opts)
	rail.release(session)
	opts = opts or {}
	local base_survived, editable_restored = false, false
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
			editable_restored = true
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

	if opts.reset_tab_diff and not editable_restored then
		M.reset_tab_diff(session.editable_win)
	end
end

function M.rail_focus(session)
	rail.focus(session, function()
		return not valid_pair(session) or session.phase ~= "active"
	end, function()
		M.rebalance(session)
	end)
end

-- These operations can move focus while installing or maintaining a pair.
for _, name in ipairs({
	"open",
	"rebind",
	"present",
	"clear_rail",
	"bind_pair",
	"rebalance",
	"refresh",
	"close",
	"prepare_sessions_save",
	"finish_sessions_save",
}) do
	M[name] = rail.guard(M[name])
end

return M
