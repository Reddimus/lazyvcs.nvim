local util = require("lazyvcs.util")
local jobs = require("lazyvcs.source_control.jobs")
local Task = require("lazyvcs.backends.task")
local M = {}

function M.root_output(stdout)
	if stdout:sub(-1) ~= "\n" then
		return nil, "Repository root output has no record terminator"
	end
	local root = stdout:sub(1, -2)
	if vim.fn.has("win32") == 1 and root:sub(-1) == "\r" then
		root = root:sub(1, -2)
	end
	if root == "" then
		return nil, "Repository returned an empty root"
	end
	return util.canonical_path(root)
end

function M.root(args, opts, callback)
	local root = opts.root
	opts = vim.tbl_extend("force", {}, opts)
	opts.root = nil
	if not root then
		local probe_opts = vim.tbl_extend("force", opts, { probe = true })
		return M.bytes(args, probe_opts, function(bytes, err, raw)
			if not bytes then
				return callback(nil, err, raw)
			end
			local decoded, decode_err = M.root_output(bytes)
			callback(decoded, decode_err, raw)
		end)
	end
	local task = Task.new(callback)
	vim.uv.fs_stat(root, function(err, stat)
		vim.schedule(util.safe_callback(function()
			if not task:is_active() then
				return
			end
			if not stat then
				local missing = err and (err:match("^ENOENT:") or err:match("^ENOTDIR:"))
				return task:finish(nil, err, missing and { code = "stale_root" } or nil)
			end
			task:finish(root)
		end))
	end)
	return task
end

function M.start(args, opts, callback)
	opts = vim.tbl_extend("force", {}, opts or {})
	if vim.tbl_contains(args, "-z") then
		opts.text = false
	end
	if opts.probe then
		opts.probe = nil
		return util.system_start(args, opts, callback)
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

---@param args string[]
---@param opts table
---@param callback fun(bytes: string?, err: string?, raw: table?): any
---@return table task
function M.bytes(args, opts, callback)
	return M.start(args, vim.tbl_extend("force", opts or {}, { text = false }), function(result, err, raw)
		if not result then
			return callback(nil, err, raw)
		end
		if result.stdout_truncated or result.stderr_truncated then
			local message = args[1] == "git"
					and args[2] == "blame"
					and string.format(
						"Blame output exceeded the %d MiB limit",
						math.floor((opts.output_limit_bytes or opts.output_limit or 4 * 1024 * 1024) / 2 / 1024 / 1024)
					)
				or "Command output was truncated; refusing incomplete contents"
			return callback(nil, message, raw)
		end
		callback(result.stdout or "", nil, raw)
	end)
end

function M.lines(args, opts, callback)
	return M.start(args, opts, function(result, err, raw)
		if not result then
			return callback(nil, err, raw)
		end
		if result.stdout_truncated or result.stderr_truncated then
			local message = args[1] == "git"
					and args[2] == "blame"
					and string.format(
						"Blame output exceeded the %d MiB limit",
						math.floor((opts.output_limit_bytes or opts.output_limit or 4 * 1024 * 1024) / 2 / 1024 / 1024)
					)
				or "Command output was truncated; refusing incomplete contents"
			return callback(nil, message, raw)
		end
		callback(util.split_lines(result.stdout), nil, raw)
	end)
end

return M
