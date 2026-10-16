local Task = require("lazyvcs.backends.task")
local process = require("lazyvcs.backends.process")
local format = require("lazyvcs.backends.blame_format")
local M = {}

function M.load(root, relpath, opts, callback)
	local task = Task.new(callback)
	task:add(process.bytes({ "git", "check-attr", "-z", "filter", "ident", "working-tree-encoding", "--", relpath }, {
		cwd = root,
		timeout = opts.timeout_ms,
	}, function(bytes, err)
		if not bytes then
			return task:finish(nil, err)
		end
		local attributes = {}
		for path, name, value in bytes:gmatch("([^%z]*)%z([^%z]*)%z([^%z]*)%z") do
			if path == relpath then
				attributes[name] = value
			end
		end
		task:finish(format.git_policy(opts, attributes))
	end))
	return task
end

return M
