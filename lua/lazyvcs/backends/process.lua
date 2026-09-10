local util = require("lazyvcs.util")
local jobs = require("lazyvcs.source_control.jobs")
local Task = require("lazyvcs.backends.task")
local M = {}

function M.root(args, opts, callback)
	local root = opts.root
	opts = vim.tbl_extend("force", {}, opts)
	opts.root = nil
	if not root then
		return M.start(args, opts, callback)
	end
	local task = Task.new(callback)
	vim.schedule(function()
		task:finish({ code = 0, stdout = root, stderr = "" })
	end)
	return task
end

function M.start(args, opts, callback)
	opts = vim.tbl_extend("force", {}, opts or {})
	if vim.tbl_contains(args, "-z") then
		opts.text = false
	end
	local task = Task.new(callback, {
		cancel_id = function(id)
			jobs.cancel(function(job)
				return job.id == id
			end)
		end,
	})
	local root = opts.cwd or vim.fn.getcwd()
	task:add(jobs.command({ root = root, vcs = args[1] }, "buffer", args, {
		owner = task,
		timeout_ms = opts.timeout_ms or opts.timeout or 30000,
		output_limit_bytes = opts.output_limit_bytes or opts.output_limit or 4 * 1024 * 1024,
		start = function(argv, scheduled, on_exit)
			return util.system_start(argv, vim.tbl_extend("force", opts, scheduled), on_exit)
		end,
	}, function(result, err, raw)
		task:finish(result, err, raw)
	end))
	return task
end

function M.lines(args, opts, callback)
	return M.start(args, opts, function(result, err, raw)
		if not result then
			return callback(nil, err, raw)
		end
		if result.stdout_truncated or result.stderr_truncated then
			return callback(nil, "Command output was truncated; refusing incomplete contents", raw)
		end
		callback(util.split_lines(result.stdout), nil, raw)
	end)
end

return M
