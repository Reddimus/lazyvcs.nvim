local config = require("lazyvcs.config")
local util = require("lazyvcs.util")

local M = {}

local queues = {
	git = {},
	svn = {},
}
local active = {
	git = 0,
	svn = 0,
}
local running = {}
local history = {}
local next_id = 0
local next_seq = 0

local function background_config()
	return config.get().source_control.background or {}
end

local function worker_limit(vcs)
	local bg = background_config()
	if vcs == "svn" then
		return math.max(1, bg.svn_workers or 1)
	end
	return math.max(1, bg.git_workers or 4)
end

local function history_limit()
	return math.max(1, background_config().history_limit or 100)
end

local function record(job, status, err)
	local item = {
		id = job.id,
		root = job.root,
		vcs = job.vcs,
		kind = job.kind,
		args = job.args,
		status = status,
		error = err,
		started_at = job.started_at,
		ended_at = vim.uv.hrtime(),
		duration_ms = job.started_at and math.floor((vim.uv.hrtime() - job.started_at) / 1e6) or 0,
	}
	history[#history + 1] = item
	while #history > history_limit() do
		table.remove(history, 1)
	end
end

local function dequeue(vcs)
	local limit = worker_limit(vcs)
	while active[vcs] < limit and #queues[vcs] > 0 do
		local job = table.remove(queues[vcs], 1)
		active[vcs] = active[vcs] + 1
		job.started_at = vim.uv.hrtime()
		running[job.id] = job

		local timeout
		if job.timeout_ms and job.timeout_ms > 0 then
			timeout = vim.defer_fn(function()
				if job.done then
					return
				end
				job.timed_out = true
				job.done = true
				if job.handle then
					pcall(job.handle.kill, job.handle, 15)
				end
			end, job.timeout_ms)
		end

		local function finish(result)
			if timeout and not timeout:is_closing() then
				timeout:stop()
				timeout:close()
			end
			running[job.id] = nil
			active[vcs] = math.max(0, active[vcs] - 1)

			if job.cancelled then
				record(job, "cancelled")
				dequeue(vcs)
				return
			end

			if job.timed_out then
				local err = string.format("Timed out after %dms: %s", job.timeout_ms, table.concat(job.args, " "))
				record(job, "timeout", err)
				vim.schedule(function()
					job.on_done(nil, err, result)
				end)
				dequeue(vcs)
				return
			end

			local err
			if result.code ~= 0 then
				err = util.system_error(result)
			end
			record(job, err and "error" or "ok", err)
			vim.schedule(function()
				job.on_done(err and nil or result, err, result)
			end)
			dequeue(vcs)
		end

		local ok, handle = pcall(vim.system, job.args, { cwd = job.cwd, text = true }, finish)
		if not ok then
			running[job.id] = nil
			active[vcs] = math.max(0, active[vcs] - 1)
			record(job, "error", tostring(handle))
			vim.schedule(function()
				job.on_done(nil, tostring(handle))
			end)
			dequeue(vcs)
		else
			job.handle = handle
		end
	end
end

function M.command(repo, kind, args, opts, on_done)
	opts = opts or {}
	next_id = next_id + 1
	next_seq = next_seq + 1
	local vcs = repo.vcs == "svn" and "svn" or "git"
	local job = {
		id = next_id,
		seq = next_seq,
		root = repo.root,
		vcs = vcs,
		kind = kind or "command",
		args = args,
		cwd = opts.cwd or repo.root,
		timeout_ms = opts.timeout_ms or 0,
		priority = opts.priority or 0,
		scope = opts.scope,
		on_done = on_done,
		generation = opts.generation,
	}
	local queue = queues[vcs]
	local inserted = false
	for idx, queued in ipairs(queue) do
		if job.priority > (queued.priority or 0) then
			table.insert(queue, idx, job)
			inserted = true
			break
		end
	end
	if not inserted then
		queue[#queue + 1] = job
	end
	dequeue(vcs)
	return job.id
end

function M.cancel(filter)
	filter = filter or function()
		return true
	end
	for vcs, queue in pairs(queues) do
		local kept = {}
		for _, job in ipairs(queue) do
			if filter(job) then
				job.cancelled = true
				record(job, "cancelled")
			else
				kept[#kept + 1] = job
			end
		end
		queues[vcs] = kept
	end
	for _, job in pairs(running) do
		if filter(job) then
			job.cancelled = true
			if job.handle then
				pcall(job.handle.kill, job.handle, 15)
			end
		end
	end
end

function M.history()
	return vim.deepcopy(history)
end

function M.clear_history()
	history = {}
end

return M
