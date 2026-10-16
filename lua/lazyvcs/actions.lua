local backends = require("lazyvcs.backends")
local compare_text = require("lazyvcs.compare_text")
local compat = require("lazyvcs.compat")
local config = require("lazyvcs.config")
local diff = require("lazyvcs.diff")
local aerial = require("lazyvcs.integrations.aerial")
local editor = require("lazyvcs.integrations.editor")
local layout = require("lazyvcs.layout")
local confirm = require("lazyvcs.source_control.confirm")
local state = require("lazyvcs.state")
local util = require("lazyvcs.util")

local M = {}
local global_augroup
local refresh
local reload_session
local clear_session_maps
local set_session_maps
local attach_session
local schedule_scroll_sync
local schedule_rebalance
local rebalance_tab
local scroll_event_source
local session_sequence = 0
local target_sequence = 0
local TEXT_LIMIT = 1024 * 1024
local pending_opens = {}
local source_attachments = {}
local transfer

-- Collapse an error (often a multi-line Lua traceback) into a single short line.
-- Multi-line messages overflow the command area and make interactive Neovim wait
-- on the hit-enter prompt, which turns a recoverable failure into a hang.
local function one_line(err)
	local text = type(err) == "string" and err or vim.inspect(err)
	text = text:gsub("%s*\n%s*", " ")
	return util.truncate(util.trim(text), 200)
end

local function notify_open_error(err, opts)
	if not opts.silent then
		util.notify(one_line(err), vim.log.levels.ERROR)
	end
end

-- Build sessions asynchronously; Git/SVN processes and working-copy locks must not block
-- navigation.
local function build_session_async(bufnr, on_done)
	if not util.is_real_file_buffer(bufnr) then
		return on_done(nil, "lazyvcs only opens on normal file buffers")
	end

	local path = util.buf_path(bufnr)
	if not path then
		return on_done(nil, "Current buffer has no file path")
	end

	local captured, capture_err = compare_text.capture(bufnr, TEXT_LIMIT)
	if not captured then
		return on_done(nil, capture_err)
	end
	local profile, profile_err = compare_text.profile(bufnr)
	if not profile then
		return on_done(nil, profile_err)
	end
	return backends.load_async(
		path,
		util.safe_callback(function(result, err)
			if not result then
				return on_done(nil, err or "Unable to load VCS base")
			end
			local live_profile = compare_text.profile(bufnr)
			if not live_profile or live_profile.key ~= profile.key or util.buf_path(bufnr) ~= path then
				return on_done(nil, "Buffer decoding context changed while loading")
			end
			local current, current_err = compare_text.capture(bufnr, TEXT_LIMIT)
			if not current then
				return on_done(nil, current_err)
			end
			local document, decode_err = diff.decode_base(bufnr, result, TEXT_LIMIT)
			if not document then
				return on_done(nil, decode_err)
			end
			on_done({
				editable_bufnr = bufnr,
				source_path = path,
				backend = result.name,
				backend_impl = result.impl,
				root = result.root,
				relpath = result.relpath,
				tracked = result.tracked,
				base_label = result.base_label,
				base_lines = document.lines,
				base_text = document,
				base_identity = result.base_identity,
				opts = vim.deepcopy(config.get()),
			})
		end)
	)
end

-- Return a session or nil, err. Catch failures so autocmds cannot trigger a hit-enter
-- prompt.
local function open_session(session)
	session_sequence = session_sequence + 1
	session.id = session_sequence
	session.editor_state = session.editor_state
		or editor.guard_markdown_buffer(session.editable_bufnr, session.source_path)
	session.editable_aerial_state = aerial.disable_buffer(session.editable_bufnr, { detach = true })
	local registered = false
	local ok, err = xpcall(function()
		layout.open(session)
		assert(
			util.win_is_valid(session.editable_win)
				and util.win_is_valid(session.base_win)
				and vim.api.nvim_win_get_buf(session.editable_win) == session.editable_bufnr
				and vim.api.nvim_win_get_buf(session.base_win) == session.base_bufnr,
			"Comparison panes changed while opening"
		)
		state.register(session)
		registered = true
		set_session_maps(session)
		attach_session(session)
		aerial.resume_win(session.editable_win)
		refresh(session.editable_bufnr)
	end, debug.traceback)
	aerial.restore_buffer(session.editable_aerial_state)
	session.editable_aerial_state = nil
	if not ok then
		if session.maps_installed then
			pcall(clear_session_maps, session)
		end
		if session.augroup then
			pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
		end
		if registered then
			state.unregister(session)
		end
		pcall(layout.close, session)
		editor.restore_buffer(session.editor_state)
		session.editor_state = nil
		return nil, tostring(err)
	end
	aerial.refetch_buffer(session.editable_bufnr)
	return session
end

