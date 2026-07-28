local config = require("lazyvcs.config")
local util = require("lazyvcs.util")

local M = {}

local DEFAULT_OUTPUT_LIMIT_BYTES = 1024 * 1024
local DEFAULT_KILL_GRACE_MS = 1000
local MAX_HISTORY_ARG_COUNT = 64
local MAX_HISTORY_ARG_BYTES = 512
local MAX_HISTORY_ERROR_BYTES = 4096
local MAX_GENERATION_KEYS = 4096

local queues = {
	git = {},
	svn = {},
}
local active = {
	git = 0,
	svn = 0,
}
local pumping = {
	git = false,
	svn = false,
}
local running = {}
local history = {}
local object_generations = setmetatable({}, { __mode = "k" })
local scalar_generations = {}
local scalar_generation_order = {}
local next_id = 0
local next_seq = 0
local pump

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
	return math.min(10000, math.max(1, background_config().history_limit or 100))
end

local function close_timer(timer)
	if not timer then
		return
	end
	local ok, closing = pcall(timer.is_closing, timer)
	if ok and not closing then
		pcall(timer.stop, timer)
		pcall(timer.close, timer)
	end
end

local function bounded_text(value, limit)
	value = type(value) == "string" and value or ""
	if #value <= limit then
		return value
	end
	local suffix = string.format("\n... [truncated %d bytes]", #value - limit)
	local keep = math.max(0, limit - #suffix)
	return value:sub(1, keep) .. suffix
end

local function bounded_result(result, limit)
	if type(result) ~= "table" then
		return result
	end
	limit = math.max(256, math.floor(limit or DEFAULT_OUTPUT_LIMIT_BYTES))
	local stdout_limit = math.floor(limit / 2)
	local stderr_limit = limit - stdout_limit
	return {
		code = result.code,
		signal = result.signal,
		stdout = bounded_text(result.stdout, stdout_limit),
		stderr = bounded_text(result.stderr, stderr_limit),
		cancelled = result.cancelled,
		timed_out = result.timed_out,
		reason = result.reason,
	}
end

local function stream_collector(limit)
	local per_stream = math.max(128, math.floor(limit / 2))
	local streams = {
		stdout = { chunks = {}, bytes = 0, omitted = 0 },
		stderr = { chunks = {}, bytes = 0, omitted = 0 },
	}
	local function capture(name, err, data)
		local stream = streams[name]
		if err and not data then
			data = tostring(err)
		end
		if type(data) ~= "string" or data == "" then
			return
		end
		local remaining = math.max(0, per_stream - stream.bytes)
		if remaining > 0 then
			local chunk = data:sub(1, remaining)
			stream.chunks[#stream.chunks + 1] = chunk
			stream.bytes = stream.bytes + #chunk
		end
		stream.omitted = stream.omitted + math.max(0, #data - remaining)
	end
	local function value(name, fallback)
		local stream = streams[name]
		if #stream.chunks == 0 and stream.omitted == 0 then
			return fallback or ""
		end
		local text = table.concat(stream.chunks)
		if stream.omitted > 0 then
			text =
				bounded_text(text .. string.format("\n... [truncated at least %d bytes]", stream.omitted), per_stream)
		end
		return text
	end
	return {
		stdout = function(err, data)
			capture("stdout", err, data)
		end,
		stderr = function(err, data)
			capture("stderr", err, data)
		end,
		merge = function(result)
			if type(result) ~= "table" then
				return result
			end
			return {
				code = result.code,
				signal = result.signal,
				stdout = value("stdout", result.stdout),
				stderr = value("stderr", result.stderr),
				cancelled = result.cancelled,
				timed_out = result.timed_out,
				reason = result.reason,
			}
		end,
	}
end

local function bounded_args(args)
	local result = {}
	for index = 1, math.min(#(args or {}), MAX_HISTORY_ARG_COUNT) do
		result[index] = bounded_text(tostring(args[index]), MAX_HISTORY_ARG_BYTES)
	end
	if #(args or {}) > MAX_HISTORY_ARG_COUNT then
		result[#result + 1] = string.format("... [%d arguments omitted]", #args - MAX_HISTORY_ARG_COUNT)
	end
	return result
end

local function record(job, status, err)
	local ended_at = vim.uv.hrtime()
	local item = {
		id = job.id,
		root = job.root,
		owner = bounded_text(
			job.owner_id
				or (type(job.owner) == "string" and job.owner)
				or string.format("<%s:%s>", type(job.owner), tostring(job.owner)),
			256
		),
		scope = job.scope,
		generation = job.generation,
		priority = job.priority,
		vcs = job.vcs,
		kind = job.kind,
		args = bounded_args(job.args),
		status = status,
		error = err and bounded_text(tostring(err), MAX_HISTORY_ERROR_BYTES) or nil,
		started_at = job.started_at,
		ended_at = ended_at,
		duration_ms = job.started_at and math.floor((ended_at - job.started_at) / 1e6) or 0,
	}
	history[#history + 1] = item
	while #history > history_limit() do
		table.remove(history, 1)
	end
end

local function notify_callback_error(err)
	vim.schedule(function()
		util.notify("Source-control job callback failed: " .. tostring(err), vim.log.levels.ERROR)
	end)
end

local function invoke_done(job, result, err, raw)
	if type(job.on_done) ~= "function" then
		return
	end
	local ok, callback_err = pcall(job.on_done, result, err, raw)
	if not ok then
		notify_callback_error(callback_err)
	end
end

local function release_worker(job)
	if not job.started or job.worker_released then
		return
	end
	job.worker_released = true
	running[job.id] = nil
	active[job.vcs] = math.max(0, active[job.vcs] - 1)
end

local function finish(job, status, result, err, raw)
	if job.finalized then
		return false
	end
	job.finalized = true
	job.queued = false
	close_timer(job.timeout_timer)
	job.timeout_timer = nil
	if (status == "cancelled" or status == "timeout") and job.started and not job.process_exited then
		job.forced_result = {
			status = status,
			result = result,
			err = err,
			raw = raw,
		}
	end
	if not job.started or job.process_exited then
		release_worker(job)
	end

	local bounded_raw = bounded_result(raw or result, job.output_limit_bytes)
	local bounded = result and bounded_result(result, job.output_limit_bytes) or nil
	record(job, status, err)
	invoke_done(job, bounded, err, bounded_raw)
	pump(job.vcs)
	return true
end

local function signal_process(job, signal)
	if not job.handle then
		return false
	end
	local ok = pcall(job.handle.kill, job.handle, signal)
	return ok
end

local function terminate(job)
	if job.process_exited or job.termination_started or not job.handle then
		return
	end
	job.termination_started = true
	signal_process(job, 15)
	job.kill_timer = vim.defer_fn(function()
		job.kill_timer = nil
		if not job.process_exited then
			signal_process(job, 9)
		end
	end, job.kill_grace_ms)
end

local function on_process_exit(job, result, err, raw)
	job.process_exited = true
	close_timer(job.kill_timer)
	job.kill_timer = nil
	if job.finalized then
		release_worker(job)
		pump(job.vcs)
		return
	end

	result = job.collector and job.collector.merge(result) or result
	raw = job.collector and job.collector.merge(raw or result) or (raw or result)
	if err and util.trim(tostring(err)) == "" then
		err = nil
	end
	if not err and raw and raw.code and raw.code ~= 0 then
		err = util.system_error(raw)
	end
	if err then
		return finish(job, "error", nil, tostring(err), raw)
	end
	return finish(job, "ok", result, nil, raw)
end

local function start_job(job)
	job.queued = false
	job.started = true
	job.started_at = vim.uv.hrtime()
	running[job.id] = job
	active[job.vcs] = active[job.vcs] + 1

	if job.timeout_ms > 0 then
		job.timeout_timer = vim.defer_fn(function()
			job.timeout_timer = nil
			if job.finalized then
				return
			end
			local err = string.format("Timed out after %dms: %s", job.timeout_ms, table.concat(job.args, " "))
			local raw = {
				code = 124,
				stdout = "",
				stderr = err,
				timed_out = true,
				reason = "timeout",
			}
			terminate(job)
			finish(job, "timeout", nil, err, raw)
		end, job.timeout_ms)
	end

	local starter = job.start or util.system_start
	job.collector = stream_collector(job.output_limit_bytes)
	local ok, handle = pcall(starter, job.args, {
		cwd = job.cwd,
		stdout = job.collector.stdout,
		stderr = job.collector.stderr,
	}, function(result, err, raw)
		on_process_exit(job, result, err, raw)
	end)
	if not ok then
		job.process_exited = true
		return finish(job, "error", nil, tostring(handle), {
			code = 127,
			stdout = "",
			stderr = tostring(handle),
		})
	end
	job.handle = handle
	if job.termination_requested and not job.process_exited then
		terminate(job)
	end
end

pump = function(vcs)
	if pumping[vcs] then
		return
	end
	pumping[vcs] = true
	while active[vcs] < worker_limit(vcs) and #queues[vcs] > 0 do
		local job = table.remove(queues[vcs], 1)
		if not job.finalized then
			start_job(job)
		end
	end
	pumping[vcs] = false
end

local function object_owner(owner)
	local owner_type = type(owner)
	return owner_type == "table" or owner_type == "function" or owner_type == "thread" or owner_type == "userdata"
end

local function scalar_generation_key(owner, scope)
	return type(owner) .. "\0" .. tostring(owner) .. "\0" .. tostring(scope or "")
end

local function latest_generation(owner, scope)
	if object_owner(owner) then
		local generations = object_generations[owner]
		return generations and generations[scope or ""] or nil
	end
	return scalar_generations[scalar_generation_key(owner, scope)]
end

local function set_latest_generation(owner, scope, generation)
	if object_owner(owner) then
		local generations = object_generations[owner]
		if not generations then
			generations = {}
			object_generations[owner] = generations
		end
		generations[scope or ""] = generation
		return
	end

	local key = scalar_generation_key(owner, scope)
	if scalar_generations[key] == nil then
		scalar_generation_order[#scalar_generation_order + 1] = key
	end
	scalar_generations[key] = generation
	while #scalar_generation_order > MAX_GENERATION_KEYS do
		local expired = table.remove(scalar_generation_order, 1)
		scalar_generations[expired] = nil
	end
end

local function insert_job(queue, job)
	for index, queued in ipairs(queue) do
		if job.priority > queued.priority then
			table.insert(queue, index, job)
			return
		end
	end
	queue[#queue + 1] = job
end

local function normalize_root(root)
	if not root or root == "" then
		return root
	end
	return vim.fs.normalize(root)
end

local function finite_option(name, value, default)
	value = value == nil and default or value
	if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
		error("lazyvcs source-control job " .. name .. " must be a finite number")
	end
	return value
end

function M.command(repo, kind, args, opts, on_done)
	opts = opts or {}
	if type(repo) ~= "table" or type(repo.root) ~= "string" or repo.root == "" then
		error("lazyvcs source-control jobs require a repository root")
	end
	if type(args) ~= "table" or #args == 0 then
		error("lazyvcs source-control jobs require a non-empty argument list")
	end
	if on_done ~= nil and type(on_done) ~= "function" then
		error("lazyvcs source-control job callback must be a function")
	end
	next_id = next_id + 1
	next_seq = next_seq + 1
	local vcs = repo.vcs == "svn" and "svn" or "git"
	local root = normalize_root(repo.root)
	local owner = opts.owner or root
	local scope = opts.scope or kind or "command"
	local timeout_ms = math.max(0, math.floor(finite_option("timeout_ms", opts.timeout_ms, 0)))
	local kill_grace_ms =
		math.max(0, math.floor(finite_option("kill_grace_ms", opts.kill_grace_ms, DEFAULT_KILL_GRACE_MS)))
	local output_limit_bytes = math.max(
		256,
		math.floor(finite_option("output_limit_bytes", opts.output_limit_bytes, DEFAULT_OUTPUT_LIMIT_BYTES))
	)
	local priority = finite_option("priority", opts.priority, 0)
	if opts.generation ~= nil then
		finite_option("generation", opts.generation)
	end
	local job = {
		id = next_id,
		seq = next_seq,
		root = root,
		owner = owner,
		owner_id = opts.owner_id,
		vcs = vcs,
		kind = kind or "command",
		args = vim.deepcopy(args),
		cwd = opts.cwd or root,
		timeout_ms = timeout_ms,
		kill_grace_ms = kill_grace_ms,
		output_limit_bytes = output_limit_bytes,
		priority = priority,
		scope = scope,
		on_done = on_done,
		generation = opts.generation,
		start = opts.start,
		queued = true,
	}

	if job.generation ~= nil then
		local latest = latest_generation(owner, scope)
		if latest ~= nil and job.generation < latest then
			local reason = string.format("Cancelled stale generation %s (latest is %s)", job.generation, latest)
			finish(job, "cancelled", nil, reason, {
				code = 130,
				stdout = "",
				stderr = reason,
				cancelled = true,
				reason = "stale",
			})
			return job.id
		end
		if latest == nil or job.generation > latest then
			set_latest_generation(owner, scope, job.generation)
			M.cancel(function(candidate)
				return candidate.owner == owner
					and candidate.scope == scope
					and candidate.generation ~= nil
					and candidate.generation < job.generation
			end, "superseded")
		end
	end

	insert_job(queues[vcs], job)
	pump(vcs)
	return job.id
end

function M.cancel(filter, reason)
	filter = filter or function()
		return true
	end
	reason = reason or "cancelled"
	local selected = {}

	for vcs, queue in pairs(queues) do
		local kept = {}
		for _, job in ipairs(queue) do
			local ok, matches = pcall(filter, job)
			if ok and matches and not job.finalized then
				selected[#selected + 1] = job
			else
				kept[#kept + 1] = job
			end
		end
		queues[vcs] = kept
	end
	for _, job in pairs(running) do
		local ok, matches = pcall(filter, job)
		if ok and matches and not job.finalized then
			selected[#selected + 1] = job
		end
	end

	for _, job in ipairs(selected) do
		if type(job.generation) == "number" then
			local latest = latest_generation(job.owner, job.scope)
			set_latest_generation(job.owner, job.scope, math.max(latest or job.generation, job.generation + 1))
		end
		job.termination_requested = true
		if job.started then
			terminate(job)
		end
		local message = reason == "cancelled" and "Cancelled" or ("Cancelled: " .. reason)
		finish(job, "cancelled", nil, message, {
			code = 130,
			stdout = "",
			stderr = message,
			cancelled = true,
			reason = reason,
		})
	end
	return #selected
end

function M.cancel_repo(root, opts)
	opts = opts or {}
	root = normalize_root(root)
	return M.cancel(function(job)
		if root and job.root ~= root then
			return false
		end
		if opts.scope and job.scope ~= opts.scope then
			return false
		end
		return true
	end, opts.reason)
end

function M.cancel_owner(owner, opts)
	opts = opts or {}
	return M.cancel(function(job)
		if job.owner ~= owner then
			return false
		end
		if opts.scope and job.scope ~= opts.scope then
			return false
		end
		return true
	end, opts.reason)
end

function M.history()
	return vim.deepcopy(history)
end

function M.clear_history()
	history = {}
end

return M
