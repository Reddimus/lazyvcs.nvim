local util = require("lazyvcs.util")
local aerial = require("lazyvcs.integrations.aerial")
local editor = require("lazyvcs.integrations.editor")

local M = {}

local function sanitize_buffer_segment(text)
	return (vim.fs.normalize(text or ""):gsub("\n", " "):gsub("\r", " "))
end

local function base_buffer_name(session)
	local root = sanitize_buffer_segment(session.root)
	local relpath = sanitize_buffer_segment(session.relpath)
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
		vim.wo[session.editable_win].winbar =
			string.format(" lazyvcs %s %s [editable]", session.backend, session.base_label:lower())
	end

	if util.win_is_valid(session.base_win) then
		session.base_prev_winbar = session.base_prev_winbar or vim.wo[session.base_win].winbar
		vim.wo[session.base_win].winbar =
			string.format(" lazyvcs %s %s [base]", session.backend, session.base_label:lower())
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

function M.reset_tab_diff(winid)
	local target = winid
	if not util.win_is_valid(target) then
		target = vim.api.nvim_get_current_win()
	end

	if util.win_is_valid(target) then
		vim.api.nvim_win_call(target, function()
			vim.cmd("silent diffoff!")
		end)
	end
end

function M.open(session)
	local editable_win = vim.fn.bufwinid(session.editable_bufnr)
	if editable_win == -1 then
		vim.cmd.buffer(session.editable_bufnr)
		editable_win = vim.api.nvim_get_current_win()
	end

	session.editable_win = editable_win
	session.editable_had_diff = vim.wo[editable_win].diff

	configure_base_buffer(session)
	vim.api.nvim_set_current_win(editable_win)

	vim.cmd("rightbelow vsplit")
	session.base_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(session.base_win, session.base_bufnr)
	session.base_had_diff = false

	vim.cmd.wincmd("p")

	vim.wo[session.base_win].number = vim.wo[editable_win].number
	vim.wo[session.base_win].relativenumber = false
	vim.wo[session.base_win].wrap = false
	vim.wo[session.base_win].cursorline = false
	vim.wo[session.base_win].winfixwidth = true

	local width = resolve_base_width(session.opts.base_window.width)
	pcall(vim.api.nvim_win_set_width, session.base_win, width)

	apply_diff(editable_win)
	apply_diff(session.base_win)
	session.tabpage = vim.api.nvim_win_get_tabpage(editable_win)
	set_window_labels(session)
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
	return ok
end

function M.refresh(session)
	set_window_labels(session)
	if util.win_is_valid(session.editable_win) then
		vim.api.nvim_win_call(session.editable_win, function()
			vim.cmd("silent diffupdate")
		end)
	end
end

function M.close(session, opts)
	opts = opts or {}

	if opts.reset_tab_diff then
		M.reset_tab_diff(session.editable_win)
	end

	if util.win_is_valid(session.editable_win) then
		if not opts.reset_tab_diff then
			pcall(vim.api.nvim_win_call, session.editable_win, function()
				if not session.editable_had_diff then
					vim.cmd("silent diffoff")
				end
			end)
		end
		if session.opts.set_winbar then
			restore_winbar(session.editable_win, session.editable_prev_winbar)
		end
	end

	if util.win_is_valid(session.base_win) then
		if not opts.reset_tab_diff then
			pcall(vim.api.nvim_win_call, session.base_win, function()
				if not session.base_had_diff then
					vim.cmd("silent diffoff")
				end
			end)
		end
		if session.opts.set_winbar then
			restore_winbar(session.base_win, session.base_prev_winbar)
		end
		pcall(vim.api.nvim_win_close, session.base_win, true)
	end

	if util.buf_is_valid(session.base_bufnr) then
		aerial.restore_buffer(session.aerial_base_state)
		pcall(vim.api.nvim_buf_delete, session.base_bufnr, { force = true })
	end
end

return M
