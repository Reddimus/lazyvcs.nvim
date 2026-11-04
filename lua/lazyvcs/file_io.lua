-- Exact file identities for patch reads and private request-file cleanup.
-- Default SVN discovery continues using libuv directly.
local uv = vim.uv
local M = {}
local windows = vim.fn.has("win32") == 1
local worker = require("lazyvcs.windows_file_worker")
local runtime = require("lazyvcs.process_runtime")
local pending, running, open_count = {}, 0, 0
-- Keep physical workers rooted until their completion callback, including cancellation.
local live, _active = {}, {}
local pump
local closing, tracked = runtime.is_shutting_down(), false
local lifetime = {}

function M.identity(entry)
	if not entry then
		return false
	end
	if entry.identity == "windows-file-id-128" then
		return type(entry.dev) == "string"
			and entry.dev:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
			and type(entry.ino) == "string"
			and #entry.ino == 32
			and entry.ino:match("^%x+$") ~= nil
			and entry.ino ~= string.rep("0", 32)
	end
	return entry.identity == nil
		and type(entry.dev) == "number"
		and entry.dev >= 0
		and type(entry.ino) == "number"
		and entry.ino > 0
end

function M.same(entry, expected)
	return M.identity(entry)
		and M.identity(expected)
		and entry.type == expected.type
		and entry.identity == expected.identity
		and entry.directory_reparse == expected.directory_reparse
		and entry.dev == expected.dev
		and entry.ino == expected.ino
end

local function release()
	if tracked and running == 0 and #pending == 0 and open_count == 0 then
		tracked = false
		runtime.untrack(lifetime)
	end
end

local function later_error(callback, err)
	vim.schedule(require("lazyvcs.util").safe_callback(function()
		callback(err)
	end))
end

local function deliver(handle, callback, err, value)
	if closing then
		if handle and live[handle] and not handle.pending then
			M.fs_close(handle, function() end)
		end
		return
	end
	local ok, failure = pcall(callback, err, value)
	if not ok then
		local function report()
			require("lazyvcs.util").notify(
				"File I/O callback: " .. tostring(failure):gsub("%s+", " "),
				vim.log.levels.ERROR
			)
		end
		if handle and live[handle] and not handle.pending then
			M.fs_close(handle, report)
		else
			report()
		end
	end
end

local function queue(operation, args, callback)
	if #pending >= 128 and operation ~= "close" then
		return later_error(callback, "Native file I/O queue is full")
	end
	local request = { operation = operation, args = args, callback = callback }
	if not tracked then
		tracked = true
		runtime.track(lifetime)
	end
	if operation == "close" then
		table.insert(pending, 1, request)
	else
		pending[#pending + 1] = request
	end
	pump()
end

pump = function()
	while running < 2 and #pending > 0 do
		local request = table.remove(pending, 1)
		_active[request] = true
		running = running + 1
		local function completed(raw)
			running = running - 1
			request.work = nil
			_active[request] = nil
			local decoded, result = pcall(vim.mpack.decode, raw or "")
			local err = (not decoded or type(result) ~= "table") and "Invalid File worker response"
				or not result.ok and tostring(result.value)
				or nil
			require("lazyvcs.util").safe_callback(request.callback)(err, not err and result.value or nil)
			pump()
			release()
		end
		local ok, err = pcall(function()
			request.work = assert(uv.new_work(worker, vim.schedule_wrap(completed)))
			assert(request.work:queue(request.operation, vim.mpack.encode(request.args)))
		end)
		if not ok then
			vim.schedule(function()
				completed(vim.mpack.encode({ ok = false, value = tostring(err) }))
			end)
		end
	end
	release()
end

function M.fs_lstat(path, callback)
	if windows and not callback then
		local result = vim.mpack.decode(worker("lstat", vim.mpack.encode({ path = path })))
		if not result.ok then
			return nil, tostring(result.value)
		end
		return result.value
	end
	if not windows then
		return uv.fs_lstat(path, callback)
	end
	if not closing then
		queue("lstat", { path = path }, function(err, entry)
			if not closing then
				callback(err, entry)
			end
		end)
	end
end

function M.fs_open(path, flags, mode, callback)
	if not windows then
		return uv.fs_open(path, flags, mode, callback)
	end
	if closing then
		return
	end
	if open_count >= 128 then
		return later_error(function(err)
			if not closing then
				callback(err)
			end
		end, "Too many owned file HANDLEs")
	end
	open_count = open_count + 1
	queue("open", { path = path }, function(err, token)
		if err then
			open_count = open_count - 1
			if not closing then
				callback(err)
			end
			release()
			return
		end
		local handle = { token = token, pending = false, closed = false }
		live[handle] = true
		deliver(handle, callback, nil, handle)
	end)
end

local function operation(name, handle, args, callback)
	if closing and name ~= "close" then
		if live[handle] and not handle.pending then
			M.fs_close(handle, function() end)
		end
		return
	end
	if not live[handle] or handle.closed or handle.pending then
		return later_error(function(err)
			if not closing then
				callback(err)
			end
		end, "Invalid or busy owned file HANDLE")
	end
	handle.pending = true
	args.token = handle.token
	queue(name, args, function(err, result)
		handle.pending = false
		if name == "close" and not err then
			handle.closed, live[handle] = true, nil
			open_count = open_count - 1
		end
		deliver(name ~= "close" and handle or nil, callback, err, result)
	end)
end

function M.fs_fstat(handle, callback)
	if not windows then
		return uv.fs_fstat(handle, callback)
	end
	if not callback then
		error("Native file fstat requires a callback")
	end
	operation("fstat", handle, {}, callback)
end

function M.fs_read(handle, size, offset, callback)
	if not windows then
		return uv.fs_read(handle, size, offset, callback)
	end
	operation("read", handle, { size = size, offset = offset }, callback)
end

function M.fs_close(handle, callback)
	if not windows then
		return uv.fs_close(handle, callback)
	end
	operation("close", handle, {}, callback)
end

local function shutdown()
	if closing then
		return
	end
	closing = true
	local queued = pending
	pending = {}
	for _, request in ipairs(queued) do
		if request.operation == "close" then
			pending[#pending + 1] = request
		else
			require("lazyvcs.util").safe_callback(request.callback)("Cancelled: editor shutdown")
		end
	end
	for handle in pairs(live) do
		if not handle.pending then
			M.fs_close(handle, function() end)
		end
	end
	pump()
end

if windows then
	-- Filesystem workers cannot be interrupted safely. Keep them physically owned
	-- through the shared shutdown deadline; pending completions only close HANDLEs.
	lifetime.shutdown = shutdown
	lifetime.force = function() end
	lifetime.close_timers = function() end
	runtime.before_shutdown(shutdown)
end

return M
