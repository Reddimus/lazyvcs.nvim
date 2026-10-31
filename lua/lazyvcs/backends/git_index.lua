local util = require("lazyvcs.util")
local Task = require("lazyvcs.backends.task")
local M = {}

-- Cached diff reads the index even when assume-unchanged/skip-worktree suppress
-- worktree status. The two documented ITA views differ only for an ITA entry.
function M.intent_commands(relpath)
	local commands = {}
	for _, visibility in ipairs({ "visible", "invisible" }) do
		commands[#commands + 1] = {
			"git",
			"--literal-pathspecs",
			"diff",
			"--cached",
			"--raw",
			"--abbrev=64",
			"--no-renames",
			"--no-color",
			"--no-ext-diff",
			"--no-textconv",
			-- A file replacing a HEAD directory also deletes its old children.
			-- Exclude those D records from both views, retaining one exact file:
			-- ITA is visible as A/M/T and invisible as absent/deleted.
			"--diff-filter=d",
			"-z",
			"--ita-" .. visibility .. "-in-index",
			"--",
			relpath,
		}
	end
	return commands
end

function M.intent_output_limit(relpath)
	-- Each view contains at most one raw header, its exact NUL-delimited path,
	-- and two full object IDs. util splits its transport budget between streams.
	return 2 * (#relpath + 1024)
end

local function valid_view(raw, relpath)
	if raw == "" then
		return true
	end
	if type(raw) ~= "string" then
		return false
	end
	local before_mode, after_mode, before, after, path = raw:match("^:(%d+) (%d+) (%x+) (%x+) [ADMTU]%z(.-)%z$")
	return path == relpath
		and #before_mode == 6
		and #after_mode == 6
		and (#before == 40 or #before == 64)
		and #after == #before
end

function M.parse_intent(visible, invisible, relpath)
	if not valid_view(visible, relpath) or not valid_view(invisible, relpath) then
		return nil, "Cannot verify exact Git index intent; refresh and retry"
	end
	return visible ~= invisible
end

local function output(result, err, relpath)
	if not result then
		return nil, err or "Cannot inspect Git index intent"
	end
	if result.code ~= 0 or (result.signal or 0) ~= 0 then
		return nil, err or util.system_error(result) or "Cannot inspect Git index intent"
	end
	if
		result.stdout_truncated
		or result.stderr_truncated
		or type(result.stdout) ~= "string"
		or #result.stdout > M.intent_output_limit(relpath) / 2
	then
		return nil, "Git index intent output was truncated; refusing discard"
	end
	return result.stdout
end

function M.intent_to_add(root, relpath)
	local views = {}
	for index, args in ipairs(M.intent_commands(relpath)) do
		local result, err =
			util.system(args, { cwd = root, text = false, output_limit_bytes = M.intent_output_limit(relpath) })
		views[index], err = output(result, err, relpath)
		if views[index] == nil then
			return nil, err
		end
	end
	return M.parse_intent(views[1], views[2], relpath)
end

-- start has util.system_start's signature. Mutation callers provide their
-- existing worker-local starter, retaining its cancellation and deadline owner.
function M.intent_to_add_async(root, relpath, start, callback, opts)
	local task = Task.new(callback)
	local commands, views = M.intent_commands(relpath), {}
	local function read(index)
		task:add(start(commands[index], {
			cwd = root,
			text = false,
			timeout = opts and (opts.timeout_ms or opts.timeout) or 30000,
			output_limit_bytes = M.intent_output_limit(relpath),
		}, function(result, err)
			if not task:is_active() then
				return
			end
			views[index], err = output(result, err, relpath)
			if views[index] == nil then
				return task:finish(nil, err)
			end
			if index == 1 then
				return read(2)
			end
			task:finish(M.parse_intent(views[1], views[2], relpath))
		end))
	end
	read(1)
	return task
end

return M
