local Task = require("lazyvcs.backends.task")
local jobs = require("lazyvcs.source_control.jobs")
local util = require("lazyvcs.util")
local M = { max_file_bytes = 1024 * 1024 }

function M.task(callback)
	return Task.new(callback, {
		cancel_id = function(id)
			jobs.cancel(function(job)
				return job.id == id
			end)
		end,
	})
end

function M.command(task, repo, args, callback, opts)
	if not task:is_active() then
		return
	end
	opts = vim.tbl_extend("force", {
		owner = task,
		timeout_ms = 30000,
		output_limit_bytes = 4 * 1024 * 1024,
		start = function(argv, scheduled, on_exit)
			return util.system_start(argv, vim.tbl_extend("force", scheduled, { text = false }), on_exit)
		end,
	}, opts or {})
	task:add(jobs.command(repo, "comparison", args, opts, function(result, err, raw)
		if not task:is_active() then
			return
		end
		if result and (result.stdout_truncated or result.stderr_truncated) then
			return callback(nil, "Comparison output was truncated; narrow the comparison", raw)
		end
		callback(result and result.stdout, err, raw)
	end))
end

function M.read_file(task, path, callback)
	vim.uv.fs_lstat(path, function(err, stat)
		vim.schedule(function()
			if not task:is_active() then
				return
			end
			if err then
				return callback(nil, err)
			end
			if stat.type == "link" then
				vim.uv.fs_readlink(path, function(link_err, target)
					vim.schedule(function()
						if task:is_active() then
							callback(target, link_err)
						end
					end)
				end)
				return
			end
			if stat.type ~= "file" then
				return callback(nil, "Directory or submodule; open it to inspect its contents")
			end
			if stat.size > M.max_file_bytes then
				return callback(nil, "File exceeds the 1 MiB preview limit")
			end
			vim.uv.fs_open(path, "r", 0, function(open_err, fd)
				if not fd then
					return vim.schedule(function()
						if task:is_active() then
							callback(nil, open_err)
						end
					end)
				end
				vim.uv.fs_read(fd, M.max_file_bytes + 1, 0, function(read_err, data)
					vim.uv.fs_close(fd)
					vim.schedule(function()
						if not task:is_active() then
							return
						end
						if data and #data > M.max_file_bytes then
							return callback(nil, "File exceeds the 1 MiB preview limit")
						end
						callback(data, read_err)
					end)
				end)
			end)
		end)
	end)
end

function M.lines(data)
	if data:find("\0", 1, true) then
		return nil, "Binary file; text preview unavailable"
	end
	if #data > M.max_file_bytes then
		return nil, "File exceeds the 1 MiB preview limit"
	end
	return util.split_lines(data:gsub("\r\n", "\n"))
end

function M.provider(vcs)
	assert(vcs == "git" or vcs == "svn", "Unsupported comparison backend")
	return require("lazyvcs.backends.compare_" .. vcs)
end

return M
