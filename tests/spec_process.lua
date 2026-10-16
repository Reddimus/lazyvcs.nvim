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
	return {
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
