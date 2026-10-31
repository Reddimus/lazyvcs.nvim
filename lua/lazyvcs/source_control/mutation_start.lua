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

	local function spawn(command, continuation, mutation, environment, allowed_code, output_budget)
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
		if output_budget then
			process_opts.output_limit_bytes = output_budget
		end
		if environment then
			process_opts.env = vim.tbl_extend("force", opts.env or {}, environment)
		end
		if guards.git_untracked_delete or vim.tbl_contains(command, "-z") then
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
			-- Use one authoritative object for both the exit check and continuation.
			local output = raw or result or {}
			local code = output.code
			if terminal then
				return finish(result, err, output)
			end
			if allowed_code then
				-- Only a normal rev-parse exit of 1 means HEAD is unborn. Synthetic
				-- failures have no exit signal, and incomplete output proves nothing.
				local exited = output.signal == 0 and not output.cancelled and not output.timed_out
				local complete = not output.stdout_truncated and not output.stderr_truncated
				local expected_error = code == allowed_code and (not err or err == util.system_error(output))
				if not exited or not complete or not ((code == 0 and not err) or expected_error) then
					return reject(
						"Cannot verify HEAD for tracked Discard: " .. tostring(err or "incomplete process result")
					)
				end
			elseif err or code ~= 0 then
				return finish(result, err, output)
			end
			local continued, continuation_err = pcall(continuation, output)
			if not continued then
				reject((tostring(continuation_err):gsub("[\r\n]+", " ")))
			end
		end)
		if not ok then
			local prefix = allowed_code and "Cannot verify HEAD for tracked Discard: " or ""
			return reject(prefix .. (tostring(started):gsub("[\r\n]+", " ")))
		end
		if not done and not exited and serial == current then
			child = started
			if terminal and child then
				child:cancel("cancelled")
			end
		end
	end

	local function guard_error()
		if guards.status_complete and not guards.status_complete() then
			return "Status incomplete; refresh before bulk mutation."
		end
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
	local head_exists
	local function check_head(continuation)
		if head_exists ~= nil then
			return continuation(head_exists)
		end
		return spawn({ "git", "rev-parse", "--verify", "--quiet", "HEAD^{commit}" }, function(result)
			head_exists = result.code == 0
			continuation(head_exists)
		end, nil, nil, 1)
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
		if guards.tracked_discard or guards.git_stage then
			local index = 0
			local function check_next()
				index = index + 1
				local target = (guards.tracked_discard or guards.git_stage)[index]
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
				local function check_target()
					filesystem(vim.uv.fs_lstat, function(stat)
						if target.directory then
							if stat and stat.type ~= "directory" then
								return reject(
									"SVN Discard refuses "
										.. stat.type
										.. " directory obstruction at "
										.. target.relpath
								)
							end
							return check_next()
						end
						if
							stat
							and stat.type == "directory"
							and repo.vcs == "git"
							and (args[2] == "restore" or guards.git_stage)
						then
							-- Validate the source restore will write, including rename sources.
							local from_head = false
							for _, argument in ipairs(args) do
								if argument == "--" then
									break
								end
								from_head = from_head or argument == "--source=HEAD"
							end
							local function is_gitlink(result, head)
								if result.stdout_truncated then
									return false
								end
								local output = result.stdout
								if head and output == "" then
									return true
								end
								local mode, kind, path
								if head then
									mode, kind, path = output:match("^(%d+) (%w+) %x+\t([^%z]+)%z$")
								else
									mode, kind, path = output:match("^(%d+) %x+ (%d)\t([^%z]+)%z$")
								end
								return mode == "160000"
									and kind == (head and "commit" or "0")
									and path == target.relpath
							end
							local function refuse()
								return reject(
									(guards.git_stage and "Stage" or "Tracked Discard")
										.. " refuses directory obstruction at "
										.. target.relpath
								)
							end
							return spawn(
								{ "git", "--literal-pathspecs", "ls-files", "--stage", "-z", "--", target.relpath },
								function(result)
									if not is_gitlink(result, false) then
										return refuse()
									end
									if not from_head then
										return check_next()
									end
									return check_head(function(exists)
										if not exists then
											return check_next()
										end
										return spawn({
											"git",
											"--literal-pathspecs",
											"ls-tree",
											"-z",
											"HEAD",
											"--",
											target.relpath,
										}, function(tree)
											if not is_gitlink(tree, true) then
												return refuse()
											end
											return check_next()
										end)
									end)
								end
							)
						end
						if stat and stat.type ~= "file" and stat.type ~= "link" then
							return reject(
								"Tracked Discard refuses " .. stat.type .. " obstruction at " .. target.relpath
							)
						end
						if stat and stat.type == "link" and vim.fn.has("win32") == 1 then
							-- libuv reports junctions and file and directory symbolic links as links on Windows.
							local script = "$item = Get-Item -Force -ErrorAction Stop -LiteralPath $env:LAZYVCS_LINK; "
								.. "'{0}|{1}' -f $item.LinkType, $item.PSIsContainer"
							return spawn(
								{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script },
								function(result)
									local kind, directory = util.trim(result.stdout):match("^(%a+)|(%a+)$")
									if kind ~= "SymbolicLink" or (directory ~= "True" and directory ~= "False") then
										return reject(
											"Tracked Discard refuses junction or unknown link obstruction at "
												.. target.relpath
										)
									end
									if directory == "True" and repo.vcs == "svn" then
										-- Subversion cannot replace a directory link on Windows; revert
										-- fails and leaves the working copy locked.
										return reject(
											"Tracked Discard refuses directory link obstruction at "
												.. target.relpath
												.. "; Subversion cannot replace it on Windows"
										)
									end
									check_next()
								end,
								nil,
								{ LAZYVCS_LINK = target.path }
							)
						end
						check_next()
					end, target.path, true)
				end
				if repo.vcs ~= "git" then
					return check_target()
				end
				-- Check proper ancestors even for file/missing targets: restore can
				-- replace an index gitlink while writing a descendant from HEAD.
				local offset = 1
				local function check_ancestor()
					local separator = target.relpath:find("/", offset, true)
					if not separator then
						return check_target()
					end
					offset = separator + 1
					local prefix = target.relpath:sub(1, separator - 1)
					local function refuse()
						return reject("Tracked Discard refuses nested repository ancestor at " .. prefix)
					end
					local function contains_gitlink(result, head)
						if result.stdout == "" and not result.stdout_truncated then
							return false
						end
						-- The exact prefix sorts before its descendants. Only the first
						-- complete record can be its gitlink, even if later output is cut.
						local entry = result.stdout:match("^([^%z]+)%z")
						local mode, path
						if entry then
							if head then
								mode, path = entry:match("^(%d+) %w+ %x+\t(.*)$")
							else
								mode, path = entry:match("^(%d+) %x+ %d\t(.*)$")
							end
						end
						if not mode then
							reject("Tracked Discard ancestor check could not complete at " .. prefix)
							return nil
						end
						return mode == "160000" and path == prefix
					end
					filesystem(vim.uv.fs_lstat, function(stat)
						if stat then
							return refuse()
						end
						spawn(
							{ "git", "--literal-pathspecs", "ls-files", "--stage", "-z", "--", prefix },
							function(result)
								local linked = contains_gitlink(result, false)
								if linked == nil then
									return
								elseif linked then
									return refuse()
								end
								-- Stage writes the current index, so a former HEAD gitlink
								-- does not obstruct ordinary files indexed beneath it.
								if guards.git_stage then
									return check_ancestor()
								end
								check_head(function(exists)
									if not exists then
										return check_ancestor()
									end
									spawn(
										{ "git", "--literal-pathspecs", "ls-tree", "-z", "HEAD", "--", prefix },
										function(tree)
											local head_linked = contains_gitlink(tree, true)
											if head_linked == nil then
												return
											elseif head_linked then
												return refuse()
											end
											check_ancestor()
										end
									)
								end)
							end
						)
					end, repo.root .. "/" .. prefix .. "/.git", true)
				end
				check_ancestor()
			end
			return check_next()
		end

		local function file_type(stat)
			if not stat or (stat.type ~= "file" and stat.type ~= "link") then
				reject(
					"Untracked Discard refuses directories and other non-file types; it deletes only files or symlinks."
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
		if guards.git_untracked_delete or guards.tracked_discard or guards.git_stage then
			return native_discard()
		end
		spawn(args, function(result)
			finish(result, nil, result)
		end, true)
	end

	local intent_paths
	if repo.vcs == "git" and guards.tracked_discard then
		intent_paths = {}
		for _, target in ipairs(guards.tracked_discard) do
			intent_paths[#intent_paths + 1] = target.relpath
		end
	elseif guards.git_intent_guard then
		-- Preserve the direct single-path guard used by lower-level callers.
		intent_paths = { guards.git_intent_guard }
	end
	local function git_preflight()
		if intent_paths then
			local index = require("lazyvcs.backends.git_index")
			local cursor = 0
			local function check_next()
				cursor = cursor + 1
				local path = intent_paths[cursor]
				if not path then
					intent_paths = nil
					return git_preflight()
				end
				local commands, budget = index.intent_commands(path), index.intent_output_limit(path)
				for _, command in ipairs(commands) do
					-- A file replacing a HEAD directory also deletes its old children.
					-- Exclude those D records from both views, retaining an exact file
					-- record: ITA is visible as A/M/T and invisible as absent/deleted.
					for position, argument in ipairs(command) do
						if argument == "--" then
							table.insert(command, position, "--diff-filter=d")
							break
						end
					end
				end
				return spawn(commands[1], function(visible)
					if visible.stdout_truncated or visible.stderr_truncated then
						return reject("Cannot verify complete Git index intent; refusing Discard.")
					end
					spawn(commands[2], function(invisible)
						if invisible.stdout_truncated or invisible.stderr_truncated then
							return reject("Cannot verify complete Git index intent; refusing Discard.")
						end
						local intent, err = index.parse_intent(visible.stdout, invisible.stdout, path)
						if intent ~= false then
							return reject(
								err
									or "Discard refuses intent-to-add content not stored in Git; unstage or delete it explicitly."
							)
						end
						check_next()
					end, nil, nil, nil, budget)
				end, nil, nil, nil, budget)
			end
			return check_next()
		elseif guards.git_head_restore then
			local command = {
				"git",
				"--literal-pathspecs",
				"status",
				"--porcelain=v1",
				"-z",
				"--ignored",
				"--untracked-files=all",
				"--",
			}
			vim.list_extend(command, guards.git_head_restore)
			return spawn(command, function(result)
				if result.stdout_truncated then
					return reject("Cannot verify Discard restore paths; refresh and retry.")
				end
				for _, path in ipairs(guards.git_head_restore) do
					if
						result.stdout:find("?? " .. path .. "\0", 1, true)
						or result.stdout:find("!! " .. path .. "\0", 1, true)
					then
						return reject("Discard refuses untracked or ignored file at " .. path .. "; move it and retry.")
					end
				end
				guards.git_head_restore = nil
				git_preflight()
			end)
		elseif guards.git_require_resolved then
			return spawn({ "git", "ls-files", "--unmerged", "-z" }, function(result)
				if result.stdout_truncated or result.stdout ~= "" then
					return reject(
						"Stage all and commit refuses unresolved conflicts; resolve and stage them explicitly."
					)
				end
				mutate()
			end)
		end
		if guards.git_addition then
			local path = guards.git_addition
			return spawn({ "git", "ls-files", "--stage", "-z", "--", path }, function(result)
				-- A file replacing a HEAD tree also reports deletions below this
				-- path. Validate the exact index entry instead of that whole diff.
				local mode, stage, indexed = result.stdout:match("^(%d+) %x+ (%d)\t([^%z]+)%z$")
				if result.stdout_truncated or not mode or stage ~= "0" or indexed ~= path then
					return reject("Addition changed before mutation at " .. path .. "; refresh and retry.")
				end
				check_head(function(exists)
					if not exists then
						return mutate()
					end
					spawn({ "git", "ls-tree", "-z", "HEAD", "--", path }, function(tree)
						local mode, kind, previous = tree.stdout:match("^(%d+) (%w+) %x+\t([^%z]+)%z$")
						local directory = mode == "040000" and kind == "tree" and previous == path
						if tree.stdout_truncated or (tree.stdout ~= "" and not directory) then
							return reject("Addition changed before mutation at " .. path .. "; refresh and retry.")
						end
						mutate()
					end)
				end)
			end)
		elseif guards.git_unstage then
			local index = 0
			local function check_next()
				index = index + 1
				local path = guards.git_unstage[index]
				if not path then
					return mutate()
				end
				local function refuse()
					return reject("Unstage scope changed at " .. path .. "; refresh and retry.")
				end
				spawn({ "git", "ls-files", "--stage", "-z", "--", path }, function(result)
					if result.stdout_truncated then
						return refuse()
					end
					local remaining = result.stdout
					while remaining ~= "" do
						local entry, rest = remaining:match("^([^%z]+)%z(.*)$")
						local indexed = entry and entry:match("^%d+ %x+ %d\t(.*)$")
						if indexed ~= path then
							return refuse()
						end
						remaining = rest
					end
					spawn({ "git", "ls-tree", "-z", "HEAD", "--", path }, function(tree)
						local mode, kind, previous = tree.stdout:match("^(%d+) (%w+) %x+\t([^%z]+)%z$")
						if
							tree.stdout_truncated
							or (tree.stdout ~= "" and (not mode or kind == "tree" or previous ~= path))
						then
							return refuse()
						end
						check_next()
					end)
				end)
			end
			return check_next()
		elseif guards.git_rename_source then
			local path = guards.git_rename_source
			return spawn(
				{ "git", "status", "--porcelain=v1", "-z", "--ignored", "--untracked-files=all", "--", path },
				function(result)
					if
						result.stdout_truncated
						or result.stdout:find("?? " .. path .. "\0", 1, true)
						or result.stdout:find("!! " .. path .. "\0", 1, true)
					then
						return reject(
							"Discard refuses untracked or ignored rename source at " .. path .. "; move it and retry."
						)
					end
					mutate()
				end
			)
		elseif guards.git_conflict then
			return spawn({ "git", "ls-tree", "-z", "HEAD", "--", guards.git_conflict }, function(result)
				if result.stdout_truncated then
					return reject("Cannot verify conflict HEAD; refresh and retry.")
				end
				if result.stdout == "" then
					args = { "git", "rm", "-f", "--", guards.git_conflict }
				end
				mutate()
			end)
		end
		mutate()
	end

	local function remote_preflight()
		local intent = guards.git_remote_intent
		if not intent then
			return mutate()
		end
		local plan = require("lazyvcs.source_control.push_intent")
		local function final_head()
			spawn({ "git", "symbolic-ref", "--quiet", "HEAD" }, function(head)
				if head.stdout_truncated or util.trim(head.stdout) ~= guards.branch_ref then
					return reject("Branch changed during remote mutation preflight; retry the action.")
				end
				mutate()
			end)
		end
		local function policy()
			if intent.kind == "fast_forward" then
				return spawn(plan.target_args(intent), function(result)
					if result.stdout_truncated or util.trim(result.stdout) ~= intent.oid then
						return reject("Fetched upstream commit changed after confirmation; retry the action.")
					end
					final_head()
				end)
			end
			spawn(plan.policy_args(), function(result)
				if result.stdout_truncated or util.trim(result.stdout) ~= intent.policy then
					return reject("Push policy changed after confirmation; retry the action.")
				end
				local err = plan.policy_error(intent.branch, intent.target, intent.policy)
				if err then
					return reject(err)
				end
				final_head()
			end)
		end
		spawn({
			"git",
			"for-each-ref",
			"--format=%(refname)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)",
			"refs/heads/" .. intent.branch,
		}, function(result)
			if result.stdout_truncated or result.stdout ~= plan.upstream_signature(intent) then
				return reject("Upstream destination changed after confirmation; retry the action.")
			end
			if not intent.missing then
				return policy()
			end
			spawn({ "git", "remote" }, function(remotes)
				if
					remotes.stdout_truncated
					or not vim.tbl_contains(util.split_lines(remotes.stdout), intent.remote)
				then
					return reject("Publishing remote changed after confirmation; retry the action.")
				end
				policy()
			end)
		end)
	end

	if guards.branch_ref then
		spawn({ "git", "symbolic-ref", "--quiet", "HEAD" }, function(result)
			if result.stdout_truncated or util.trim(result.stdout) ~= guards.branch_ref then
				return reject("Branch changed while preparing the mutation; retry the action.")
			end
			remote_preflight()
		end)
	elseif guards.svn_discard then
		local plan = guards.svn_discard
		spawn({
			"svn",
			"info",
			"--xml",
			"--depth",
			plan.recursive and "infinity" or "empty",
			"--",
			util.svn_target(plan.relpath),
		}, function(result)
			local info = require("lazyvcs.backends.xml").parse_info(result.stdout)
			local recursive = info
				and info.kind == "dir"
				and (info.schedule == "delete" or info.schedule == "add" or info.schedule == "replace")
			if
				not info
				or not info.kind
				or not info.schedule
				or recursive ~= plan.recursive
				or info.kind ~= plan.kind
				or (plan.schedule and info.schedule ~= plan.schedule)
			then
				return reject("SVN directory classification changed before discard; refresh and retry.")
			end
			if plan.recursive then
				if result.stdout_truncated then
					return reject("Cannot verify SVN restore directories; refresh and retry.")
				end
				local xml = require("lazyvcs.backends.xml")
				local targets = {}
				for block in result.stdout:gmatch("<entry%f[%s>].-</entry%s*>") do
					local entry = xml.parse_info(block)
					if not entry or not entry.path or (entry.kind ~= "dir" and entry.kind ~= "file") then
						return reject("Cannot verify SVN restore targets; refresh and retry.")
					end
					local path = util.normalize_literal_path(repo.root .. "/" .. entry.path)
					local relative = util.relative_literal_path(repo.root, path)
					if
						not relative
						or (relative ~= plan.relpath and relative:sub(1, #plan.relpath + 1) ~= plan.relpath .. "/")
					then
						return reject("SVN restore target changed; refresh and retry.")
					end
					-- Check parents first. Never lstat a child through an unchecked link.
					local prefix = ""
					for component in relative:gmatch("[^/]+") do
						prefix = prefix == "" and component or prefix .. "/" .. component
						targets[prefix] = prefix == relative and entry.kind or "dir"
					end
				end
				guards.tracked_discard = {}
				for _, relative in ipairs(vim.fn.sort(vim.tbl_keys(targets))) do
					guards.tracked_discard[#guards.tracked_discard + 1] = {
						path = util.normalize_literal_path(repo.root .. "/" .. relative),
						relpath = relative,
						directory = targets[relative] == "dir",
					}
				end
			end
			mutate()
		end)
	else
		git_preflight()
	end
	return handle
end

return M