local function close_session(session, opts)
	opts = opts or {}
	if not session or session.closing then
		return
	end

	session.closing = true
	session.phase = "closed"
	if session.refresh_job and type(session.refresh_job.kill) == "function" then
		pcall(session.refresh_job.kill, session.refresh_job, 15)
		session.refresh_job = nil
	end
	local cleanup_error
	local function cleanup(fn, ...)
		local ok, err = pcall(fn, ...)
		if not ok then
			cleanup_error = cleanup_error or err
		end
	end
	cleanup(state.clear_pending_transfer, session.editable_win)
	cleanup(clear_session_maps, session)
	if session.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
	end
	state.unregister(session)
	cleanup(layout.close, session, opts)
	cleanup(editor.restore_buffer, session.editor_state)
	session.editor_state = nil
	if session.owned_editor_win and not opts.keep_editor_win and util.win_is_valid(session.editable_win) then
		pcall(vim.api.nvim_win_close, session.editable_win, true)
	end
	if session.owned_editable_buf then
		if
			not session.owned_editor_win
			and util.win_is_valid(session.editable_win)
			and util.buf_is_valid(session.original_bufnr)
			and vim.api.nvim_win_get_buf(session.editable_win) == session.editable_bufnr
		then
			pcall(vim.api.nvim_win_set_buf, session.editable_win, session.original_bufnr)
		end
		if util.buf_is_valid(session.editable_bufnr) then
			pcall(vim.api.nvim_buf_delete, session.editable_bufnr, { force = true })
		end
	end
	if cleanup_error then
		util.notify("lazyvcs: cleanup failed: " .. one_line(cleanup_error), vim.log.levels.ERROR)
	end
end

local function commit_transfer(old, replacement)
	session_sequence = session_sequence + 1
	replacement.id = session_sequence
	replacement.phase = "committing"
	clear_session_maps(old)
	if old.augroup then
		vim.api.nvim_del_augroup_by_id(old.augroup)
		old.augroup = nil
	end
	if old.refresh_job and type(old.refresh_job.kill) == "function" then
		pcall(old.refresh_job.kill, old.refresh_job, 15)
	end
	require("lazyvcs.align").clear(old)
	editor.restore_buffer(old.editor_state)
	old.editor_state = nil
	layout.rebind(old, replacement)
	state.replace(old, replacement)
	old.phase, old.closing = "closed", true
	set_session_maps(replacement)
	attach_session(replacement)
	local current, err = compare_text.capture(replacement.editable_bufnr, TEXT_LIMIT)
	if current then
		replacement.hunks = diff.compute_text_hunks(replacement.base_text, current)
	else
		replacement.hunks = {}
		replacement.capture_error = err
		util.notify(err, vim.log.levels.WARN)
	end
end

transfer = require("lazyvcs.live_transfer").new({
	build = build_session_async,
	close = close_session,
	commit = commit_transfer,
})

local function safe_callback(fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			util.notify("lazyvcs: " .. one_line(err), vim.log.levels.ERROR)
		end
	end
end

local function ensure_global_autocmds()
	if global_augroup then
		return
	end

	global_augroup = vim.api.nvim_create_augroup("lazyvcs_global", { clear = true })
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = global_augroup,
		callback = safe_callback(function(args)
			layout.cleanup_buffer(args.buf, vim.api.nvim_get_current_win())
		end),
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = global_augroup,
		callback = safe_callback(function(args)
			layout.forget_departed(args.buf)
		end),
	})
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "TabEnter" }, {
		group = global_augroup,
		callback = safe_callback(function()
			for _, session in ipairs(state.list()) do
				transfer.schedule(session)
			end
		end),
	})
	vim.api.nvim_create_autocmd("TabEnter", {
		group = global_augroup,
		callback = safe_callback(function()
			rebalance_tab(vim.api.nvim_get_current_tabpage())
		end),
	})
	vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
		group = global_augroup,
		callback = safe_callback(function(args)
			local win = vim.api.nvim_get_current_win()
			local session = state.for_window(win)
			if session and win == session.editable_win then
				transfer.guard(session, args.buf, args.match)
			end
		end),
	})
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = global_augroup,
		callback = safe_callback(function()
			for _, session in ipairs(state.list()) do
				schedule_rebalance(session)
			end
		end),
	})
end

refresh = function(bufnr)
	local session = state.get(bufnr)
	if not session or session.closing or session.phase ~= "active" then
		return
	end

	if not session.readonly_comparison then
		local profile = compare_text.profile(session.editable_bufnr)
		if session.failed_profile_key and profile and session.failed_profile_key == profile.key then
			session.hunks = {}
			return
		end
		if
			session.base_invalid
			or not profile
			or not session.base_text
			or session.base_text.profile_key ~= profile.key
			or util.buf_path(session.editable_bufnr) ~= session.source_path
		then
			session.hunks, session.base_invalid = {}, true
			if not session.refresh_job and (not session.reload_retry_at or vim.uv.now() >= session.reload_retry_at) then
				reload_session(session)
			end
			return
		end
		local current, err = compare_text.capture(session.editable_bufnr, TEXT_LIMIT)
		if not current then
			session.hunks = {}
			if session.capture_error ~= err then
				session.capture_error = err
				util.notify(err, vim.log.levels.WARN)
			end
			return
		end
		session.capture_error = nil
		session.current_text = current
		session.hunks = diff.compute_text_hunks(session.base_text, current)
	else
		session.hunks = diff.compute_hunks(session.base_lines, util.get_buf_lines(session.editable_bufnr))
	end
	layout.refresh(session)
