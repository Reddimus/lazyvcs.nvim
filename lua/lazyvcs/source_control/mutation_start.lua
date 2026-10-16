local util = require("lazyvcs.util")
local buffer_guard = require("lazyvcs.source_control.buffer_guard")

local M = {}

-- Preflight and mutation share a worker and one deadline.
function M.start(repo, args, opts, guards, on_exit)
	-- A zero timeout means unbounded, as in the scheduler.
	local deadline = (opts.timeout and opts.timeout > 0) and (vim.uv.hrtime() / 1e6 + opts.timeout) or nil
	local child, terminal, done
	local serial = 0
	local handle = {}
	local function report(err)
		util.notify(("Mutation callback failed: " .. tostring(err)):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
	end
	local function finish(result, err, raw)
		if done then
			return
		end
		done, child = true, nil
		if terminal then
			result, err, raw = nil, terminal.stderr, terminal
		end
		local ok, callback_err = pcall(on_exit, result, err, raw)
		if not ok then
			report(callback_err)
		end
	end
	local function reject(err)
		finish(nil, err, { code = 1, stdout = "", stderr = err })
	end
	local function terminate(_, err, raw)
		if done or terminal then
			return
		end
		terminal = raw or { code = 130, stdout = "", stderr = err or "Cancelled", cancelled = true }
		if opts.on_terminate then
			local ok, callback_err = pcall(opts.on_terminate, nil, terminal.stderr, terminal)
			if not ok then
				report(callback_err)
			end
		end
	end
	function handle:cancel(reason)
		if done or terminal then
			return false
		end
		terminate(nil, nil, {
			code = 130,
			stdout = "",
			stderr = "Cancelled: " .. tostring(reason or "cancelled"),
			cancelled = true,
		})
		if child then
			return child:cancel(reason)
		end
		return true
	end
	function handle:kill()
		return self:cancel("cancelled")
	end

	local function spawn(command, continuation)
		if done or terminal then
			return
		end
		local remaining = deadline and math.ceil(deadline - vim.uv.hrtime() / 1e6) or nil
		if remaining and remaining <= 0 then
			return finish(
				nil,
				"Mutation timed out",
				{ code = 124, stdout = "", stderr = "Mutation timed out", timed_out = true }
			)
		end
		serial = serial + 1
		local current = serial
		local process_opts = vim.tbl_extend("force", opts, { timeout = remaining, on_terminate = terminate })
		if command == args and guards.on_mutation_start then
			guards.on_mutation_start()
		end
		local ok, started = pcall(util.system_start, command, process_opts, function(result, err, raw)
			if done or current ~= serial then
				return
			end
			child = nil
			if terminal or err or (raw or result or {}).code ~= 0 then
				return finish(result, err, raw or result)
			end
			local continued, continuation_err = pcall(continuation, result)
			if not continued then
				reject((tostring(continuation_err):gsub("[\r\n]+", " ")))
			end
		end)
		if not ok then
			return reject((tostring(started):gsub("[\r\n]+", " ")))
		end
		if not done and serial == current then
			child = started
			if terminal and child then
				child:cancel("cancelled")
			end
		end
	end

	local function mutate()
		if guards.guard_modified_buffers then
			local err = buffer_guard.error(repo.root, guards.guard_paths, guards.guard_subtrees)
			if err then
				return reject(err)
			end
		end
		if guards.guard_relpaths then
			for index, expected in ipairs(guards.guard_relpaths) do
				local relative, err = util.relpath(repo.root, guards.guard_paths[index])
				if relative ~= expected or util.canonical_path(repo.root) ~= repo.root then
					return reject(err or "Repository entry changed before discard; refresh and retry")
				end
			end
		end
		spawn(args, function(result)
			finish(result, nil, result)
		end)
	end
	if guards.branch_ref then
		spawn({ "git", "symbolic-ref", "--quiet", "HEAD" }, function(result)
			if util.trim(result.stdout) ~= guards.branch_ref then
				return reject("Branch changed while preparing the mutation; retry the action.")
			end
			mutate()
		end)
	elseif guards.svn_discard then
		local plan = guards.svn_discard
		spawn({ "svn", "info", "--xml", "--depth", "empty", "--", util.svn_target(plan.relpath) }, function(result)
			local info = require("lazyvcs.backends.xml").parse_info(result.stdout)
			local recursive = info and info.kind == "dir" and info.schedule == "delete"
			if not info or not info.kind or not info.schedule or recursive ~= plan.recursive then
				return reject("SVN directory classification changed before discard; refresh and retry.")
			end
			mutate()
		end)
	else
		mutate()
	end
	return handle
end

return M
