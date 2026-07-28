local backends = require("lazyvcs.backends")
local compat = require("lazyvcs.compat")
local config = require("lazyvcs.config")
local diff = require("lazyvcs.diff")
local aerial = require("lazyvcs.integrations.aerial")
local editor = require("lazyvcs.integrations.editor")
local layout = require("lazyvcs.layout")
local state = require("lazyvcs.state")
local util = require("lazyvcs.util")

local M = {}
local global_augroup
local refresh
local clear_session_maps
local set_session_maps
local attach_session
local schedule_scroll_sync
local schedule_rebalance
local rebalance_tab
local scroll_event_source
local session_sequence = 0
local target_sequence = 0
local pending_opens = {}

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

-- Build a diff session off the UI thread. Used by `M.open` and by buffer
-- transfers.
--
-- The synchronous path spawns `svn info` + `svn cat` (or `git show`) on the UI
-- thread. Buffer navigation also triggers the signs autocmd, which runs its own
-- VCS commands against the same working copy; when those contend on the SVN
-- working-copy lock the synchronous call blocks until it times out, freezing
-- Neovim for tens of seconds. Everything on the navigation path is async.
local function build_session_async(bufnr, on_done)
	if not util.is_real_file_buffer(bufnr) then
		return on_done(nil, "lazyvcs only opens on normal file buffers")
	end

	local path = util.buf_path(bufnr)
	if not path then
		return on_done(nil, "Current buffer has no file path")
	end

	return backends.load_async(path, function(result, err)
		if not result then
			return on_done(nil, err or "Unable to load VCS base")
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
			base_lines = result.base_lines,
			opts = vim.deepcopy(config.get()),
		})
	end)
end