end

function M.resume_session_save(session)
	if state.get(session.editable_bufnr) == session and not session.closing then
		transfer.schedule(session)
		refresh(session.editable_bufnr)
	end
end

local function schedule_refresh(bufnr)
	local session = state.get(bufnr)
	if not session or session.closing or session.phase ~= "active" then
		return
	end

	session.refresh_tick = (session.refresh_tick or 0) + 1
	local tick = session.refresh_tick
	vim.defer_fn(function()
		local live = state.get(bufnr)
		if not live or live ~= session or live.closing or live.phase ~= "active" or live.refresh_tick ~= tick then
			return
		end
		safe_callback(refresh)(bufnr)
	end, session.opts.debounce_ms)
end

local function capture_buffer_map(bufnr, mode, lhs)
	if not lhs or lhs == false or not util.buf_is_valid(bufnr) then
		return nil
	end
	local captured
	pcall(vim.api.nvim_buf_call, bufnr, function()
		local value = vim.fn.maparg(lhs, mode, false, true)
		if type(value) == "table" and value.buffer == 1 then
			captured = vim.deepcopy(value)
		end
	end)
	return captured
end

local function restore_buffer_map(bufnr, mode, lhs, captured)
	if not lhs or lhs == false or not util.buf_is_valid(bufnr) then
		return
	end
	pcall(compat.keymap_del, mode, lhs, { buffer = bufnr })
	if not captured then
		return
	end

	pcall(vim.api.nvim_buf_call, bufnr, function()
		vim.fn.mapset(mode, false, captured)
	end)
end

clear_session_maps = function(session)
	if not session.opts.session_keymaps then
		return
	end

	for _, item in ipairs(session.map_snapshots or {}) do
		restore_buffer_map(item.bufnr, item.mode, item.lhs, item.previous)
	end
	session.map_snapshots = nil
	session.maps_installed = false
end

schedule_rebalance = function(session)
	if not session or session.closing or session.phase ~= "active" then
		return
	end

	session.rebalance_tick = (session.rebalance_tick or 0) + 1
	local tick = session.rebalance_tick
	vim.defer_fn(function()
		local live = state.get(session.editable_bufnr)
		if not live or live ~= session or live.closing or live.phase ~= "active" or live.rebalance_tick ~= tick then
			return
		end
		safe_callback(layout.rebalance)(live)
	end, 20)
end

-- Coalesce scroll gestures, then sync 20 ms after the last event. Earlier syncs feed a
-- moving relative offset back into scrollbind and misalign the panes.
schedule_scroll_sync = function(session, source_win)
	if not session or session.closing or session.phase ~= "active" then
		return
	end

	session.scroll_sync_tick = (session.scroll_sync_tick or 0) + 1
	local tick = session.scroll_sync_tick
	vim.defer_fn(function()
		local live = state.get(session.editable_bufnr)
		if not live or live ~= session or live.closing or live.phase ~= "active" or live.scroll_sync_tick ~= tick then
			return
		end
		safe_callback(layout.sync_scroll)(live, source_win)
	end, 20)
end

local function has_scroll_delta(entry)
	return entry
		and (
			(entry.topline or 0) ~= 0
			or (entry.topfill or 0) ~= 0
			or (entry.leftcol or 0) ~= 0
			or (entry.skipcol or 0) ~= 0
		)
end

-- Choose the authoritative pane from WinScrolled window-ID entries. The optional windows
-- field supports pre-shaped callers.
scroll_event_source = function(session, event)
	if not session then
		return nil
	end

	local windows = (event or {}).windows or event or {}
	local editable_scrolled = has_scroll_delta(windows[tostring(session.editable_win)])
	local base_scrolled = has_scroll_delta(windows[tostring(session.base_win)])

	-- Exactly one pane moved. This is the case Vim deliberately does not handle:
	-- the wheel over a window without cursor focus ignores 'scrollbind'
	-- (:h scrollbind-quickadj), so the moved pane is authoritative.
	if base_scrolled and not editable_scrolled then
		return session.base_win
	end
	if editable_scrolled and not base_scrolled then
		return session.editable_win
	end

	-- Both moved, which is what 'scrollbind' does when the focused pane scrolls.
	if base_scrolled and editable_scrolled then
		-- With wrapped alignment, keep native binding. Extra syncbind applies a drifting
		-- relative offset that padding cannot correct.
		if require("lazyvcs.align").is_active(session) then
			return nil
		end

		-- Without wrapping there is no drift, and following the focused pane
		-- corrects the topfill and sub-line offsets that returning nil here used
		-- to decline silently.
		local current = vim.api.nvim_get_current_win()
		if current == session.editable_win or current == session.base_win then
			return current
		end
		return session.editable_win
	end

	return nil
