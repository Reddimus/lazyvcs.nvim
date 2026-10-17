local Task = require("lazyvcs.backends.task")
local process = require("lazyvcs.backends.process")
local format = require("lazyvcs.backends.blame_format")
local ASYNC_TIMEOUT_MS = 30000
local M = {}

function M.load(root, relpath, opts, callback)
	local task = Task.new(callback)
	task:add(process.bytes({ "git", "check-attr", "-z", "filter", "ident", "working-tree-encoding", "--", relpath }, {
		cwd = root,
		timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
	}, function(bytes, err)
		if not bytes then
			return task:finish(nil, err)
		end
		local attributes, parse_err = require("lazyvcs.backends.git_attributes").parse(bytes, relpath)
		if not attributes then
			return task:finish(nil, parse_err)
		end
		task:finish(format.git_policy(opts, attributes))
	end))
	return task
end

return M