-- Returns the session on success, or `nil, err` on failure. This must never raise:
-- callers run inside autocmd and `vim.schedule` callbacks, where an uncaught error
-- prints a multi-line traceback and blocks interactive Neovim on the hit-enter
-- prompt (headless only logs it, which is why this hid behind passing spec tests).
local function open_session(session)
	session_sequence = session_sequence + 1
	session.id = session_sequence
	session.editor_state = editor.guard_markdown_buffer(session.editable_bufnr, session.source_path)
	session.editable_aerial_state = aerial.disable_buffer(session.editable_bufnr, { detach = true })
	local registered = false
	local ok, err = xpcall(function()
		layout.open(session)
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
	if session.refresh_job and type(session.refresh_job.kill) == "function" then
		pcall(session.refresh_job.kill, session.refresh_job, 15)
		session.refresh_job = nil
	end
	if not opts.keep_pending_transfer then
		state.clear_pending_transfer(session.editable_win)
	end
	clear_session_maps(session)
	if session.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
	end
	aerial.resume_win(session.editable_win)
	aerial.restore_buffer(session.aerial_transfer_state)
	session.aerial_transfer_state = nil
	state.unregister(session)
	layout.close(session, opts)
	editor.restore_buffer(session.editor_state)
	session.editor_state = nil
	if
		session.owned_editor_win
		and not opts.keep_pending_transfer
		and not opts.keep_editor_win
		and util.win_is_valid(session.editable_win)
	then
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
end

local function resume_transfer_aerial(pending)
	if pending and pending.editable_win then
		aerial.resume_win(pending.editable_win)
	end
	if pending and pending.aerial_transfer_state then
		aerial.restore_buffer(pending.aerial_transfer_state)
	end
end

local function close_failed_transfer_window(pending)
	if not pending or not util.win_is_valid(pending.editable_win) then
		return
	end

	local function cleanup()
		if not vim.api.nvim_tabpage_is_valid(pending.tabpage) or not util.win_is_valid(pending.editable_win) then
			return
		end

		local current_win = vim.api.nvim_get_current_win()
		if pending.base_win ~= pending.editable_win and util.win_is_valid(pending.base_win) then
			pcall(vim.api.nvim_win_close, pending.base_win, true)
		end
		if pending.owned_editor_win and util.win_is_valid(pending.editable_win) then
			pcall(vim.api.nvim_win_close, pending.editable_win, true)
		end
		if util.buf_is_valid(pending.base_bufnr) and #vim.fn.win_findbuf(pending.base_bufnr) == 0 then
			pcall(vim.api.nvim_buf_delete, pending.base_bufnr, { force = true })
		end
		if util.win_is_valid(current_win) and vim.api.nvim_get_current_win() ~= current_win then
			pcall(vim.api.nvim_set_current_win, current_win)
		end
	end

	cleanup()
	vim.schedule(cleanup)
end

local function settle_aborted_transfer(pending)
	resume_transfer_aerial(pending)
	local live = pending and state.get(pending.editable_bufnr) or nil
	if not live then
		return
	end
	if
		util.win_is_valid(pending.editable_win)
		and vim.api.nvim_win_get_buf(pending.editable_win) == pending.editable_bufnr
	then
		pcall(vim.api.nvim_win_call, pending.editable_win, function()
			vim.cmd("silent diffthis")
		end)
		return
	end
	pcall(close_session, live, { reset_tab_diff = true })
	close_failed_transfer_window(pending)
end

local function handle_pending_transfer(target_bufnr)
	local pending = state.peek_pending_transfer()
	if not pending then
		return
	end

	if pending.tabpage ~= vim.api.nvim_get_current_tabpage() then
		state.clear_pending_transfer()
		settle_aborted_transfer(pending)
		return
	end

	if pending.editable_win ~= vim.api.nvim_get_current_win() then
		state.clear_pending_transfer()
		settle_aborted_transfer(pending)
		return
	end

	if target_bufnr == pending.editable_bufnr or target_bufnr == pending.base_bufnr then
		state.clear_pending_transfer()
		settle_aborted_transfer(pending)
		return
	end

	pending = state.take_pending_transfer()
	vim.schedule(function()
		local function pending_is_current()
			return pending and not pending.cancelled and state.peek_pending_transfer(pending.editable_win) == pending
		end

		local function abort()
			if pending and state.peek_pending_transfer(pending.editable_win) == pending then
				state.clear_pending_transfer(pending.editable_win)
			elseif pending and pending.handle and type(pending.handle.kill) == "function" then
				local handle = pending.handle
				pending.handle = nil
				pcall(handle.kill, handle, 15)
			end
			settle_aborted_transfer(pending)
		end

		if not pending_is_current() then
			return
		end

		if not state.get(pending.editable_bufnr) then
			return abort()
		end

		if pending.tabpage ~= vim.api.nvim_get_current_tabpage() then
			return abort()
		end

		if pending.editable_win ~= vim.api.nvim_get_current_win() then
			return abort()
		end

		if vim.api.nvim_get_current_buf() ~= target_bufnr then
			return abort()
		end

		-- Failures below are reported as a notification and always leave the
		-- transfer cleaned up: an uncaught error inside a scheduled callback
		-- blocks interactive Neovim on the hit-enter prompt.
		local function fail_transfer(err)
			close_failed_transfer_window(pending)
			abort()
			if err then
				util.notify(
					"lazyvcs: could not reopen diff after buffer change: " .. one_line(err),
					vim.log.levels.ERROR
				)
			end
		end

		pending.handle = build_session_async(target_bufnr, function(replacement, build_err)
			pending.handle = nil
			if not pending_is_current() then
				return
			end
			-- The user may have navigated again while the backend was loading, so
			-- re-validate before touching any window.
			local tab_ok = vim.api.nvim_tabpage_is_valid(pending.tabpage)
				and pending.tabpage == vim.api.nvim_get_current_tabpage()
			local win_ok = tab_ok and pending.editable_win == vim.api.nvim_get_current_win()

			if not win_ok then
				-- The user moved to another window or tab: the old session is still
				-- coherent where it lives, so leave it alone.
				return abort()
			end

			if vim.api.nvim_get_current_buf() ~= target_bufnr then
				-- Same window, but it now holds a third buffer: the old session can
				-- never be reached again. Tear it down instead of leaving an orphaned
				-- lazyvcs:// window diffed against the wrong file.
				local stale = state.get(pending.editable_bufnr)
				if stale then
					pcall(close_session, stale, { reset_tab_diff = true })
				end
				close_failed_transfer_window(pending)
				return abort()
			end

			local ok, err = pcall(function()
				local live = state.get(pending.editable_bufnr)
				if not live or live.closing or not pending_is_current() then
					return abort()
				end
				close_session(live, {
					keep_pending_transfer = true,
					reset_tab_diff = true,
				})

				if not replacement then
					-- No backend for this buffer is a normal outcome of navigating to a
					-- plain file, so close quietly. A real backend failure (git mid-rebase,
					-- an index.lock, a timed-out `svn cat`) must not be silent, or the user
					-- cannot tell the plugin failed from the file being unsupported.
					local unsupported = not build_err
						or build_err:match("No Git or SVN working copy")
						or build_err:match("not tracked")
						or build_err:match("only opens on normal file buffers")
					return fail_transfer(not unsupported and build_err or nil)
				end

				replacement.owned_editor_win = pending.owned_editor_win
				local _, open_err = open_session(replacement)
				if open_err then
					fail_transfer(open_err)
					return
				end
				state.finish_pending_transfer(pending.editable_win, pending)
			end)

			if not ok then
				fail_transfer(err)
			end
		end)
	end)
end

local function ensure_global_autocmds()
	if global_augroup then
		return
	end

	global_augroup = vim.api.nvim_create_augroup("lazyvcs_global", { clear = true })
	vim.api.nvim_create_autocmd("BufEnter", {
		group = global_augroup,
		callback = function(args)
			-- Errors escaping an autocmd callback block interactive Neovim on the
			-- hit-enter prompt; report them instead so navigation always continues.
			local ok, err = pcall(handle_pending_transfer, args.buf)
			if not ok then
				state.clear_pending_transfer()
				util.notify("lazyvcs: buffer transfer failed: " .. one_line(err), vim.log.levels.ERROR)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
		group = global_augroup,
		callback = function(args)
			local pending = state.peek_pending_transfer()
			if not pending then
				return
			end
			if pending.tabpage ~= vim.api.nvim_get_current_tabpage() then
				return
			end
			if pending.editable_win ~= vim.api.nvim_get_current_win() then
				return
			end
			if args.buf == pending.editable_bufnr or args.buf == pending.base_bufnr then
				return
			end
			editor.guard_markdown_buffer(args.buf, args.match)
		end,
	})
	vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
		group = global_augroup,
		callback = function()
			rebalance_tab(vim.api.nvim_get_current_tabpage())
		end,
	})