end

rebalance_tab = function(tabpage)
	for _, session in ipairs(state.list()) do
		if not session.closing and util.win_is_valid(session.editable_win) and util.win_is_valid(session.base_win) then
			local editable_tab = vim.api.nvim_win_get_tabpage(session.editable_win)
			local base_tab = vim.api.nvim_win_get_tabpage(session.base_win)
			if editable_tab == tabpage and base_tab == tabpage then
				schedule_rebalance(session)
			end
		end
	end
end

set_session_maps = function(session)
	if not session.opts.session_keymaps then
		return
	end

	local maps = session.opts.keymaps
	local definitions = {
		{ "n", maps.next_hunk, session.editable_bufnr, M.next_hunk, "lazyvcs next hunk" },
		{ "n", maps.prev_hunk, session.editable_bufnr, M.prev_hunk, "lazyvcs previous hunk" },
		{ "n", maps.close, session.editable_bufnr, M.close, "lazyvcs close diff view" },
		{ "n", maps.close, session.base_bufnr, M.close, "lazyvcs close diff view" },
	}
	if maps.close ~= "<leader>q" then
		definitions[#definitions + 1] = { "n", "<leader>q", session.base_bufnr, M.close, "lazyvcs close diff view" }
	end
	if not session.readonly_comparison then
		table.insert(
			definitions,
			3,
			{ "n", maps.revert_hunk, session.editable_bufnr, M.revert_hunk, "lazyvcs revert current hunk" }
		)
	end
	session.map_snapshots = {}
	for _, item in ipairs(definitions) do
		local mode, lhs, bufnr, rhs, desc = unpack(item)
		if lhs and lhs ~= false then
			session.map_snapshots[#session.map_snapshots + 1] = {
				mode = mode,
				lhs = lhs,
				bufnr = bufnr,
				previous = capture_buffer_map(bufnr, mode, lhs),
			}
			compat.keymap_set(mode, lhs, rhs, { silent = true, buffer = bufnr, desc = desc })
		end
	end
	session.maps_installed = true
end

attach_session = function(session)
	if not session.readonly_comparison and not source_attachments[session.editable_bufnr] then
		source_attachments[session.editable_bufnr] = vim.api.nvim_buf_attach(session.editable_bufnr, false, {
			on_lines = safe_callback(function(_, bufnr)
				local live = state.get(bufnr)
				if live and live.editable_bufnr == bufnr and not live.closing then
					schedule_refresh(bufnr)
				end
			end),
			on_detach = safe_callback(function(_, bufnr)
				source_attachments[bufnr] = nil
				local live = state.get(bufnr)
				if live and live.editable_bufnr == bufnr then
					M.close(bufnr)
				end
			end),
		})
	end

	session.augroup = vim.api.nvim_create_augroup("lazyvcs_" .. session.editable_bufnr, { clear = true })

	vim.api.nvim_create_autocmd("OptionSet", {
		group = session.augroup,
		pattern = { "fileencoding", "fileformat", "bomb", "binary", "endofline", "fixendofline" },
		callback = safe_callback(function()
			if vim.api.nvim_get_current_buf() == session.editable_bufnr then
				schedule_refresh(session.editable_bufnr)
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufFilePost", {
		group = session.augroup,
		buffer = session.editable_bufnr,
		callback = safe_callback(function()
			session.base_invalid, session.hunks = true, {}
			vim.schedule(safe_callback(function()
				M.close(session.editable_bufnr)
			end))
		end),
	})

	vim.api.nvim_create_autocmd("WinScrolled", {
		group = session.augroup,
		callback = safe_callback(function()
			local live = state.get(session.editable_bufnr)
			if not live or live ~= session or live.closing or live.phase ~= "active" or live.syncing_scroll then
				return
			end

			-- WinScrolled is global and one callback is registered per live
			-- session, so bail immediately when neither pane is involved --
			-- otherwise every session pays for every unrelated scroll.
			local event = vim.v.event or {}
			local windows = event.windows or event
			if not (windows[tostring(live.editable_win)] or windows[tostring(live.base_win)]) then
				return
			end

			-- Refresh visible padding after every relevant scroll, even when native binding needs
			-- no correction.
			require("lazyvcs.align").schedule(live)

			local source_win = scroll_event_source(live, event)
			if source_win then
				schedule_scroll_sync(live, source_win)
			end
		end),
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = session.augroup,
		buffer = session.editable_bufnr,
		callback = safe_callback(function()
			if state.get(session.editable_bufnr) then
				M.close(session.editable_bufnr)
			end
		end),
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = session.augroup,
		buffer = session.base_bufnr,
		callback = safe_callback(function()
			-- Deleting a buffer during its BufWipeout raises E937. Mark it so layout.close skips
			-- deletion.
			session.base_wiping = true
			if state.get(session.base_bufnr) then
				M.close(session.base_bufnr)
			end
		end),
	})

	if not session.readonly_comparison then
		vim.api.nvim_create_autocmd("BufWinLeave", {
			group = session.augroup,
			buffer = session.editable_bufnr,
			callback = function()
				transfer.leave(session)
			end,
		})
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		group = session.augroup,
		pattern = tostring(session.base_win),
		callback = safe_callback(function()
			state.clear_pending_transfer(session.editable_win)
			session.phase = "closed"
			vim.schedule(safe_callback(function()
				if state.get(session.editable_bufnr) == session then
					M.close(session.editable_bufnr)
				end
			end))
		end),
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = session.augroup,
		pattern = tostring(session.editable_win),
		callback = safe_callback(function()
			state.clear_pending_transfer(session.editable_win)
			session.phase = "closed"
			vim.schedule(safe_callback(function()
				if state.get(session.editable_bufnr) == session then
					M.close(session.editable_bufnr)
				end
			end))
		end),
	})
