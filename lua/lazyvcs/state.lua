local M = {
	sessions = {},
	buffer_index = {},
	pending_transfer = nil,
	repo_jobs = {},
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

function M.list()
	local out = {}
	for _, session in pairs(M.sessions) do
		out[#out + 1] = session
	end
	return out
end

function M.set_pending_transfer(session)
	M.pending_transfer = {
		tabpage = vim.api.nvim_get_current_tabpage(),
		editable_bufnr = session.editable_bufnr,
		base_bufnr = session.base_bufnr,
		editable_win = session.editable_win,
		base_win = session.base_win,
		aerial_transfer_state = session.aerial_transfer_state,
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

function M.set_repo_job(repo_root, job)
	if not repo_root then
		return
	end
	M.repo_jobs[repo_root] = vim.tbl_extend("force", { root = repo_root }, job or {})
end

function M.get_repo_job(repo_root)
	if not repo_root then
		return nil
	end
	return M.repo_jobs[repo_root]
end

function M.clear_repo_job(repo_root)
	if not repo_root then
		return
	end
	M.repo_jobs[repo_root] = nil
end

function M.clear_repo_job_errors(repo_root)
	if repo_root then
		local job = M.repo_jobs[repo_root]
		if job and job.status == "error" then
			M.repo_jobs[repo_root] = nil
		end
		return
	end

	for root, job in pairs(M.repo_jobs) do
		if job.status == "error" then
			M.repo_jobs[root] = nil
		end
	end
end

function M.list_repo_jobs()
	local out = {}
	for _, job in pairs(M.repo_jobs) do
		out[#out + 1] = job
	end
	return out
end

return M