end

refresh = function(bufnr)
	local session = state.get(bufnr)
	if not session or session.closing then
		return
	end

	session.hunks = diff.compute_hunks(session.base_lines, util.get_buf_lines(session.editable_bufnr))
	layout.refresh(session)
end

local function schedule_refresh(bufnr)
	local session = state.get(bufnr)
	if not session or session.closing then
		return
	end

	session.refresh_tick = (session.refresh_tick or 0) + 1
	local tick = session.refresh_tick
	vim.defer_fn(function()
		local live = state.get(bufnr)
		if not live or live.closing or live.refresh_tick ~= tick then
			return
		end
		refresh(bufnr)
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
	if not session or session.closing then
		return
	end

	session.rebalance_tick = (session.rebalance_tick or 0) + 1
	local tick = session.rebalance_tick
	vim.defer_fn(function()
		local live = state.get(session.editable_bufnr)
		if not live or live.closing or live.rebalance_tick ~= tick then
			return
		end
		layout.rebalance(live)
	end, 20)
end

schedule_scroll_sync = function(session, source_win)
	if not session or session.closing then
		return
	end

	session.scroll_sync_tick = (session.scroll_sync_tick or 0) + 1
	local tick = session.scroll_sync_tick
	vim.defer_fn(function()
		local live = state.get(session.editable_bufnr)
		if not live or live.closing or live.scroll_sync_tick ~= tick then
			return
		end
		layout.sync_scroll(live, source_win)
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

scroll_event_source = function(session, event)
	if not session then
		return nil
	end

	local windows = (event or {}).windows or event or {}
	local editable_scrolled = has_scroll_delta(windows[tostring(session.editable_win)])
	local base_scrolled = has_scroll_delta(windows[tostring(session.base_win)])

	if base_scrolled and not editable_scrolled then
		return session.base_win
	end
	if editable_scrolled and not base_scrolled then
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
	if not session.readonly_comparison then
		vim.api.nvim_buf_attach(session.editable_bufnr, false, {
			on_lines = function(_, bufnr)
				local live = state.get(bufnr)
				if not live or live ~= session or live.id ~= session.id or live.closing then
					return true
				end
				schedule_refresh(bufnr)
			end,
			on_detach = function(_, bufnr)
				local live = state.get(bufnr)
				if live and live == session and live.id == session.id then
					M.close(bufnr)
				end
			end,
		})
	end

	session.augroup = vim.api.nvim_create_augroup("lazyvcs_" .. session.editable_bufnr, { clear = true })

	vim.api.nvim_create_autocmd("WinScrolled", {
		group = session.augroup,
		callback = function()
			local live = state.get(session.editable_bufnr)
			if not live or live.closing or live.syncing_scroll then
				return
			end

			local source_win = scroll_event_source(live, vim.v.event)
			if source_win then
				schedule_scroll_sync(live, source_win)
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = session.augroup,
		buffer = session.editable_bufnr,
		callback = function()
			if state.get(session.editable_bufnr) then
				M.close(session.editable_bufnr)
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = session.augroup,
		buffer = session.base_bufnr,
		callback = function()
			-- Neovim is already wiping this buffer. Deleting it again from inside its
			-- own BufWipeout raises E937, which aborts the user's :q / :only /
			-- :tabclose -- and the surrounding pcall does not catch an emsg. Mark it
			-- so layout.close skips the delete.
			session.base_wiping = true
			if state.get(session.base_bufnr) then
				M.close(session.base_bufnr)
			end
		end,
	})

	if not session.readonly_comparison then
		vim.api.nvim_create_autocmd("BufLeave", {
			group = session.augroup,
			buffer = session.editable_bufnr,
			callback = function()
				local live = state.get(session.editable_bufnr)
				if not live or live.closing then
					return
				end
				-- Remove the currently displayed buffer from Neovim's diff group
				-- before the window swaps to the transfer target. Otherwise a
				-- pre-diffed buffer can remain registered after it becomes hidden.
				layout.reset_tab_diff(live.editable_win)
				live.aerial_transfer_state = aerial.disable_buffer(live.editable_bufnr, { detach = true })
				aerial.suspend_win(live.editable_win)
				state.set_pending_transfer(live)
			end,
		})
	end

	vim.api.nvim_create_autocmd("WinClosed", {
		group = session.augroup,
		pattern = tostring(session.base_win),
		callback = function()
			vim.schedule(function()
				if state.get(session.editable_bufnr) then
					M.close(session.editable_bufnr)
				end
			end)
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = session.augroup,
		pattern = tostring(session.editable_win),
		callback = function()
			vim.schedule(function()
				if state.get(session.editable_bufnr) then
					M.close(session.editable_bufnr)
				end
			end)
		end,
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

	-- Opening must never block: `<leader>vo` runs on a keystroke, and the
	-- synchronous backend load spawns `svn info` + `svn cat` (or `git show`).
	-- Against a locked working copy those calls block until they time out,
	-- which freezes Neovim. Build the session off the UI thread instead.
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
	local current = vim.api.nvim_get_current_win()
	local current_buf = vim.api.nvim_win_get_buf(current)
	if vim.bo[current_buf].filetype ~= "lazyvcs-source-control" then
		return current, false
	end
	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local bufnr = vim.api.nvim_win_get_buf(winid)
		if winid ~= current and vim.bo[bufnr].filetype ~= "lazyvcs-source-control" then
			return winid, false
		end
	end
	vim.cmd("rightbelow split")
	return vim.api.nvim_get_current_win(), true
end

local function comparison_buffer(comparison, side, editor_win)
	if comparison.editable_side == "right" and side.modifiable and side.path then
		local bufnr = vim.fn.bufadd(side.path)
		vim.fn.bufload(bufnr)
		vim.api.nvim_win_set_buf(editor_win, bufnr)
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
	if comparison.property_only then
		vim.bo[bufnr].filetype = "diff"
	elseif extension ~= "" then
		vim.bo[bufnr].filetype = vim.filetype.match({ filename = comparison.path or comparison.relpath }) or ""
	end
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true
	vim.api.nvim_win_set_buf(editor_win, bufnr)
	return bufnr, true
end

local function cleanup_failed_comparison(context)
	if not context or context.registered then
		return
	end
	local editor_win = context.editor_win
	local editable_bufnr = context.editable_bufnr
	if context.created_editor_win and util.win_is_valid(editor_win) then
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
	local current_session = state.get(vim.api.nvim_win_get_buf(editor_win))
	local inherited_editor_win = current_session and current_session.owned_editor_win or false
	if current_session then
		close_session(current_session, { keep_editor_win = true })
	end
	local original_bufnr = vim.api.nvim_win_get_buf(editor_win)
	failure_context.original_bufnr = original_bufnr
	local editable_bufnr, owned = comparison_buffer(comparison, comparison.right, editor_win)
	failure_context.editable_bufnr = editable_bufnr
	failure_context.owned_editable_buf = owned
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

function M.open_target(comparison)
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
	if not session then
		local transfer = state.peek_pending_transfer()
		if
			transfer
			and transfer.editable_win == vim.api.nvim_get_current_win()
			and vim.api.nvim_win_get_buf(transfer.editable_win) == bufnr
		then
			session = state.get(transfer.editable_bufnr)
			if not session then
				state.clear_pending_transfer(transfer.editable_win)
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
	local session = state.current()
	if not session then
		return require("lazyvcs.signs").revert_hunk()
	end
	if session.readonly_comparison then
		util.notify("This comparison is read-only", vim.log.levels.WARN)
		return false
	end

	refresh(session.editable_bufnr)
	local line = vim.api.nvim_win_get_cursor(session.editable_win)[1]
	local hunk = diff.find_current_hunk(session.hunks or {}, line)
	if not hunk then
		util.notify("No modified hunk at the cursor", vim.log.levels.WARN)
		return
	end

	if not session.backend_impl.revert_hunk(session, hunk) then
		diff.reset_hunk(session.editable_bufnr, session.base_lines, hunk)
	end

	schedule_refresh(session.editable_bufnr)
end

function M.jump_to_hunk(direction)
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

function M.refresh_current()
	local session = state.current()
	if not session or session.closing then
		return
	end
	if session.refresh_job and type(session.refresh_job.kill) == "function" then
		pcall(session.refresh_job.kill, session.refresh_job, 15)
	end
	session.base_generation = (session.base_generation or 0) + 1
	local generation = session.base_generation
	session.refresh_job = backends.load_base_async(session.source_path, function(result, err)
		local live = state.get(session.editable_bufnr)
		if not live or live ~= session or live.closing or live.base_generation ~= generation then
			return
		end
		live.refresh_job = nil
		if not result then
			util.notify(err or "Could not refresh the VCS comparison base", vim.log.levels.WARN)
			return
		end
		live.root = result.root
		live.relpath = result.relpath
		live.base_label = result.base_label
		live.base_lines = result.base_lines
		if util.buf_is_valid(live.base_bufnr) then
			vim.bo[live.base_bufnr].modifiable = true
			vim.bo[live.base_bufnr].readonly = false
			vim.api.nvim_buf_set_lines(live.base_bufnr, 0, -1, false, live.base_lines)
			vim.bo[live.base_bufnr].modifiable = false
			vim.bo[live.base_bufnr].readonly = true
		end
		refresh(live.editable_bufnr)
	end)
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