end

local function current_session_or_warn()
	local session = state.current()
	if session then
		return session
	end

	util.notify("No active lazyvcs diff session for the current buffer", vim.log.levels.WARN)
	return nil
end

function M.open(opts)
	opts = opts or {}
	ensure_global_autocmds()

	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	local invoking_win = opts.winid or vim.api.nvim_get_current_win()
	local existing = state.get(bufnr)
	if existing then
		if util.win_is_valid(existing.editable_win) then
			vim.api.nvim_set_current_win(existing.editable_win)
		end
		return existing
	end

	local pending = pending_opens[bufnr]
	if pending then
		local active = true
		if type(pending.is_active) == "function" then
			local ok, result = pcall(pending.is_active, pending)
			active = not ok or result
		end
		if active then
			return pending
		end
		pending_opens[bufnr] = nil
	end

	-- Resolve and read the base asynchronously; working-copy locks must not freeze the UI.
	local source_path = util.buf_path(bufnr)
	local request = {}
	local task
	pending_opens[bufnr] = request
	task = build_session_async(bufnr, function(session, err)
		local current = pending_opens[bufnr]
		if current ~= request and current ~= task then
			return
		end
		pending_opens[bufnr] = nil
		if not session then
			notify_open_error(err, opts)
			return
		end
		-- The buffer may have been wiped, renamed, or already opened while the
		-- backend call was in flight.
		if not util.buf_is_valid(bufnr) or util.buf_path(bufnr) ~= source_path or state.get(bufnr) then
			return
		end
		if not util.win_is_valid(invoking_win) or vim.api.nvim_win_get_buf(invoking_win) ~= bufnr then
			return
		end
		local opened, open_err = open_session(session)
		if not opened then
			notify_open_error(open_err, opts)
			return
		end
		if type(opts.on_open) == "function" then
			opts.on_open(opened)
		end
	end)
	if pending_opens[bufnr] == request then
		pending_opens[bufnr] = task
	end
	if task and type(task.on_cancel) == "function" then
		pcall(task.on_cancel, task, function()
			if pending_opens[bufnr] == task then
				pending_opens[bufnr] = nil
			end
		end)
	end
	return task
end

local function target_editor_window()
	local target = require("lazyvcs.editor_target").capture(vim.api.nvim_get_current_win())
	if not target.fallback then
		return target.winid, false
	end
	local current_buf = vim.api.nvim_win_get_buf(target.winid)
	if vim.bo[current_buf].filetype ~= "lazyvcs-source-control" then
		return target.winid, false
	end
	vim.cmd("rightbelow split")
	util.editor_window(vim.api.nvim_get_current_win())
	return vim.api.nvim_get_current_win(), true
end

local function comparison_buffer(comparison, side, editor_win)
	if comparison.editable_side == "right" and side.modifiable and side.path then
		local bufnr = vim.fn.bufadd(side.path)
		vim.fn.bufload(bufnr)
		util.show_win_buffer(editor_win, bufnr)
		return bufnr, false
	end

	target_sequence = target_sequence + 1
	local bufnr = vim.api.nvim_create_buf(false, true)
	local name = string.format(
		"lazyvcs://comparison/%s/%s/%s//right-%d",
		comparison.backend or comparison.vcs or "vcs",
		comparison.kind or "diff",
		(comparison.relpath or "buffer"):gsub("[/\\%c]+", "/"),
		target_sequence
	)
	vim.api.nvim_buf_set_name(bufnr, name)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].buflisted = false
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, side.lines or {})
	local extension = vim.fn.fnamemodify(comparison.path or comparison.relpath or "", ":e")
	if comparison.property_only or comparison.kind == "git_submodule" then
		vim.bo[bufnr].filetype = "diff"
	elseif extension ~= "" then
		vim.bo[bufnr].filetype = vim.filetype.match({ filename = comparison.path or comparison.relpath }) or ""
	end
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true
	util.show_win_buffer(editor_win, bufnr)
	return bufnr, true
end

