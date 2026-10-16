return function(ctx)
	local h, p = ctx.helpers, require("process_helpers")
	local util = require("lazyvcs.util")
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
					return timed_out
				end, "timeout did not fire")
				assert(#signals == 0, "timeout signalled an empty group")
			end
			assert(calls == 0 and p.alive(p.pid(dir .. "/helper.pid")), "pipes closed before regression probe")
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
				-- Record native PIDs and inherit the real output handles on Windows
				-- too; an MSYS shell's $! need not be a Windows process ID.
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
			"test_core_process_windows_hung_taskkill_cannot_hold_worker",
			function()
				local jobs = require("lazyvcs.source_control.jobs")
				local original, has = vim.system, vim.fn.has
				local process_exit, helper_opts
				local killed, recovered = false, false
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(name)
					return name == "win32" and 1 or has(name)
				end
				vim.system = function(args, opts, cb)
					if args[1] == "taskkill" then
						helper_opts = opts
						return {} -- Enumeration never finishes; no helper callback.
					end
					process_exit = cb
					return {
						pid = 12345,
						is_closing = function()
							return false
						end,
						kill = function(_, signal)
							killed = signal == 9
						end,
					}
				end
				local ok, err = xpcall(function()
					local repo = { root = h.tempdir(), vcs = "svn" }
					local id = jobs.command(repo, "buffer", { "held" }, { kill_grace_ms = 20 })
					jobs.command(repo, "buffer", { "next" }, {
						start = function(_, _, done)
							recovered = true
							done({ code = 0, stdout = "", stderr = "" })
							return {}
						end,
					})
					jobs.cancel(function(job)
						return job.id == id
					end)
					ctx.wait_for(function()
						return killed
					end, "hung taskkill prevented forced parent termination")
					assert(helper_opts.timeout and helper_opts.timeout > 0, "taskkill has no deadline")
					assert(not recovered, "worker released before process exit")
				end, debug.traceback)
				if process_exit then
					process_exit({ code = 1, stdout = "", stderr = "" })
					ctx.wait_for(function()
						return recovered
					end, "Windows cancellation held worker after process exit")
				end
				vim.system, vim.fn.has = original, has
				assert(ok, err)
			end,
		},
		{
			"test_core_process_windows_taskkill_and_parent_fallback",
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
					for mode = 1, 3 do
						taskkill, fail, closing = nil, mode == 2, mode == 3
						local calls = 0
						local handle = assert(util.system_start({ "fake" }, {}, function()
							calls = calls + 1
						end))
						handle:cancel("test")
						if closing then
							assert(taskkill == nil, "taskkill targeted an exited parent")
						else
							assert(
								vim.deep_equal(taskkill, { "taskkill", "/T", "/F", "/PID", "12345" }),
								"Windows descendants did not receive taskkill"
							)
						end
						ctx.wait_for(function()
							return killed == mode
						end, "parent termination fallback missing")
						process_exit({ code = 1, stdout = "", stderr = "" })
						ctx.wait_for(function()
							return calls == 1
						end, "Windows completion missing")
					end
				end)
				vim.system, vim.fn.has = original, has
				assert(ok, err)
			end,
		},
		{
			"test_core_process_command_options_disable_prompts",
			function()
				local original = vim.system
				local captured = {}
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
					assert(captured[3].opts.env.GIT_TERMINAL_PROMPT == "0", "Git terminal prompts remain enabled")
					assert(captured[3].opts.env.CUSTOM == "yes")
					util.system_result({ "git", "status" }, { env = { GIT_TERMINAL_PROMPT = "1" } })
					assert(captured[4].opts.env.GIT_TERMINAL_PROMPT == "1", "explicit environment overridden")
				end)
				vim.system = original
				vim.wait(20)
				assert(ok, err)
			end,
		},
	}
end
