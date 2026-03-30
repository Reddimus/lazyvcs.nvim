local M = {
	sessions = {},
	buffer_index = {},
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

return M
