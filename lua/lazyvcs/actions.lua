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
local schedule_rebalance
local rebalance_tab

local function notify_open_error(err, opts)
	if not opts.silent then
		util.notify(err, vim.log.levels.ERROR)
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

local function open_session(session)
	editor.guard_markdown_buffer(session.editable_bufnr, session.source_path)
	local editable_aerial_state = aerial.disable_buffer(session.editable_bufnr, { detach = true })
	local ok, err = pcall(layout.open, session)
	aerial.restore_buffer(editable_aerial_state)
	if not ok then
		error(err)
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

		editor.guard_markdown_buffer(target_bufnr, vim.api.nvim_buf_get_name(target_bufnr))
		local replacement = build_session(target_bufnr)
		local live = state.get(pending.editable_bufnr)
		if live then
			close_session(live, {
				keep_pending_transfer = true,
				reset_tab_diff = true,
			})
		end

		if replacement then
			open_session(replacement)
		else
			abort()
		end
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
			handle_pending_transfer(args.buf)
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

	return open_session(session)
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
	local session = current_session_or_warn()
	if not session then
		return
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
	local session = current_session_or_warn()
	if not session then
		return
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

return M
