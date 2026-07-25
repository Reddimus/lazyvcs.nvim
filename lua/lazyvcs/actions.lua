local backends = require("lazyvcs.backends")
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

local function build_session(bufnr)
	if not util.is_real_file_buffer(bufnr) then
		return nil, "lazyvcs only opens on normal file buffers"
	end

	local path = util.buf_path(bufnr)
	if not path then
		return nil, "Current buffer has no file path"
	end

	local backend_info, err = backends.load(path)
	if not backend_info then
		return nil, err or "Unable to detect VCS backend"
	end

	return {
		editable_bufnr = bufnr,
		source_path = path,
		backend = backend_info.name,
		backend_impl = backend_info.impl,
		root = backend_info.root,
		relpath = backend_info.relpath,
		tracked = backend_info.tracked,
		base_label = backend_info.base_label,
		base_lines = backend_info.base_lines,
		opts = vim.deepcopy(config.get()),
	}
end

-- Asynchronous counterpart of build_session, used by buffer transfers.
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

	-- Backend resolution is cached per directory, so this is a table lookup for
	-- any buffer in an already-visited directory.
	local backend, _, resolve_err = backends.resolve(path)
	if not backend then
		return on_done(nil, resolve_err or "Unable to detect VCS backend")
	end

	backend.load_base_async(path, function(result, err)
		if not result then
			return on_done(nil, err or "Unable to load VCS base")
		end
		on_done({
			editable_bufnr = bufnr,
			source_path = path,
			backend = backend.name,
			backend_impl = backend,
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
	editor.guard_markdown_buffer(session.editable_bufnr, session.source_path)
	local editable_aerial_state = aerial.disable_buffer(session.editable_bufnr, { detach = true })
	local ok, err = pcall(layout.open, session)
	aerial.restore_buffer(editable_aerial_state)
	if not ok then
		-- layout.open may have already created the base buffer/window; tear the
		-- half-built session down so no orphaned `lazyvcs://` window survives.
		pcall(layout.close, session, { reset_tab_diff = not session.editable_had_diff })
		return nil, tostring(err)
	end
	state.register(session)
	set_session_maps(session)
	attach_session(session)
	aerial.resume_win(session.editable_win)
	aerial.refetch_buffer(session.editable_bufnr)
	refresh(session.editable_bufnr)
	return session
end

local function close_session(session, opts)
	opts = opts or {}
	if not session or session.closing then
		return
	end

	session.closing = true
	if not opts.keep_pending_transfer then
		state.clear_pending_transfer()
	end
	clear_session_maps(session)
	if session.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
	end
	aerial.resume_win(session.editable_win)
	aerial.restore_buffer(session.aerial_transfer_state)
	session.aerial_transfer_state = nil
	state.unregister(session)
	layout.close(session, {
		reset_tab_diff = opts.reset_tab_diff,
	})
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
		for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(pending.tabpage)) do
			if winid ~= pending.editable_win and util.win_is_valid(winid) then
				local bufnr = vim.api.nvim_win_get_buf(winid)
				local name = vim.api.nvim_buf_get_name(bufnr)
				if winid == pending.base_win or name:match("^lazyvcs://") then
					pcall(vim.api.nvim_win_close, winid, true)
				end
			end
		end
		if util.win_is_valid(current_win) and vim.api.nvim_get_current_win() ~= current_win then
			pcall(vim.api.nvim_set_current_win, current_win)
		end
	end

	cleanup()
	vim.schedule(cleanup)
end

local function handle_pending_transfer(target_bufnr)
	local pending = state.peek_pending_transfer()
	if not pending then
		return
	end

	if pending.tabpage ~= vim.api.nvim_get_current_tabpage() then
		resume_transfer_aerial(pending)
		state.clear_pending_transfer()
		return
	end

	if pending.editable_win ~= vim.api.nvim_get_current_win() then
		resume_transfer_aerial(pending)
		state.clear_pending_transfer()
		return
	end

	if target_bufnr == pending.editable_bufnr or target_bufnr == pending.base_bufnr then
		resume_transfer_aerial(pending)
		state.clear_pending_transfer()
		return
	end

	pending = state.take_pending_transfer()
	vim.schedule(function()
		local function abort()
			resume_transfer_aerial(pending)
		end

		if not pending then
			return
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

		local guard_ok, guard_err =
			pcall(editor.guard_markdown_buffer, target_bufnr, vim.api.nvim_buf_get_name(target_bufnr))
		if not guard_ok then
			return fail_transfer(guard_err)
		end

		build_session_async(target_bufnr, function(replacement, build_err)
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
				if live then
					close_session(live, {
						keep_pending_transfer = true,
						reset_tab_diff = true,
					})
				end

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

				local _, open_err = open_session(replacement)
				if open_err then
					fail_transfer(open_err)
				end
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

clear_session_maps = function(session)
	if not session.opts.session_keymaps then
		return
	end

	local maps = session.opts.keymaps
	local targets = {
		{ "n", maps.next_hunk, session.editable_bufnr },
		{ "n", maps.prev_hunk, session.editable_bufnr },
		{ "n", maps.revert_hunk, session.editable_bufnr },
		{ "n", maps.close, session.editable_bufnr },
		{ "n", maps.close, session.base_bufnr },
		{ "n", "<leader>q", session.base_bufnr },
	}

	for _, item in ipairs(targets) do
		pcall(vim.keymap.del, item[1], item[2], { buffer = item[3] })
	end
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
	local opts = { silent = true, buffer = session.editable_bufnr }

	vim.keymap.set("n", maps.next_hunk, M.next_hunk, vim.tbl_extend("force", opts, { desc = "lazyvcs next hunk" }))
	vim.keymap.set("n", maps.prev_hunk, M.prev_hunk, vim.tbl_extend("force", opts, { desc = "lazyvcs previous hunk" }))
	vim.keymap.set(
		"n",
		maps.revert_hunk,
		M.revert_hunk,
		vim.tbl_extend("force", opts, { desc = "lazyvcs revert current hunk" })
	)
	vim.keymap.set("n", maps.close, M.close, vim.tbl_extend("force", opts, { desc = "lazyvcs close diff view" }))
	vim.keymap.set(
		"n",
		maps.close,
		M.close,
		{ silent = true, buffer = session.base_bufnr, desc = "lazyvcs close diff view" }
	)
	vim.keymap.set(
		"n",
		"<leader>q",
		M.close,
		{ silent = true, buffer = session.base_bufnr, desc = "lazyvcs close diff view" }
	)
end

attach_session = function(session)
	vim.api.nvim_buf_attach(session.editable_bufnr, false, {
		on_lines = function(_, bufnr)
			schedule_refresh(bufnr)
		end,
		on_detach = function(_, bufnr)
			local live = state.get(bufnr)
			if live then
				M.close(bufnr)
			end
		end,
	})

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
			if state.get(session.base_bufnr) then
				M.close(session.base_bufnr)
			end
		end,
	})

	vim.api.nvim_create_autocmd("BufLeave", {
		group = session.augroup,
		buffer = session.editable_bufnr,
		callback = function()
			local live = state.get(session.editable_bufnr)
			if not live or live.closing then
				return
			end
			live.aerial_transfer_state = aerial.disable_buffer(live.editable_bufnr, { detach = true })
			aerial.suspend_win(live.editable_win)
			state.set_pending_transfer(live)
		end,
	})

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
	local existing = state.get(bufnr)
	if existing then
		if util.win_is_valid(existing.editable_win) then
			vim.api.nvim_set_current_win(existing.editable_win)
		end
		return existing
	end

	local session, err = build_session(bufnr)
	if not session then
		notify_open_error(err, opts)
		return nil
	end

	local opened, open_err = open_session(session)
	if not opened then
		notify_open_error(open_err, opts)
		return nil
	end

	return opened
end

function M.close(target)
	local bufnr = type(target) == "number" and target or vim.api.nvim_get_current_buf()
	local session = state.get(bufnr)
	close_session(session)
end

function M.toggle()
	local session = state.current()
	if session then
		return M.close(session.editable_bufnr)
	end
	return M.open()
end

function M.revert_hunk()
	local session = state.current()
	if not session then
		return require("lazyvcs.signs").revert_hunk()
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
	if session then
		refresh(session.editable_bufnr)
	end
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
