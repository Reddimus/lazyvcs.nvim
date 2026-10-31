return function(ctx)
	local h, p = ctx.helpers, require("process_helpers")
	local util = require("lazyvcs.util")
	local function windows_cancel_commands(commands)
		local jobs = require("lazyvcs.source_control.jobs")
		local original, has = vim.system, vim.fn.has
		local taskkills, exit, handle, wrapped = 0, nil, nil, false
		local failures = {}
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.has = function(name)
			return name == "win32" and 1 or has(name)
		end
		vim.system = function(args, _, cb)
			if args[1] == "taskkill" then
				taskkills = taskkills + 1
				assert(vim.deep_equal(args, { "taskkill", "/T", "/F", "/PID", "12345" }))
				vim.schedule(function()
					cb({ code = 0 })
				end)
				return {}
			end
			wrapped = args[1] == vim.v.progpath and args[2] == "-ll"
			exit = cb
			local closing = false
			return {
				pid = 12345,
				is_closing = function()
					return closing
				end,
				kill = function()
					if not closing then
						closing = true
						vim.schedule(function()
							cb({ code = 1, stdout = "", stderr = "" })
						end)
					end
				end,
			}
		end
		local ok, err = xpcall(function()
			for _, command in ipairs(commands) do
				taskkills, exit, handle, wrapped = 0, nil, nil, false
				local completed = false
				local function done()
					completed = true
				end
				local passed, failure = xpcall(function()
					if command.kind then
						local id = jobs.command(
							{ root = h.tempdir(), vcs = command.args[1] },
							command.kind,
							command.args,
							{
								start = function(args, opts, cb)
									handle = util.system_start(args, opts, cb)
									return handle
								end,
							},
							done
						)
						ctx.wait_for(function()
							return handle ~= nil
						end, "job did not start")
						jobs.cancel(function(job)
							return job.id == id
						end)
					else
						handle = assert(util.system_start(command.args, { scope = command.scope }, done))
						handle:cancel("test")
					end
					ctx.wait_for(function()
						return completed
					end, "cancelled process did not finish")
					assert(wrapped == (command.tree == true), command.label .. ": command-tree ownership changed")
					assert(taskkills == 0, command.label .. ": owned or direct cancellation spawned taskkill")
				end, debug.traceback)
				if exit then
					exit({ code = 1, stdout = "", stderr = "" })
				end
				if not passed then
					failures[#failures + 1] = command.label .. ": " .. failure
				end
			end
		end, debug.traceback)
		vim.system, vim.fn.has = original, has
		if exit then
			exit({ code = 1, stdout = "", stderr = "" })
		end
		assert(ok, err)
		assert(#failures == 0, table.concat(failures, "\n"))
	end
	local function posix()
		if vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "POSIX process groups" })
		end
	end
	local function queue_case(cancel)
		posix()
		local f = h.make_git_fixture()
		local jobs = require("lazyvcs.source_control.jobs")
		local config = require("lazyvcs.config")
		local old = vim.deepcopy(config.get())
		config.setup({ source_control = { background = { git_workers = 1 } } })
		local argv = p.tree(f.root)
		h.exec({ "git", "config", "core.hooksPath", f.root .. "/.git/hooks" }, f.root)
		h.write_file(
			f.root .. "/.git/hooks/pre-commit",
			'#!/bin/sh\necho $PPID > "' .. f.root .. '/git.pid"\nexec sh "' .. argv[2] .. '" "' .. f.root .. '"\n'
		)
		vim.uv.fs_chmod(f.root .. "/.git/hooks/pre-commit", 493)
		h.exec({ "git", "add", "sample.txt" }, f.root)
		local calls, recovered = 0, false
		---@type table?
		local raw
		local repo = { root = f.root, vcs = "git" }
		local ref = util.trim(h.exec({ "git", "symbolic-ref", "HEAD" }, f.root))
		local function start(args, opts, cb)
			if cancel then
				h.write_file(f.root .. "/private-message", "tree")
				return util.system_start(args, opts, cb)
			end
			return require("lazyvcs.source_control.mutation_start").start(repo, args, opts, { branch_ref = ref }, cb)
		end
		local ok, err = pcall(p.guarded, f.root, function()
			local id = jobs.command(repo, "mutation", { "git", "commit", "-m", "tree" }, {
				timeout_ms = cancel and 10000 or 800,
				kill_grace_ms = 100,
				start = start,
			}, function(_, _, result)
				calls, raw = calls + 1, result
			end)
			ctx.wait_for(function()
				return p.ready(f.root)
			end, "hook did not become ready", 5000)
			jobs.command(repo, "status", { "git", "status", "--short" }, {}, function(_, failure)
				recovered = not failure
			end)
			if cancel then
				jobs.cancel(function(job)
					return job.id == id
				end, "test")
			end
			ctx.wait_for(function()
				return calls == 1
			end, "logical completion missing")
			assert(raw and raw.code == (cancel and 130 or 124), "wrong logical result")
			assert(not recovered, "worker released before physical cleanup")
			ctx.wait_for(function()
				return recovered and p.dead(f.root)
			end, "descendants survived or queued status remained blocked", 2500)
			vim.wait(150)
			assert(calls == 1, "logical completion repeated")
			local count = 0
			for _, item in ipairs(jobs.history()) do
				if item.id == id then
					count = count + 1
					assert(item.status == (cancel and "cancelled" or "timeout"))
				end
			end
			assert(count == 1, "job recorded more than once")
		end)
		config.setup(old)
		assert(ok, err)
	end
	local function job_control_shell()
		for _, shell in ipairs({ "sh", "bash", "ksh", "zsh" }) do
			if vim.fn.executable(shell) == 1 then
				local result = vim.system({ shell, "-c", "set -m; sh -c 'kill -0 -$$' & wait $!" }, { detach = true })
					:wait()
				if result.code == 0 then
					return shell
				end
			end
		end
		error({ lazyvcs_skip = "No shell supports process groups through job control" })
	end
	local function held_pipe_case(forced)
		posix()
		local shell = job_control_shell()
		local dir = h.tempdir()
		local kill = vim.uv.kill
		local signals = {}
		local handle
		local ok, err = pcall(p.guarded, dir, function()
			local calls, timed_out = 0, false
			handle = util.system_start({
				shell,
				"-c",
				"set -m; "
					.. (forced and 'trap "" TERM; ' or "")
					.. 'sh -c \'echo $$ > "$1/helper.pid"; exec sleep 60\' sh "$1" & '
					.. 'echo $$ > "$1/parent.pid"; while [ ! -f "$1/helper.pid" ]; do sleep 0.01; done; '
					.. (forced and "wait" or "exit 0"),
				"sh",
				dir,
			}, {
				timeout_ms = forced and 10000 or 2000,
				kill_grace_ms = 30,
				on_terminate = function(_, _, raw)
					timed_out = raw.timed_out == true
				end,
			}, function()
				calls = calls + 1
			end)
			local pid = handle.process.pid
			---@diagnostic disable-next-line: duplicate-set-field
			vim.uv.kill = function(target, signal)
				if target == -pid and signal ~= 0 then
					signals[#signals + 1] = signal
				end
				return kill(target, signal)
			end
			ctx.wait_for(function()
				return p.pid(dir .. "/helper.pid") ~= nil
			end, "escaped pipe holder not ready")
			if not kill(-assert(p.pid(dir .. "/helper.pid")), 0) then
				error({ lazyvcs_skip = "Pipe holder did not lead its own process group" })
			end
			if forced then
				handle:cancel("test")
				ctx.wait_for(function()
					return vim.tbl_contains(signals, 9)
				end, "force signal missing")
			else
				ctx.wait_for(function()
					return handle.process:is_closing() and not kill(-pid, 0)
				end, "leader or original group still alive")
				ctx.wait_for(function()
					return calls == 1
				end, "exited process did not settle at its deadline")
				assert(not timed_out, "exited process reported a timeout")
				assert(#signals == 0, "timeout signalled an empty group")
			end
			ctx.wait_for(function()
				return calls == 1
			end, "held pipes retained the worker")
			assert(p.alive(p.pid(dir .. "/helper.pid")), "escaped helper was killed")
			local count = #signals
			-- Pretend the now-free group id has been reused after the first observation.
			---@diagnostic disable-next-line: duplicate-set-field
			vim.uv.kill = function(target, signal)
				if target == -pid then
					if signal ~= 0 then
						signals[#signals + 1] = signal
					end
					return true
				end
				return kill(target, signal)
			end
			handle:shutdown()
			handle:force()
			vim.wait(80)
			assert(#signals == count, "shutdown, force or timer signalled a retired group id")
		end)
		vim.uv.kill = kill
		if handle then
			handle:close_timers()
		end
		assert(ok, err)
	end
	return {
		{
			"test_core_process_guarded_kills_only_live_recorded_pids",
			function()
				local pids, alive, kill = p.pids, p.alive, vim.uv.kill
				local killed = {}
				---@diagnostic disable-next-line: duplicate-set-field
				p.pids = function()
					return { 101, 102 }
				end
				---@diagnostic disable-next-line: duplicate-set-field
				p.alive = function(pid)
					return pid == 102
				end
				vim.uv.kill = function(pid, signal)
					assert(signal == 9)
					killed[#killed + 1] = pid
					return true
				end
				local ok, err = pcall(p.guarded, "/unused", function() end)
				p.pids, p.alive, vim.uv.kill = pids, alive, kill
				assert(ok, err)
				assert(vim.deep_equal(killed, { 102 }), "cleanup signalled a dead recorded pid")
			end,
		},
		{
			"test_core_process_force_never_retargets_group_with_escaped_pipes",
			function()
				held_pipe_case(true)
			end,
		},
		{
			"test_core_process_timeout_never_targets_empty_group_with_escaped_pipes",
			function()
				held_pipe_case(false)
			end,
		},
		{
			"test_source_control_process_timeout_kills_tree_and_recovers_queue",
			function()
				queue_case(false)
			end,
		},
		{
			"test_source_control_process_cancel_kills_tree_and_recovers_queue",
			function()
				queue_case(true)
			end,
		},
		{
			"test_core_process_cancel_reaches_descendant_after_parent_and_pipes_close",
			function()
				posix()
				local dir = h.tempdir()
				p.guarded(dir, function()
					local calls = 0
					local handle = assert(util.system_start(p.tree(dir, true), { kill_grace_ms = 300 }, function()
						calls = calls + 1
					end))
					ctx.wait_for(function()
						return p.ready(dir)
					end, "tree not ready")
					handle:cancel("test")
					handle:cancel("again")
					ctx.wait_for(function()
						return not p.alive(p.pid(dir .. "/parent.pid"))
					end, "parent survived TERM")
					assert(p.alive(p.pid(dir .. "/child.pid")), "fixture did not ignore TERM")
					ctx.wait_for(function()
						return p.dead(dir) and calls == 1
					end, "descendant survived after parent and pipes closed")
					vim.wait(100)
					assert(calls == 1, "physical completion repeated")
				end)
			end,
		},
		{
			"test_core_process_git_credentials_fail_without_terminal_prompt",
			function()
				posix()
				local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
				local dir = h.tempdir()
				local code
				local job = vim.fn.jobstart({
					vim.v.progpath,
					"--headless",
					"-u",
					"NONE",
					"-i",
					"NONE",
					"-l",
					root .. "/tests/fixtures/process_prompt.lua",
					root,
					dir .. "/result.json",
				}, {
					pty = true,
					on_exit = function(_, status)
						code = status
					end,
				})
				assert(job > 0, "PTY editor did not start")
				local exited = vim.wait(7000, function()
					return code ~= nil
				end, 10)
				if not exited then
					vim.fn.jobstop(job)
				end
				assert(exited and code == 0, "credential probe editor failed")
				local raw = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/result.json"), "\n"))
				assert(not raw.timed_out and raw.elapsed_ms < 1000, "Git waited for terminal credentials until timeout")
				assert(
					raw.code ~= 0 and raw.stderr:find("terminal prompts disabled", 1, true),
					"Git did not report disabled prompts"
				)
			end,
		},
		{
			"test_core_process_windows_cancel_releases_worker_with_inherited_pipes",
			function()
				local jobs = require("lazyvcs.source_control.jobs")
				local dir, has = h.tempdir(), vim.fn.has
				local handle, recovered
				-- Detach only the helper: libuv kills non-detached Windows children
				-- when their spawning process exits. Keep the inherited output handles.
				h.write_file(
					dir .. "/helper.lua",
					[[
vim.fn.writefile({ tostring(vim.uv.os_getpid()) }, arg[1])
vim.wait(60000, function() return false end, 100)
vim.cmd("qa!")
]]
				)
				h.write_file(
					dir .. "/leader.lua",
					[[
local child = assert(vim.uv.spawn(vim.v.progpath, {
  args = { "--headless", "-u", "NONE", "-i", "NONE", "-l", arg[1], arg[2] },
  stdio = { nil, 1, 2 },
  detached = true,
}, function() end))
child:unref()
assert(vim.wait(5000, function() return vim.fn.filereadable(arg[2]) == 1 end, 10))
vim.cmd("qa!")
]]
				)
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				local ok, err = pcall(p.guarded, dir, function()
					local repo = { root = dir, vcs = "svn" }
					local id = jobs.command(repo, "buffer", {
						vim.v.progpath,
						"--headless",
						"-u",
						"NONE",
						"-i",
						"NONE",
						"-l",
						dir .. "/leader.lua",
						dir .. "/helper.lua",
						dir .. "/helper.pid",
					}, {
						kill_grace_ms = 20,
						start = function(args, opts, done)
							handle = util.system_start(args, opts, done)
							return handle
						end,
					})
					ctx.wait_for(function()
						return p.pid(dir .. "/helper.pid") and handle.process:is_closing()
					end, "leader did not exit with inherited pipes open")
					jobs.command(repo, "buffer", { "probe" }, {
						start = function(_, _, done)
							recovered = true
							done({ code = 0, stdout = "", stderr = "" })
							return {}
						end,
					})
					vim.wait(100)
					assert(p.alive(p.pid(dir .. "/helper.pid")), "pipe holder died with its parent")
					assert(not recovered, "fixture did not keep inherited pipes open before cancellation")
					jobs.cancel(function(job)
						return job.id == id
					end)
					ctx.wait_for(function()
						return recovered
					end, "exited Windows parent held worker through inherited pipes")
					assert(p.alive(p.pid(dir .. "/helper.pid")), "fixture did not keep inherited pipes open")
				end)
				vim.fn.has = has
				-- Reap the fixture even on the failing-before path.
				vim.wait(1000, function()
					return recovered
				end, 10)
				assert(ok, err)
			end,
		},
		{
			"test_core_process_windows_remote_cancellation_owns_command_tree",
			function()
				windows_cancel_commands({
					{
						label = "remote svn status -u",
						args = { "svn", "status", "--xml", "--ignore-externals", "-u", "target" },
						kind = "remote",
						tree = true,
					},
					{
						label = "remote git fetch",
						args = { "git", "fetch", "--all", "--prune", "--quiet" },
						kind = "remote",
						tree = true,
					},
					{ label = "remote scope", args = { "transport" }, kind = "remote", tree = true },
					{
						label = "svn status -u without scope",
						args = { "svn", "status", "--xml", "-u", "target" },
						tree = true,
					},
					{
						label = "svn status --show-updates before subcommand",
						args = { "svn", "--show-updates", "status", "--xml", "target" },
						tree = true,
					},
					{
						label = "svn status --show-updates after target",
						args = { "svn", "status", "--xml", "target", "--show-updates" },
						tree = true,
					},
					{ label = "local svn status", args = { "svn", "status", "--xml" }, kind = "summary" },
				})
			end,
		},
		{
			"test_core_process_windows_cancel_tree_command_rules",
			function()
				local commands = {
					{ label = "git remote listing", args = { "git", "remote" } },
					{
						label = "git UTF-8 commit",
						args = { "git", "-c", "i18n.commitEncoding=UTF-8", "commit", "-F", "message" },
						tree = true,
					},
					{ label = "git publish is not a subcommand", args = { "git", "publish" } },
					{ label = "git switch", args = { "git", "switch", "branch" } },
					{ label = "git merge", args = { "git", "merge", "branch" } },
					{ label = "git URL read", args = { "git", "show", "https://example.invalid/repo" } },
					{ label = "svn read with -u", args = { "svn", "info", "-u", "target" } },
					{ label = "mutation scope", args = { "custom-command" }, scope = "mutation", tree = true },
					{
						label = "git remote update",
						args = { "git", "-C", "repo", "remote", "update", "--prune" },
						tree = true,
					},
				}
				for _, verb in ipairs({ "fetch", "pull", "push", "clone", "ls-remote", "commit" }) do
					commands[#commands + 1] = { label = "git " .. verb, args = { "git", verb }, tree = true }
				end
				for _, verb in ipairs({
					"checkout",
					"co",
					"update",
					"up",
					"switch",
					"sw",
					"merge",
					"commit",
					"ci",
					"import",
				}) do
					commands[#commands + 1] =
						{ label = "svn " .. verb, args = { "svn", "--non-interactive", verb, "target" }, tree = true }
				end
				for _, verb in ipairs({ "log", "blame" }) do
					commands[#commands + 1] = { label = "svn " .. verb, args = { "svn", verb, "target" } }
				end
				for _, verb in ipairs({ "info", "ls", "log", "blame", "cat", "diff" }) do
					commands[#commands + 1] = {
						label = "svn URL " .. verb,
						args = { "svn", verb, "svn+ssh://example.invalid/repo@42" },
					}
				end
				commands[#commands + 1] = {
					label = "svn info --xml URL",
					args = { "svn", "info", "--xml", "https://example.invalid/repo" },
				}
				windows_cancel_commands(commands)
			end,
		},
		{
			"test_core_process_cancel_tree_invalid_executable_does_not_throw",
			function()
				local commands = {}
				for _, args in ipairs({ {}, { false }, { 123 }, { {} }, { "" }, { "/" }, { "C:\\" } }) do
					for _, scope in ipairs({ "buffer", "remote", "mutation" }) do
						commands[#commands + 1] =
							{ label = vim.inspect(args) .. " " .. scope, args = args, scope = scope }
					end
				end
				windows_cancel_commands(commands)
			end,
		},
		{
			"test_core_process_windows_superseded_reads_do_not_spawn_taskkill",
			function()
				local jobs = require("lazyvcs.source_control.jobs")
				local original, has = vim.system, vim.fn.has
				local taskkills, spawned, exits = 0, 0, {}
				local owner = {}
				local repo = { root = h.tempdir(), vcs = "svn" }
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				vim.system = function(args, _, cb)
					if args[1] == "taskkill" then
						taskkills = taskkills + 1
						vim.schedule(function()
							cb({ code = 0 })
						end)
						return {}
					end
					spawned = spawned + 1
					exits[#exits + 1] = cb
					local closing = false
					return {
						pid = 12345,
						is_closing = function()
							return closing
						end,
						kill = function()
							if not closing then
								closing = true
								vim.schedule(function()
									cb({ code = 1, stdout = "", stderr = "" })
								end)
							end
						end,
					}
				end
				local ok, err = xpcall(function()
					local reads = {
						{ "git", "status", "--short" },
						{ "git", "diff", "--", "commit" },
						{ "git", "log", "-1" },
						{ "svn", "info", "--xml" },
						{ "svn", "cat", "-r", "BASE", "file" },
						{ "svn", "cat", "svn+ssh://example.invalid/repo/file@42" },
						{ "svn", "info", "--xml", "https://example.invalid/repo" },
						{ "svn", "log", "target" },
						{ "svn", "blame", "target" },
					}
					for generation = 1, 20 do
						jobs.command(repo, "buffer", reads[(generation - 1) % #reads + 1], {
							owner = owner,
							scope = "signs",
							generation = generation,
						})
						ctx.wait_for(function()
							return spawned == generation
						end, "superseded read held worker")
					end
					jobs.cancel_owner(owner)
					vim.wait(50)
					assert(taskkills == 0, "superseded reads spawned taskkill: " .. taskkills)
				end, debug.traceback)
				vim.system, vim.fn.has = original, has
				for _, cb in ipairs(exits) do
					cb({ code = 1, stdout = "", stderr = "" })
				end
				vim.wait(50)
				assert(ok, err)
			end,
		},
		{
			"test_core_process_windows_timeout_still_uses_taskkill",
			function()
				-- Guard the timeout upgrade of tree_termination for an otherwise direct read.
				local original, has = vim.system, vim.fn.has
				local exit, taskkill, raw
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				vim.system = function(args, _opts, cb)
					if args[1] == "taskkill" then
						taskkill = args
						vim.schedule(function()
							cb({ code = 0 })
						end)
						return {}
					end
					exit = cb
					return {
						pid = 12345,
						is_closing = function()
							return false
						end,
						kill = function()
							exit({ code = 1, stdout = "", stderr = "" })
						end,
					}
				end
				local ok, err = xpcall(function()
					util.system_start(
						{ "svn", "cat", "svn+ssh://example.invalid/repo/file@42" },
						{ timeout_ms = 20 },
						function(_, _, result)
							raw = result
						end
					)
					ctx.wait_for(function()
						return raw ~= nil
					end, "timeout did not finish")
					assert(raw.timed_out and raw.code == 124, "timeout result lost")
					assert(
						vim.deep_equal(taskkill, { "taskkill", "/T", "/F", "/PID", "12345" }),
						"timed-out read did not terminate descendants"
					)
				end, debug.traceback)
				vim.system, vim.fn.has = original, has
				if exit then
					exit({ code = 1, stdout = "", stderr = "" })
				end
				assert(ok, err)
			end,
		},
		{
			"test_core_process_windows_hung_taskkill_cannot_hold_worker",
			function()
				local jobs = require("lazyvcs.source_control.jobs")
				local original, has = vim.system, vim.fn.has
				local process_exit, helper_opts, helper_timer
				local helper_running, helpers = false, 0
				local early_kill = false
				local killed, recovered = false, false
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				vim.system = function(args, opts, cb)
					if args[1] == "taskkill" then
						helper_opts, helper_running = opts, true
						helpers = helpers + 1
						-- Real vim.system kills a stalled helper at its own deadline.
						helper_timer = vim.defer_fn(function()
							helper_running = false
							cb({ code = 124 })
						end, opts.timeout)
						return {}
					end
					process_exit = cb
					return {
						pid = 12345,
						is_closing = function()
							return false
						end,
						kill = function(_, signal)
							early_kill = early_kill or helper_running
							killed = signal == 9
						end,
					}
				end
				local ok, err = xpcall(function()
					local repo = { root = h.tempdir(), vcs = "svn" }
					jobs.command(repo, "buffer", { "held" }, { timeout_ms = 20, kill_grace_ms = 20 })
					jobs.command(repo, "buffer", { "next" }, {
						start = function(_, _, done)
							recovered = true
							done({ code = 0, stdout = "", stderr = "" })
							return {}
						end,
					})
					ctx.wait_for(function()
						return killed
					end, "hung taskkill prevented forced parent termination", 3500)
					assert(helper_opts.timeout == 2000, "taskkill deadline depends on kill grace")
					assert(helpers == 1, "forced termination started a second tree walk")
					assert(not early_kill, "parent killed before taskkill finished enumerating")
					assert(not recovered, "worker released before process exit")
					process_exit({ code = 1, stdout = "", stderr = "" })
					ctx.wait_for(function()
						return recovered
					end, "Windows cancellation held worker after process exit")
				end, debug.traceback)
				vim.system, vim.fn.has = original, has
				if process_exit then
					process_exit({ code = 1, stdout = "", stderr = "" })
				end
				if helper_timer and not helper_timer:is_closing() then
					helper_timer:stop()
					helper_timer:close()
				end
				assert(ok, err)
			end,
		},
		{
			"test_core_process_windows_owned_and_fallback_cancellation",
			function()
				local original, has = vim.system, vim.fn.has
				local process_exit, taskkill, fail, closing
				local killed = 0
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				vim.system = function(args, opts, cb)
					if args[1] == "taskkill" then
						taskkill = args
						if fail then
							error("taskkill unavailable")
						end
						vim.schedule(function()
							cb({ code = 1 })
						end)
						return {}
					end
					assert(opts.detach == false, "Windows command detached from taskkill parent")
					process_exit = cb
					return {
						pid = 12345,
						is_closing = function()
							return closing
						end,
						kill = function()
							killed = killed + 1
						end,
					}
				end
				local ok, err = pcall(function()
					local commands = {
						{ { "fake" }, { timeout_ms = 20 }, fallback = true },
						{ { "fake" }, { timeout_ms = 20 }, fallback = true, fail = true },
						{ { "fake" }, { scope = "mutation" }, closing = true },
						{ { "git", "fetch" } },
						{ { "git", "pull" } },
						{ { "git", "push" } },
						{ { "git", "commit" } },
						{ { "C:\\Git\\git.exe", "-C", "repo", "-c", "key=value", "fetch" } },
						{ { "svn", "--non-interactive", "commit" } },
						{ { "svn", "cat", "https://example.invalid/repo/file" }, direct = true },
					}
					for _, command in ipairs(commands) do
						taskkill, fail, closing = nil, command.fail, command.closing
						local expected_kills = killed + (closing and 0 or 1)
						local calls = 0
						local handle = assert(util.system_start(command[1], command[2], function()
							calls = calls + 1
						end))
						if command.fallback then
							vim.wait(40)
						else
							handle:cancel("test")
						end
						if closing or not command.fallback then
							assert(taskkill == nil, "taskkill targeted an exited parent or routine read")
						else
							assert(
								vim.deep_equal(taskkill, { "taskkill", "/T", "/F", "/PID", "12345" }),
								"Windows descendants did not receive taskkill"
							)
						end
						ctx.wait_for(function()
							return killed == expected_kills
						end, "parent termination fallback missing")
						process_exit({ code = 1, stdout = "", stderr = "" })
						ctx.wait_for(function()
							return calls == 1
						end, "Windows completion missing")
					end
				end)
				vim.system, vim.fn.has = original, has
				if process_exit then
					process_exit({ code = 1, stdout = "", stderr = "" })
				end
				assert(ok, err)
			end,
		},
		{
			"test_core_process_windows_shutdown_forces_parent_during_taskkill",
			function()
				local runtime = require("lazyvcs.process_runtime")
				local original, has, is_shutdown = vim.system, vim.fn.has, runtime.is_shutting_down
				local shutdown, exit, helper_exit, killed, handle
				local helpers = 0
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				runtime.is_shutting_down = function()
					return shutdown == true
				end
				vim.system = function(args, _, cb)
					if args[1] == "taskkill" then
						helpers = helpers + 1
						helper_exit = cb
						return {}
					end
					exit = cb
					return {
						pid = 12345,
						is_closing = function()
							return false
						end,
						kill = function(_, signal)
							killed = signal
						end,
					}
				end
				local ok, err = xpcall(function()
					handle = util.system_start({ "git", "status" }, {})
					shutdown = true
					handle:shutdown()
					assert(helper_exit and not killed, "shutdown did not allow initial tree walk")
					handle:force()
					assert(killed == 9, "shutdown waited for taskkill past its global deadline")
					assert(helpers == 1, "shutdown started a second tree walk")
				end, debug.traceback)
				vim.system, vim.fn.has, runtime.is_shutting_down = original, has, is_shutdown
				if exit then
					exit({ code = 1, stdout = "", stderr = "" })
				end
				if helper_exit then
					helper_exit({ code = 124 })
				end
				if handle then
					handle:close_timers()
				end
				assert(ok, err)
			end,
		},
		{
			"test_core_process_windows_reap_tolerates_invalid_pipe_handles",
			function()
				local original, has = vim.system, vim.fn.has
				local exit, handle
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				vim.system = function(_, _, cb)
					exit = cb
					return {
						pid = 12345,
						is_closing = function()
							return true
						end,
						kill = function() end,
						_state = {
							stdout = {},
							stderr = {
								is_closing = function()
									error("invalid pipe")
								end,
							},
						},
					}
				end
				local ok, err = xpcall(function()
					handle = util.system_start({ "git", "status" }, {})
					handle:cancel("test")
					handle:force()
				end, debug.traceback)
				vim.system, vim.fn.has = original, has
				if exit then
					exit({ code = 1, stdout = "", stderr = "" })
				end
				if handle then
					handle:close_timers()
				end
				assert(ok, err)
			end,
		},
		{
			"test_core_process_windows_kill_reaches_handles_without_closing_state",
			function()
				local original, has = vim.system, vim.fn.has
				local exit, handle
				local signals = {}
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				-- A handle that cannot report whether it is closing must still be killed.
				vim.system = function(_, _, cb)
					exit = cb
					return {
						kill = function(_, signal)
							signals[#signals + 1] = signal
						end,
					}
				end
				local ok, err = xpcall(function()
					handle = util.system_start({ "git", "status" }, { kill_grace_ms = 100 })
					assert(handle:kill(15))
					assert(vim.deep_equal(signals, { 15 }), "cancellation did not signal the process")
				end, debug.traceback)
				vim.system, vim.fn.has = original, has
				if exit then
					exit({ code = 143, signal = 15, stdout = "", stderr = "" })
				end
				if handle then
					handle:close_timers()
				end
				assert(ok, err)
			end,
		},
		{
			"test_core_process_command_options_disable_prompts",
			function()
				local original = vim.system
				local captured = {}
				local function env_value(env, key)
					if env[key] then
						return env[key]
					end
					for _, entry in ipairs(env) do
						if entry:sub(1, #key + 1) == key .. "=" then
							return entry:sub(#key + 2)
						end
					end
				end
				vim.system = function(args, opts, cb)
					captured[#captured + 1] = { args = vim.deepcopy(args), opts = opts }
					local result = { code = 0, stdout = "", stderr = "" }
					if cb then
						vim.schedule(function()
							cb(result)
						end)
					end
					return {
						wait = function()
							return result
						end,
						kill = function() end,
					}
				end
				local ok, err = pcall(function()
					local args = { "svn", "commit", "-F", "private-message", "--", "file@" }
					util.system_result(args)
					assert(captured[1].args[2] == "--non-interactive", "SVN prompts remain enabled")
					assert(captured[1].args[5] == "private-message", "SVN -F value shifted incorrectly")
					assert(args[2] == "commit", "caller argv mutated")
					util.system_result({ "svn", "info", "--non-interactive", "file@" })
					assert(#captured[2].args == 4, "duplicate non-interactive flag")
					util.system_start({ "git", "status" }, { env = { CUSTOM = "yes" } }, function() end)
					assert(
						env_value(captured[3].opts.env, "GIT_TERMINAL_PROMPT") == "0",
						"Git terminal prompts remain enabled"
					)
					assert(env_value(captured[3].opts.env, "CUSTOM") == "yes")
					assert(env_value(captured[3].opts.env, "GIT_OPTIONAL_LOCKS") == "0")
					util.system_result(
						{ "git", "status" },
						{ env = { GIT_TERMINAL_PROMPT = "1", GIT_OPTIONAL_LOCKS = "1" } }
					)
					assert(
						env_value(captured[4].opts.env, "GIT_TERMINAL_PROMPT") == "1",
						"explicit environment overridden"
					)
					assert(env_value(captured[4].opts.env, "GIT_OPTIONAL_LOCKS") == "1")
				end)
				vim.system = original
				vim.wait(20)
				assert(ok, err)
			end,
		},
	}
end
