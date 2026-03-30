local backends = require("lazyvcs.backends")
local config = require("lazyvcs.config")
local diff = require("lazyvcs.diff")
local layout = require("lazyvcs.layout")
local state = require("lazyvcs.state")
local util = require("lazyvcs.util")

local M = {}

local function refresh(bufnr)
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

local function clear_session_maps(session)
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
	}

	for _, item in ipairs(targets) do
		pcall(vim.keymap.del, item[1], item[2], { buffer = item[3] })
	end
end

local function set_session_maps(session)
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
end

local function attach_session(session)
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

function M.open()
	local bufnr = vim.api.nvim_get_current_buf()
	local existing = state.get(bufnr)
	if existing then
		if util.win_is_valid(existing.editable_win) then
			vim.api.nvim_set_current_win(existing.editable_win)
		end
		return existing
	end

	if not util.is_real_file_buffer(bufnr) then
		util.notify("lazyvcs only opens on normal file buffers", vim.log.levels.ERROR)
		return nil
	end

	local path = util.buf_path(bufnr)
	if not path then
		util.notify("Current buffer has no file path", vim.log.levels.ERROR)
		return nil
	end

	local backend_info, err = backends.load(path)
	if not backend_info then
		util.notify(err or "Unable to detect VCS backend", vim.log.levels.ERROR)
		return nil
	end

	local session = {
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

	layout.open(session)
	state.register(session)
	set_session_maps(session)
	attach_session(session)
	refresh(bufnr)
	return session
end

function M.close(target)
	local bufnr = type(target) == "number" and target or vim.api.nvim_get_current_buf()
	local session = state.get(bufnr)
	if not session or session.closing then
		return
	end

	session.closing = true
	clear_session_maps(session)
	if session.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, session.augroup)
	end
	state.unregister(session)
	layout.close(session)
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
	vim.api.nvim_set_current_win(session.editable_win)
	vim.api.nvim_win_set_cursor(session.editable_win, { diff.hunk_anchor(hunk), 0 })
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

return M
