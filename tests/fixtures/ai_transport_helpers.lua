-- Self-authored models of the callback/yield and Job contracts used by the bridge.
local M = {}

function M.async()
	local async = {}
	function async.wrap(leaf, argc)
		return function(...)
			if select("#", ...) == argc then
				return leaf(...)
			end
			return coroutine.yield(leaf, argc, ...)
		end
	end
	function async.run(fn)
		local thread = coroutine.create(fn)
		local function resume(...)
			local values = { coroutine.resume(thread, ...) }
			assert(values[1], values[2])
			if coroutine.status(thread) ~= "dead" then
				local args = {}
				for index = 1, values[3] - 1 do
					args[index] = values[index + 3]
				end
				args[values[3]] = resume
				-- Invoke immediately after yield, outside the coroutine that owns it.
				assert(coroutine.running() ~= thread)
				values[2](unpack(args, 1, values[3]))
			end
		end
		resume()
	end
	return async
end

function M.transport(dir, child, async)
	local jobs, curl, chat_curl, Job = {}, {}, {}, {}
	function Job:new(url, opts)
		assert(url == "offline://fixture" and opts.headers.Authorization == "fixture", "curl arguments changed")
		if opts.fail_request then
			error("fixture request failure")
		end
		local path = dir .. "/job-" .. (#jobs + 1)
		local job = setmetatable({}, { __index = self })
		local function finish(code)
			if job.is_shutdown then
				return
			end
			job.is_shutdown = true
			if not job.handle:is_closing() then
				job.handle:close()
			end
			vim.schedule(function()
				if code == 0 then
					if opts.stream then
						opts.stream(nil, "Generated subject")
					end
					opts.callback({ status = 200, body = "Generated subject" })
				elseif opts.on_error then
					opts.on_error({ stderr = "cancelled" })
				end
			end)
		end
		function job:shutdown()
			-- Deliberately only close the handle: callers must signal the child first.
			finish(143)
		end
		job.handle, job.pid = assert(vim.uv.spawn(vim.v.progpath, {
			args = { "--headless", "-u", "NONE", "-i", "NONE", "-l", child, path },
		}, finish))
		jobs[#jobs + 1] = { job = job, path = path }
		return job
	end
	function Job:shutdown() end
	for _, name in ipairs({ "get", "post" }) do
		curl[name] = function(url, opts)
			return Job:new(url, opts)
		end
		chat_curl[name] = async.wrap(function(url, opts, done)
			if opts.fail_leaf then
				error("fixture leaf failure")
			end
			local args = vim.tbl_extend("force", opts, {
				callback = function(response)
					done(response)
				end,
				on_error = function(err)
					done(nil, err.stderr)
				end,
			})
			curl[name](url, args)
		end, 3)
	end
	return curl, chat_curl, Job, jobs
end

return M
