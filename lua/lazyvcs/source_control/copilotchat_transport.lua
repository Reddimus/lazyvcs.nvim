local util = require("lazyvcs.util")
local M = {}
local scopes = setmetatable({}, { __mode = "k" })
local installed = setmetatable({}, { __mode = "k" })
local pending_scope

local function terminate(job)
	if not job.is_shutdown then
		-- Job:shutdown closes handles but does not signal the process.
		if job.handle and not job.handle:is_closing() then
			pcall(job.handle.kill, job.handle, 15)
		end
		util.safe_callback(job.shutdown)(job)
	end
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
