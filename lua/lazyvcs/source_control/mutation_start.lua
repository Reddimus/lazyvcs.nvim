local util = require("lazyvcs.util")
local buffer_guard = require("lazyvcs.source_control.buffer_guard")
local runtime = require("lazyvcs.process_runtime")

local M = {}
local native_plans = {}

runtime.before_shutdown(function()
	for handle in pairs(native_plans) do
		handle:cancel("editor shutdown")
	end
end)

-- Preflight and mutation share a worker and one deadline.
function M.start(repo, args, opts, guards, on_exit)
	-- A zero timeout means unbounded, as in the scheduler.
	local deadline = (opts.timeout and opts.timeout > 0) and (vim.uv.hrtime() / 1e6 + opts.timeout) or nil
	local child, terminal, done
	local request, pending, timer
	local unlink_pending = false
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
		native_plans[handle] = nil
		runtime.untrack(handle)
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
		if terminal then
			result, err, raw = nil, terminal.stderr, terminal
		end
		local ok, callback_err = pcall(on_exit, result, err, raw)
		if not ok then
			report(callback_err)
		end
	end
	local function reject(err)
		err = tostring(err):gsub("[\r\n]+", " ")
		finish(nil, err, { code = 1, stdout = "", stderr = err })
	end
	local function terminate(_, err, raw)
		if done or terminal then
			return
		end
		terminal = raw or { code = 130, stdout = "", stderr = err or "Cancelled", cancelled = true }
		if opts.on_terminate and not unlink_pending then
			local ok, callback_err = pcall(opts.on_terminate, nil, terminal.stderr, terminal)
			if not ok then
				report(callback_err)
			end
		end
	end
	function handle:cancel(reason)
		if done or terminal then
			return not done and unlink_pending and "pending" or false
		end
		terminate(nil, nil, {
			code = 130,
			stdout = "",
			stderr = "Cancelled: " .. tostring(reason or "cancelled"),
			cancelled = true,
		})
		if request then
			pcall(vim.uv.cancel, request)
		end
		-- The scheduler must wait for the unlink result before reporting cancellation.
		if unlink_pending then
			return "pending"
		end
		if child then
			return child:cancel(reason)
		elseif not pending then
			finish()
		end
		return true
	end
	function handle:kill()
		return self:cancel("cancelled")
	end

	local function spawn(command, continuation, mutation)
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
		local process_opts = vim.tbl_extend("force", opts, {
			timeout = remaining,
			on_terminate = terminate,
			preserve_on_shutdown = opts.preserve_on_shutdown and mutation == true,
		})
		if guards.git_untracked_delete then
			process_opts.text = false
		end
		if mutation and guards.on_mutation_start then
			guards.on_mutation_start()
		end
		local exited = false
		local ok, started = pcall(util.system_start, command, process_opts, function(result, err, raw)
			exited = true
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
		if not done and not exited and serial == current then
			child = started
			if terminal and child then
				child:cancel("cancelled")
			end
		end
	end

	local function guard_error()
		if guards.guard_modified_buffers then
			local err = buffer_guard.error(repo.root, guards.guard_paths, guards.guard_subtrees)
			if err then
				return err
			end
		end
		if guards.guard_relpaths then
			for index, expected in ipairs(guards.guard_relpaths) do
				local relative, err = util.relpath(repo.root, guards.guard_paths[index])
				if relative ~= expected or util.canonical_path(repo.root) ~= repo.root then
					return err or "Repository entry changed before discard; refresh and retry"
				end
			end
		end
	end
	local function native_discard()
		local plan = guards.git_untracked_delete
		native_plans[handle] = true
		runtime.track(handle)
		handle.shutdown = handle.cancel
		handle.force = handle.cancel
		handle.close_timers = function()
			if timer then
				timer:stop()
				timer:close()
				timer = nil
			end
		end
		local function stopped()
			if done then
				return true
			end
			if not terminal and runtime.is_shutting_down() then
				handle:cancel("editor shutdown")
			end
			if not terminal and deadline and vim.uv.hrtime() / 1e6 >= deadline then
				terminate(nil, nil, { code = 124, stdout = "", stderr = "Mutation timed out", timed_out = true })
			end
			if terminal then
				if not pending and not child then
					finish()
				end
				return true
			end
			return false
		end
		if deadline then
			timer = assert(vim.uv.new_timer())
			timer:start(math.max(1, math.ceil(deadline - vim.uv.hrtime() / 1e6)), 0, function()
				vim.schedule(function()
					local ok, err = pcall(function()
						if done then
							return
						end
						terminate(
							nil,
							nil,
							{ code = 124, stdout = "", stderr = "Mutation timed out", timed_out = true }
						)
						if request then
							pcall(vim.uv.cancel, request)
						end
						if child then
							child:cancel("timeout")
						elseif not pending then
							finish()
						end
					end)
					if not ok then
						report(err)
						reject(tostring(err):gsub("[\r\n]+", " "))
					end
				end)
			end)
		end
		local function filesystem(operation, continuation, path, allow_missing)
			if stopped() then
				return
			end
			pending = true
			unlink_pending = operation == vim.uv.fs_unlink
			local submitted, value, submit_err = pcall(operation, path or plan.path, function(err, result)
				vim.schedule(function()
					pending, request = false, nil
					local ok, callback_err = pcall(function()
						if unlink_pending and not err then
							-- A completed deletion is authoritative, even after interruption.
							terminal, unlink_pending = nil, false
							return finish({ code = 0, stdout = "", stderr = "" })
						end
						unlink_pending = false
						if stopped() then
							return
						end
						if allow_missing and not err and not result then
							return reject("Cannot verify tracked Discard target: " .. path)
						end
						if err and not (allow_missing and (err == "ENOENT" or tostring(err):match("^ENOENT[: ]"))) then
							return reject(tostring(err):gsub("[\r\n]+", " "))
						end
						continuation(result)
					end)
					if not ok then
						report(callback_err)
						reject(tostring(callback_err):gsub("[\r\n]+", " "))
					end
				end)
			end)
			if not submitted or not value then
				pending, unlink_pending = false, false
				return reject(tostring(submitted and submit_err or value):gsub("[\r\n]+", " "))
			end
			request = value
		end
		if guards.tracked_discard then
			local index = 0
			local function check_next()
				index = index + 1
				local target = guards.tracked_discard[index]
				if not target then
					local err = guard_error()
					if err then
						return reject(err)
					end
					if stopped() then
						return
					end
					native_plans[handle] = nil
					runtime.untrack(handle)
					if timer then
						timer:stop()
						timer:close()
						timer = nil
					end
					return spawn(args, function(result)
						finish(result, nil, result)
					end, true)
				end
				filesystem(vim.uv.fs_lstat, function(stat)
					if stat and stat.type ~= "file" and stat.type ~= "link" then
						return reject("Tracked Discard refuses " .. stat.type .. " obstruction at " .. target.relpath)
					end
					if stat and stat.type == "link" and vim.fn.has("win32") == 1 then
						-- libuv reports both junctions and symbolic links as links on Windows.
						local script = "(Get-Item -Force -ErrorAction Stop -LiteralPath '"
							.. target.path:gsub("'", "''")
							.. "').LinkType"
						return spawn(
							{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script },
							function(result)
								if util.trim(result.stdout) ~= "SymbolicLink" then
									return reject(
										"Tracked Discard refuses junction or unknown link obstruction at "
											.. target.relpath
									)
								end
								check_next()
							end
						)
					end
					check_next()
				end, target.path, true)
			end
			return check_next()
		end

		local function file_type(stat)
			if not stat or (stat.type ~= "file" and stat.type ~= "link") then
				reject(
					"Untracked Discard only deletes files or symlinks; directories and other file types are refused."
				)
				return false
			end
			return true
		end
		filesystem(vim.uv.fs_lstat, function(stat)
			if not file_type(stat) then
				return
			end
			spawn(args, function(result)
				if result.stdout_truncated or result.stdout ~= "?? " .. plan.relpath .. "\0" then
					return reject("Untracked entry changed before discard; refresh and retry.")
				end
				filesystem(vim.uv.fs_lstat, function(current)
					if not file_type(current) then
						return
					end
					local err = guard_error()
					if err then
						return reject(err)
					end
					if stopped() then
						return
					end
					if guards.on_mutation_start then
						guards.on_mutation_start()
					end
					filesystem(vim.uv.fs_unlink, function()
						finish({ code = 0, stdout = "", stderr = "" })
					end)
				end)
			end)
		end)
	end
	local function mutate()
		local err = guard_error()
		if err then
			return reject(err)
		end
		if guards.git_untracked_delete or guards.tracked_discard then
			return native_discard()
		end
		spawn(args, function(result)
			finish(result, nil, result)
		end, true)
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
			if
				not info
				or not info.kind
				or not info.schedule
				or recursive ~= plan.recursive
				or info.kind ~= plan.kind
			then
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