local function cleanup_failed_comparison(context)
	if not context or context.registered then
		return
	end
	local editor_win = context.editor_win
	local editable_bufnr = context.editable_bufnr
	if
		context.created_editor_win
		and util.win_is_valid(editor_win)
		and vim.api.nvim_win_get_buf(editor_win) == (editable_bufnr or context.original_bufnr)
	then
		pcall(vim.api.nvim_win_close, editor_win, true)
	elseif not editor_win and context.tabpage and vim.api.nvim_tabpage_is_valid(context.tabpage) then
		for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(context.tabpage)) do
			if not context.original_windows[winid] then
				pcall(vim.api.nvim_win_close, winid, true)
			end
		end
	elseif
		context.owned_editable_buf
		and util.win_is_valid(editor_win)
		and vim.api.nvim_win_get_buf(editor_win) == editable_bufnr
		and util.buf_is_valid(context.original_bufnr)
	then
		pcall(vim.api.nvim_win_set_buf, editor_win, context.original_bufnr)
	end
	if context.owned_editable_buf and util.buf_is_valid(editable_bufnr) then
		pcall(vim.api.nvim_buf_delete, editable_bufnr, { force = true })
	end
end

local function open_target_impl(comparison, failure_context)
	if not comparison or not comparison.left or not comparison.right then
		util.notify("Invalid LazyVCS diff target", vim.log.levels.ERROR)
		return nil
	end
	if comparison.property_only and comparison.property_patch then
		comparison = vim.deepcopy(comparison)
		comparison.left = { label = "PROPERTIES", lines = {}, modifiable = false }
		comparison.right = comparison.property_patch
		comparison.editable_side = nil
	end

	local editor_win, created_editor_win = target_editor_window()
	failure_context.editor_win = editor_win
	failure_context.created_editor_win = created_editor_win
	local current_session = state.for_window(editor_win) or state.get(vim.api.nvim_win_get_buf(editor_win))
	local inherited_editor_win = current_session and current_session.owned_editor_win or false
	if current_session then
		close_session(current_session, { keep_editor_win = true })
	end
	local original_bufnr = vim.api.nvim_win_get_buf(editor_win)
	failure_context.original_bufnr = original_bufnr
	local editable_bufnr, owned = comparison_buffer(comparison, comparison.right, editor_win)
	failure_context.editable_bufnr = editable_bufnr
	failure_context.owned_editable_buf = owned
	assert(
		util.win_is_valid(editor_win) and vim.api.nvim_win_get_buf(editor_win) == editable_bufnr,
		"Editor destination changed while opening"
	)
	local existing = state.get(editable_bufnr)
	if existing then
		close_session(existing)
	end
	local backend_impl = comparison.path and backends.resolve_cached(comparison.path) or nil
	if not backend_impl then
		local ok, implementation = pcall(require, "lazyvcs.backends." .. (comparison.backend or comparison.vcs or ""))
		backend_impl = ok and implementation or nil
	end
	local session = {
		editable_bufnr = editable_bufnr,
		editable_win = editor_win,
		source_path = comparison.path,
		backend = comparison.backend or comparison.vcs,
		backend_impl = backend_impl,
		root = comparison.root,
		relpath = comparison.relpath,
		tracked = comparison.kind ~= "git_untracked" and comparison.kind ~= "svn_untracked",
		base_label = comparison.left.label,
		left_label = comparison.left.label,
		right_label = comparison.right.label,
		base_lines = comparison.left.lines or {},
		opts = vim.deepcopy(config.get()),
		readonly_comparison = not (comparison.editable_side == "right" and comparison.right.modifiable),
		owned_editable_buf = owned,
		owned_editor_win = created_editor_win or inherited_editor_win,
		original_bufnr = owned and original_bufnr or nil,
		comparison = comparison,
	}
	if not session.readonly_comparison then
		local document, decode_err = diff.decode_base(editable_bufnr, {
			base_bytes = comparison.left.bytes
				or (comparison.left.source and comparison.left.source.kind == "empty" and "" or nil),
			base_lines = comparison.left.lines,
			base_encoding = comparison.left.base_encoding,
		}, TEXT_LIMIT)
		if not document then
			error(decode_err)
		end
		session.base_text, session.base_lines, session.base_identity =
			document, document.lines, comparison.base_identity
		comparison.left.bytes = nil
	end
	vim.api.nvim_set_current_win(editor_win)
	local opened, err = open_session(session)
	if not opened then
		cleanup_failed_comparison(failure_context)
		util.notify("Could not open comparison: " .. one_line(err), vim.log.levels.ERROR)
		return nil
	end
	failure_context.registered = true
	return opened
end

function M.open_target(comparison, opts)
	local previous_win = vim.api.nvim_get_current_win()
	if opts then
		if not require("lazyvcs.editor_target").valid(opts) then
			return nil
		end
		vim.api.nvim_set_current_win(opts.winid)
	end
	ensure_global_autocmds()
	local failure_context = {
		tabpage = vim.api.nvim_get_current_tabpage(),
		original_windows = {},
	}
	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(failure_context.tabpage)) do
		failure_context.original_windows[winid] = true
	end
	local ok, result = xpcall(function()
		return open_target_impl(comparison, failure_context)
	end, debug.traceback)
	if opts and opts.preserve_focus and util.win_is_valid(previous_win) then
		vim.api.nvim_set_current_win(previous_win)
	end
	if not ok then
		cleanup_failed_comparison(failure_context)
		util.notify("Could not open comparison: " .. one_line(result), vim.log.levels.ERROR)
		return nil
	end
	return result
