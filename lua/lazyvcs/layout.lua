local util = require("lazyvcs.util")

local M = {}

local function resolve_base_width(width)
	if width <= 1 then
		return math.max(math.floor(vim.o.columns * width), 30)
	end

	return math.max(width, 30)
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

	vim.api.nvim_buf_set_name(buf, string.format("lazyvcs://%s/%s", session.backend, session.relpath))
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
	set_window_labels(session)
end

function M.refresh(session)
	set_window_labels(session)
	if util.win_is_valid(session.editable_win) then
		vim.api.nvim_win_call(session.editable_win, function()
			vim.cmd("silent diffupdate")
		end)
	end
end

function M.close(session)
	if util.win_is_valid(session.editable_win) then
		pcall(vim.api.nvim_win_call, session.editable_win, function()
			if not session.editable_had_diff then
				vim.cmd("silent diffoff")
			end
			if session.opts.set_winbar then
				vim.wo.winbar = session.editable_prev_winbar or ""
			end
		end)
	end

	if util.win_is_valid(session.base_win) then
		pcall(vim.api.nvim_win_call, session.base_win, function()
			if not session.base_had_diff then
				vim.cmd("silent diffoff")
			end
			if session.opts.set_winbar then
				vim.wo.winbar = session.base_prev_winbar or ""
			end
		end)
		pcall(vim.api.nvim_win_close, session.base_win, true)
	end

	if util.buf_is_valid(session.base_bufnr) then
		pcall(vim.api.nvim_buf_delete, session.base_bufnr, { force = true })
	end
end

return M
