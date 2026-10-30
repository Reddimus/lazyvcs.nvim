local runtime = require("lazyvcs.process_runtime")
local util = require("lazyvcs.util")

local M = {}
local scopes = setmetatable({}, { __mode = "k" })
local installed = setmetatable({}, { __mode = "k" })
local pending_scope, pending_files

function M.new_scope()
	if runtime.is_shutting_down() then
		return nil
	end
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
		or type(Job._shutdown) ~= "function"
		or type(Job._stop) ~= "function"
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
					local scope, files = pending_scope, pending_files
					pending_scope, pending_files = nil, nil
					if scope and scope.terminal then
						error("cancelled", 0)
					end
					if files then
						files:adopt(opts)
						opts = vim.tbl_extend("force", {}, opts or {}, { dump = { "-D", files:header() } })
					end
					if scope and runtime.is_shutting_down() then
						error("CopilotChat transport is shutting down", 0)
					end
					local result = original(url, opts)
					if scope and type(result) == "table" and type(result.shutdown) == "function" then
						local owned = require("lazyvcs.source_control.copilotchat_job").adopt(result, scope, files)
						files.attached = true
						if scope.terminal then
							owned:stop("cancelled")
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
			-- Keep the handoff synchronous within the leaf and clear it even if
			-- request serialization throws before reaching curl.
			local function leaf(scope, url, opts, callback)
				if scope.terminal then
					return callback(nil, "cancelled")
				end
				local files = require("lazyvcs.source_control.copilotchat_files").new()
				local tmpname, tempname = os.tmpname, vim.fn.tempname
				---@diagnostic disable-next-line: duplicate-set-field
				os.tmpname = function()
					return files:record(tmpname())
				end
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.tempname = function()
					return files:record(tempname())
				end
				pending_scope, pending_files = scope, files
				local ok, err = pcall(original, url, opts, callback)
				pending_scope, pending_files = nil, nil
				os.tmpname, vim.fn.tempname = tmpname, tempname
				if not ok then
					if not files.attached then
						files:release()
					end
					callback(nil, err)
				end
			end
			local invoke = async.wrap(function(scope, url, opts, callback)
				-- Plenary resumes chained requests in a libuv callback. The leaf
				-- allocates temporary files through Vimscript, so enter the main loop first.
				if vim.in_fast_event() then
					vim.schedule(util.safe_callback(function()
						leaf(scope, url, opts, callback)
					end))
				else
					return leaf(scope, url, opts, callback)
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
		for _, owned in pairs(self.jobs) do
			owned:stop("cancelled")
		end
	end
	function scope:close()
		self:cancel()
	end
	return scope
end

return M