end

function M.close(target)
	local bufnr = type(target) == "number" and target or vim.api.nvim_get_current_buf()
	-- Cancel an open that is still resolving, so closing before the backend
	-- returns does not leave a session that appears moments later.
	local pending = pending_opens[bufnr]
	if pending and type(pending.kill) == "function" then
		pcall(pending.kill, pending, 15)
		pending_opens[bufnr] = nil
	end
	local session = state.get(bufnr)
	if not session and target == nil then
		session = state.for_window(vim.api.nvim_get_current_win())
	end
	if not session then
		for _, pending_transfer in pairs(state.pending_transfers) do
			if
				util.win_is_valid(pending_transfer.editable_win)
				and vim.api.nvim_win_get_buf(pending_transfer.editable_win) == bufnr
			then
				session = state.for_window(pending_transfer.editable_win)
				break
			end
		end
	end
	close_session(session)
end

function M.toggle()
	local session = state.current()
	if session then
		return M.close(session.editable_bufnr)
	end
	local current_bufnr = vim.api.nvim_get_current_buf()
	if pending_opens[current_bufnr] then
		return M.close(current_bufnr)
	end
	return M.open()
end

function M.revert_hunk()
	if require("lazyvcs.compare_navigation").owns(require("lazyvcs.compare").current()) then
		util.notify("This comparison is read-only", vim.log.levels.WARN)
		return false
	end
	local session = state.current()
	if not session then
		return require("lazyvcs.signs").revert_hunk()
	end
	if session.readonly_comparison then
		util.notify("This comparison is read-only", vim.log.levels.WARN)
		return false
	end

	local function can_mutate()
		return state.get(session.editable_bufnr) == session
			and not session.closing
			and session.phase == "active"
			and util.win_is_valid(session.editable_win)
			and vim.api.nvim_win_get_buf(session.editable_win) == session.editable_bufnr
	end
	if not can_mutate() then
		util.notify("Wait for the live diff transfer to finish before reverting a hunk", vim.log.levels.WARN)
		return false
	end

	refresh(session.editable_bufnr)
	local line = vim.api.nvim_win_get_cursor(session.editable_win)[1]
	local hunk = diff.find_current_hunk(session.hunks or {}, line)
	if not hunk then
		util.notify("No modified hunk at the cursor", vim.log.levels.WARN)
		return
	end
	local context = util.capture_buffer_context(session.editable_win)
	if not context or context.bufnr ~= session.editable_bufnr then
		return false
	end
	local confirmed_base = vim.deepcopy(session.base_text)
	local confirmed_hunk = vim.deepcopy(hunk)
	local function context_is_unchanged()
		if not can_mutate() or context.bufnr ~= session.editable_bufnr then
			return false
		end
		if not util.buffer_context_is_unchanged(context) then
			util.notify("Hunk context changed while confirmation was open; nothing was reverted", vim.log.levels.WARN)
			return false
		end
		refresh(session.editable_bufnr)
		if session.base_invalid then
			return false
		end
		local current_hunk = diff.find_current_hunk(session.hunks or {}, context.cursor[1])
		if
			not vim.deep_equal(session.base_text, confirmed_base) or not vim.deep_equal(current_hunk, confirmed_hunk)
		then
			util.notify("Hunk base changed while confirmation was open; nothing was reverted", vim.log.levels.WARN)
			return false
		end
		return true
	end

	return confirm.mutation({ prompt = "Revert hunk under cursor?", before_confirm = context_is_unchanged }, function()
		if not context_is_unchanged() then
			return false
		end
		local function reset()
			if not context_is_unchanged() then
				return false
			end
			return vim.api.nvim_win_call(session.editable_win, function()
				if not session.backend_impl.revert_hunk(session, confirmed_hunk) then
					diff.reset_text_hunk(session.editable_bufnr, confirmed_base, session.current_text, confirmed_hunk)
				end

				schedule_refresh(session.editable_bufnr)
				return true
			end)
		end
		if not session.base_identity then
			return reset()
		end
		return backends.validate_editable_base_async(
			context.path,
			session.base_identity,
			util.safe_callback(function(valid, err)
				if state.get(session.editable_bufnr) ~= session or session.closing then
					return
				end
				if not valid then
					session.hunks = {}
					session.base_invalid = true
					reload_session(session)
					return util.notify(err or "Hunk base is no longer editable", vim.log.levels.WARN)
				end
				reset()
			end)
		)
	end)
end

