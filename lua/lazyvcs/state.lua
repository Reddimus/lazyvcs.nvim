local M = {
	sessions = {},
	buffer_index = {},
	pending_transfer = nil,
}

function M.register(session)
	M.sessions[session.editable_bufnr] = session
	M.buffer_index[session.editable_bufnr] = session.editable_bufnr
	M.buffer_index[session.base_bufnr] = session.editable_bufnr
end

function M.unregister(session)
	if not session then
		return
	end

	M.sessions[session.editable_bufnr] = nil
	M.buffer_index[session.editable_bufnr] = nil
	if session.base_bufnr then
		M.buffer_index[session.base_bufnr] = nil
	end
end

function M.get(bufnr)
	if not bufnr then
		return nil
	end

	local editable = M.buffer_index[bufnr] or bufnr
	return M.sessions[editable]
end

function M.current()
	return M.get(vim.api.nvim_get_current_buf())
end

function M.set_pending_transfer(session)
	M.pending_transfer = {
		tabpage = vim.api.nvim_get_current_tabpage(),
		editable_bufnr = session.editable_bufnr,
		base_bufnr = session.base_bufnr,
		editable_win = session.editable_win,
		base_win = session.base_win,
	}
end

function M.peek_pending_transfer()
	return M.pending_transfer
end

function M.take_pending_transfer()
	local pending = M.pending_transfer
	M.pending_transfer = nil
	return pending
end

function M.clear_pending_transfer()
	M.pending_transfer = nil
end

return M
