local M = {
	sessions = {},
	views = {},
	buffer_index = {},
	window_index = {},
	pending_transfers = {},
	repo_jobs = {},
}

local function transfer_key(winid)
	assert(type(winid) == "number" and winid ~= 0, "transfer requires an explicit window")
	return tostring(winid)
end

local function cancel_transfer(pending)
	if not pending then
		return
	end
	pending.cancelled = true
	pending.phase = "closed"
	if pending.handle and type(pending.handle.kill) == "function" then
		local handle = pending.handle
		pending.handle = nil
		pcall(handle.kill, handle, 15)
	end
end

local view_sequence = 0

function M.owns(session)
	return session
		and ((session.view_id and M.views[session.view_id] == session) or M.sessions[session.editable_bufnr] == session)
end

-- Views own windows. Only an active view claims its source buffer.
local function registration_error(session, old)
	for _, buf in ipairs(session.paused and { session.base_bufnr } or { session.editable_bufnr, session.base_bufnr }) do
		local owner = M.get(buf)
		if owner and owner ~= old then
			return "Buffer already has a live diff owner"
		end
	end
	for _, win in ipairs({ session.editable_win, session.base_win }) do
		local owner = M.window_index[win]
		if owner and owner ~= old then
			return "Window already has a live diff owner"
		end
	end
end

function M.register(session)
	local err = registration_error(session)
	if err then
		return nil, err
	end
	if not session.view_id then
		view_sequence = view_sequence + 1
		session.view_id = view_sequence
	end
	M.views[session.view_id] = session
	M.window_index[session.editable_win], M.window_index[session.base_win] = session, session
	M.buffer_index[session.base_bufnr] = session
	if not session.paused then
		M.sessions[session.editable_bufnr] = session
		M.buffer_index[session.editable_bufnr] = session
	end
	return session
end

function M.unregister(session)
	if not M.owns(session) then
		return
	end
	if session.view_id and M.views[session.view_id] == session then
		M.views[session.view_id] = nil
	end
	for _, win in ipairs({ session.editable_win, session.base_win }) do
		if M.window_index[win] == session then
			M.window_index[win] = nil
		end
	end
	if M.sessions[session.editable_bufnr] == session then
		M.sessions[session.editable_bufnr] = nil
	end
	for _, buf in ipairs({ session.editable_bufnr, session.base_bufnr }) do
		if M.buffer_index[buf] == session or M.buffer_index[buf] == session.editable_bufnr then
			M.buffer_index[buf] = nil
		end
	end
end

function M.get(bufnr)
	if not bufnr then
		return nil
	end
	local entry = M.buffer_index[bufnr]
	return type(entry) == "table" and entry or M.sessions[entry or bufnr]
end

function M.current()
	local win = vim.api.nvim_get_current_win()
	if vim.w[win].lazyvcs_compare then
		return nil
	end
	local owned = M.for_window(win)
	if owned then
		return owned
	end
	local source = M.get(vim.api.nvim_get_current_buf())
	if source and vim.wo[win].diff and source.tabpage == vim.api.nvim_get_current_tabpage() then
		return source
	end
end

function M.list()
	local out, seen = {}, {}
	for _, collection in ipairs({ M.sessions, M.views }) do
		for _, session in pairs(collection) do
			if not seen[session] then
				out[#out + 1], seen[session] = session, true
			end
		end
	end
	return out
end

function M.for_window(winid)
	return M.window_index[winid]
end

function M.replace(old, replacement)
	assert(M.owns(old), "session lost ownership")
	local err = registration_error(replacement, old)
	assert(not err, err)
	replacement.view_id = old.view_id
	M.unregister(old)
	assert(M.register(replacement))
end

function M.set_pending_transfer(winid, pending)
	local key = transfer_key(winid)
	cancel_transfer(M.pending_transfers[key])
	M.pending_transfers[key] = pending
	return pending
end

function M.peek_pending_transfer(winid)
	return M.pending_transfers[transfer_key(winid)]
end

function M.finish_pending_transfer(winid, pending)
	local key = transfer_key(winid)
	if M.pending_transfers[key] ~= pending then
		return false
	end
	M.pending_transfers[key] = nil
	return true
end

function M.clear_pending_transfer(winid)
	local key = transfer_key(winid)
	local pending = M.pending_transfers[key]
	M.pending_transfers[key] = nil
	cancel_transfer(pending)
	if pending and pending.dispose then
		pending.dispose()
	end
end

function M.clear_all_pending_transfers()
	local windows = {}
	for _, pending in pairs(M.pending_transfers) do
		windows[#windows + 1] = pending.editable_win
	end
	for _, win in ipairs(windows) do
		M.clear_pending_transfer(win)
	end
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
