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
		local job = setmetatable({ exit_callbacks = {}, options = opts }, { __index = self })
		function job:_user_on_exit(code, _signal)
			vim.schedule(function()
				-- Match plenary curl's code-only success test, including signal exits.
				if code == 0 then
					if opts.stream then
						opts.stream(nil, "Generated subject")
					end
					opts.callback({ status = opts.http_error and 500 or 200, body = "Generated subject" })
				elseif opts.on_error then
					opts.on_error({ stderr = "cancelled" })
				end
			end)
		end
		function job:_shutdown(code, signal)
			if job.is_shutdown then
				return
			end
			job.signal = signal
			job:_user_on_exit(code, signal)
			for _, callback in ipairs(job.exit_callbacks) do
				callback(job, code)
			end
			job:_stop()
			job.is_shutdown = true
		end
		function job:shutdown(code, signal)
			self:_shutdown(code or 143, signal or 0)
		end
		job.handle, job.pid = assert(vim.uv.spawn(vim.v.progpath, {
			args = {
				"--headless",
				"-u",
				"NONE",
				"-i",
				"NONE",
				"-l",
				child,
				path,
				opts.ignore_term and "ignore-term" or "",
			},
		}, function(code, signal)
			job:_shutdown(code, signal)
		end))
		jobs[#jobs + 1] = { job = job, path = path }
		return job
	end
	function Job:shutdown() end
	function Job:_shutdown() end
	function Job:_stop()
		if not self.handle:is_closing() then
			self.closed_active = self.handle:is_active()
			self.handle:close()
		end
	end
	function Job:add_on_exit_callback(callback)
		self.exit_callbacks[#self.exit_callbacks + 1] = callback
	end
	for _, name in ipairs({ "get", "post" }) do
		curl[name] = function(url, opts)
			return Job:new(url, opts)
		end
		chat_curl[name] = async.wrap(function(url, opts, done)
			if opts.fail_leaf then
				error("fixture leaf failure")
			end
			local body_file
			if opts.json_request then
				body_file = opts.temp_source == "vim" and vim.fn.tempname() or os.tmpname()
				vim.fn.writefile({ vim.json.encode(opts.body) }, body_file, "b")
				vim.uv.fs_chmod(body_file, 384)
			end
			if opts.unused_name then
				vim.fn.writefile({ "unrelated" }, vim.fn.tempname())
			end
			local args
			args = vim.tbl_extend("force", opts, {
				callback = function(response)
					-- An HTTP failure keeps the body, so only LazyVCS cleanup can remove it.
					if body_file and not args.http_error then
						os.remove(body_file)
					end
					done(response, response.status >= 400 and "http failure" or nil)
				end,
				on_error = function(err)
					done(nil, err.stderr)
				end,
			})
			if body_file then
				args.body = body_file
			end
			curl[name](url, args)
		end, 3)
	end
	return curl, chat_curl, Job, jobs
end

function M.with_transport(ctx, run)
	local h, wait, process = ctx.helpers, ctx.wait_for, require("process_helpers")
	local tests = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
	local names = {
		"plenary.async",
		"plenary.job",
		"plenary.curl",
		"CopilotChat.utils.curl",
		"CopilotChat",
		"CopilotChat.client",
		"lazy",
	}
	local previous = {}
	local tempname, tmpname, defer, notify = vim.fn.tempname, os.tmpname, vim.defer_fn, vim.notify
	for _, name in ipairs(names) do
		previous[name] = package.loaded[name]
	end
	local model = assert(loadfile(tests .. "/fixtures/ai_transport_helpers.lua"))()
	local async, dir = model.async(), h.tempdir()
	local curl, chat, Job, jobs = model.transport(dir, tests .. "/fixtures/ai_transport.lua", async)
	package.loaded["plenary.async"], package.loaded["plenary.job"] = async, Job
	package.loaded["plenary.curl"], package.loaded["CopilotChat.utils.curl"] = curl, chat
	package.loaded["lazy"] = { load = function() end }
	package.loaded["CopilotChat"] = { config = { model = "fixture" } }
	local client = { models = function() end, get_providers = function() end }
	package.loaded["CopilotChat.client"] = client
	local function ready(index)
		wait(function()
			return jobs[index] and process.pid(jobs[index].path) ~= nil
		end, "transport did not start", 15000)
		return jobs[index].job
	end
	local ok, err = xpcall(function()
		run({
			async = async,
			curl = curl,
			chat = chat,
			Job = Job,
			jobs = jobs,
			ready = ready,
			client = client,
			dir = dir,
		})
	end, debug.traceback)
	for _, item in ipairs(jobs) do
		if not process.reaped(item.job.pid) then
			pcall(vim.uv.kill, item.job.pid, 9)
		end
	end
	vim.wait(3000, function()
		for _, item in ipairs(jobs) do
			if not process.reaped(item.job.pid) then
				return false
			end
		end
		return true
	end, 10)
	for _, item in ipairs(jobs) do
		if item.job.options.json_request and type(item.job.options.body) == "string" then
			os.remove(item.job.options.body)
		end
	end
	vim.fn.tempname, os.tmpname, vim.defer_fn, vim.notify = tempname, tmpname, defer, notify
	for _, name in ipairs(names) do
		package.loaded[name] = previous[name]
	end
	assert(ok, err)
end

return M