function M.jump_to_hunk(direction)
	if require("lazyvcs.compare").jump_to_hunk(direction) then
		return
	end
	local session = state.current()
	if not session then
		return require("lazyvcs.signs").jump_to_hunk(direction)
	end

	refresh(session.editable_bufnr)
	local hunks = session.hunks or {}
	if #hunks == 0 then
		util.notify("No hunks in the current buffer", vim.log.levels.INFO)
		return
	end

	local line = vim.api.nvim_win_get_cursor(session.editable_win)[1]
	local hunk = diff.find_neighbor_hunk(hunks, line, direction)
	diff.focus_hunk(session.editable_win, session.editable_bufnr, hunk)
end

function M.next_hunk()
	M.jump_to_hunk("next")
end

function M.prev_hunk()
	M.jump_to_hunk("prev")
end

reload_session = function(session)
	if not session or session.closing or session.phase ~= "active" then
		return
	end
	if session.refresh_job and type(session.refresh_job.kill) == "function" then
		pcall(session.refresh_job.kill, session.refresh_job, 15)
	end
	session.base_generation = (session.base_generation or 0) + 1
	local generation = session.base_generation
	local profile = compare_text.profile(session.editable_bufnr)
	local source_path = util.buf_path(session.editable_bufnr)
	local function loaded_impl(result, err)
		local live = state.get(session.editable_bufnr)
		if not live or live ~= session or live.closing or live.base_generation ~= generation then
			return
		end
		live.refresh_job = nil
		local current_profile = compare_text.profile(live.editable_bufnr)
		if
			not current_profile
			or not profile
			or current_profile.key ~= profile.key
			or util.buf_path(live.editable_bufnr) ~= source_path
		then
			return
		end
		if not result then
			live.hunks, live.base_invalid = {}, true
			local message = err or "Could not refresh the VCS comparison base"
			live.reload_retry_at = vim.uv.now() + 3000
			if live.reload_error ~= message then
				live.reload_error = message
				util.notify(message, vim.log.levels.WARN)
			end
			return
		end
		live.reload_error, live.reload_retry_at = nil, nil
		if live.comparison then
			live.comparison = result
			result.base_label = result.left.label
			result.base_lines = result.left.lines or {}
			result.base_encoding = result.left.base_encoding
			result.base_bytes = result.left.bytes
				or (result.left.source and result.left.source.kind == "empty" and "" or nil)
			if live.readonly_comparison and util.buf_is_valid(live.editable_bufnr) then
				vim.bo[live.editable_bufnr].modifiable = true
				vim.bo[live.editable_bufnr].readonly = false
				vim.api.nvim_buf_set_lines(live.editable_bufnr, 0, -1, false, result.right.lines or {})
				vim.bo[live.editable_bufnr].modifiable = false
				vim.bo[live.editable_bufnr].readonly = true
			end
		end
		if not live.comparison then
			local backend = backends.resolve_cached(live.source_path)
			if backend then
				live.backend, live.backend_impl = backend.name, backend
			end
		end
		live.root = result.root
		live.relpath = result.relpath
		live.base_label = result.base_label
		if not live.readonly_comparison then
			local document, decode_err = diff.decode_base(live.editable_bufnr, result, TEXT_LIMIT)
			if not document then
				live.hunks, live.base_invalid = {}, true
				live.failed_profile_key = profile.key
				util.notify(decode_err, vim.log.levels.WARN)
				return
			end
			live.base_text, live.base_lines = document, document.lines
			if live.comparison then
				live.comparison.left.bytes = nil
			end
			live.base_invalid = false
			live.failed_profile_key = nil
		else
			live.base_lines = result.base_lines
		end
		live.base_identity = result.base_identity
		if util.buf_is_valid(live.base_bufnr) then
			vim.bo[live.base_bufnr].modifiable = true
			vim.bo[live.base_bufnr].readonly = false
			vim.api.nvim_buf_set_lines(live.base_bufnr, 0, -1, false, live.base_lines)
			if live.base_text then
				vim.bo[live.base_bufnr].endofline = live.base_text.eol
				vim.bo[live.base_bufnr].fixendofline = false
			end
			vim.bo[live.base_bufnr].modifiable = false
			vim.bo[live.base_bufnr].readonly = true
		end
		refresh(live.editable_bufnr)
	end
	local loaded = safe_callback(loaded_impl)
	if session.comparison then
		session.refresh_job = backends.load_diff_target_async(session.comparison, loaded)
	else
		session.refresh_job = backends.load_base_async(session.source_path, loaded)
	end
end

function M.refresh_current()
	local session = state.current()
	if session and not session.comparison then
		backends.invalidate(session.source_path)
	end
	return reload_session(session)
end

function M.rebalance(target)
	local bufnr = type(target) == "number" and target or vim.api.nvim_get_current_buf()
	local session = state.get(bufnr)
	if session then
		return layout.rebalance(session)
	end
	return false
end

function M.rebalance_tab(tabpage)
	rebalance_tab(tabpage or vim.api.nvim_get_current_tabpage())
end

M._test_scroll_event_source = scroll_event_source

return M
