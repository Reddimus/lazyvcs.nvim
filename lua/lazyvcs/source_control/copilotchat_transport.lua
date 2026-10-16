local M = {}
local scopes = setmetatable({}, { __mode = "k" })
local installed = setmetatable({}, { __mode = "k" })
local pending_scope

local function terminate(job)
	local handle = job.handle
	if job.is_shutdown or not handle or handle:is_closing() then
		return
	end
	local exited = false
	local on_exit = job._user_on_exit
	if on_exit then
		job._user_on_exit = function(self, code, signal)
			exited = true
			-- A signal-only exit has code 0 in libuv. Plenary curl checks only
			-- the code, so route it to on_error instead of parsing missing output.
			if code == 0 and signal and signal ~= 0 then
				code = 128 + signal
			end
			return on_exit(self, code, signal)
		end
	end
	local timer = assert(vim.uv.new_timer())
	local function close_timer()
		if not timer:is_closing() then
			timer:stop()
			timer:close()
		end
	end
	job:add_on_exit_callback(close_timer)
	-- Keep the process handle open so libuv reaps the child before plenary's
	-- spawn exit callback shuts down the Job. Job:shutdown closes it too early.
	pcall(handle.kill, handle, 15)
	timer:start(2000, 0, function()
		close_timer()
		-- Plenary's exit chain can stop early if a callback throws; never signal a reaped pid.
		if not exited and not job.is_shutdown and not handle:is_closing() and handle:is_active() then
			pcall(handle.kill, handle, 9)
		end
	end)
end

function M.new_scope()
	local ok_curl, curl = pcall(require, "plenary.curl")
	local ok_job, Job = pcall(require, "plenary.job")
	local ok_chat, chat_curl = pcall(require, "CopilotChat.utils.curl")
	local ok_async, async = pcall(require, "plenary.async")
	if
		not ok_curl
		or not ok_job
		or not ok_chat
		or not ok_async
		or type(curl) ~= "table"
		or type(Job) ~= "table"
		or type(Job.shutdown) ~= "function"
		or type(Job.add_on_exit_callback) ~= "function"
		or type(Job.new) ~= "function"
		or type(curl.get) ~= "function"
		or type(curl.post) ~= "function"
		or type(chat_curl) ~= "table"
		or type(chat_curl.get) ~= "function"
		or type(chat_curl.post) ~= "function"
		or type(async) ~= "table"
		or type(async.wrap) ~= "function"
	then
		return nil
	end
	if not installed[curl] then
		for _, name in ipairs({ "get", "post", "put", "head", "patch", "delete", "request" }) do
			local original = curl[name]
			if type(original) == "function" then
				curl[name] = function(url, opts)
					local scope = pending_scope
					pending_scope = nil
					local result = original(url, opts)
					if scope and type(result) == "table" and type(result.shutdown) == "function" then
						if scope.terminal then
							-- Let the normal error callback resume CopilotChat, even for late leaves.
							terminate(result)
						else
							scope.jobs[result] = true
						end
					end
					return result
				end
			end
		end
		installed[curl] = true
	end
	if not installed[chat_curl] then
		for _, name in ipairs({ "get", "post" }) do
			local original = chat_curl[name]
			-- Delegate through the public callback form of async.wrap. This keeps
			-- the handoff synchronous and clears it even if the leaf throws before
			-- reaching curl (for example, while serializing a request body).
			local invoke = async.wrap(function(scope, url, opts, callback)
				pending_scope = scope
				local ok, err = pcall(original, url, opts, callback)
				pending_scope = nil
				if not ok then
					callback(nil, err)
				end
			end, 4)
			chat_curl[name] = function(...)
				local scope = scopes[coroutine.running()]
				if not scope then
					return original(...)
				end
				local url, opts, callback = ...
				if callback then
					return invoke(scope, url, opts, callback)
				end
				return invoke(scope, url, opts)
			end
		end
		installed[chat_curl] = true
	end
	local scope = { jobs = {}, terminal = false }
	function scope:run(fn)
		local thread = coroutine.running()
		if not thread then
			return fn()
		end
		local previous = scopes[thread]
		scopes[thread] = self
		local ok, err = pcall(fn)
		scopes[thread] = previous
		if not ok then
			error(err, 0)
		end
	end
	function scope:cancel()
		self.terminal = true
		local jobs = self.jobs
		self.jobs = {}
		for job in pairs(jobs) do
			terminate(job)
		end
	end
	function scope:close()
		self.terminal = true
		self.jobs = {}
	end
	return scope
end

return M
