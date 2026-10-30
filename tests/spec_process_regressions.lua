return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local util = require("lazyvcs.util")
	local ai = require("lazyvcs.source_control.ai")
	local function guarded(fn)
		return function()
			local system, start, rtp = vim.system, util.system_start, vim.o.runtimepath
			local chat, lazy = package.loaded.CopilotChat, package.loaded["lazy.core.config"]
			local ok, err = xpcall(fn, debug.traceback)
			vim.system, util.system_start, vim.o.runtimepath = system, start, rtp
			package.loaded.CopilotChat, package.loaded["lazy.core.config"] = chat, lazy
			ai._test_reset_privacy()
			assert(ok, err)
		end
	end
	local function setup(context)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { confirm_mutations = false, remote_refresh = "manual" },
			ai = { commit_message = { provider = "codex", confirm_privacy = false, context = context } },
		})
		ai._test_set_executable_checker(function()
			return true
		end)
	end
	return {
		{
			"test_core_process_termination_is_failure",
			guarded(function()
				local system = vim.system
				for _, signal in ipairs({ 0, 15, 9 }) do
					vim.system = function(_, _, cb)
						local raw = { code = 0, signal = signal, stdout = "partial", stderr = "" }
						if cb then
							vim.schedule(function()
								cb(raw)
							end)
						end
						return {
							wait = function()
								return raw
							end,
						}
					end
					local result, err = util.system({ "fixture" })
					assert((result ~= nil) == (signal == 0), "synchronous signal counted as success")
					if signal ~= 0 then
						assert(err and err:find(tostring(signal), 1, true))
					end
					local done, value, failure, raw
					util.system_start({ "fixture" }, {}, function(v, e, r)
						done, value, failure, raw = true, v, e, r
					end)
					wait(function()
						return done
					end)
					assert((value ~= nil) == (signal == 0), "asynchronous signal counted as success")
					assert(raw.signal == signal and raw.code == 0)
					if signal ~= 0 then
						assert(failure and failure:find(tostring(signal), 1, true))
					end
				end
				vim.system = system
			end),
		},
		{
			"test_source_control_termination_custom_starter_is_failure",
			guarded(function()
				setup("staged")
				local jobs = require("lazyvcs.source_control.jobs")
				local repo = { root = h.tempdir(), vcs = "git" }
				local done, value, failure, raw
				jobs.command(repo, "signal_probe", { "fixture" }, {
					start = function(_, _, cb)
						cb({ code = 0, signal = 15, stdout = "", stderr = "" }, "")
						return {}
					end,
				}, function(v, e, r)
					done, value, failure, raw = true, v, e, r
				end)
				wait(function()
					return done
				end)
				assert(not value and failure and failure:find("15", 1, true), "scheduler accepted signalled result")
				assert(raw.signal == 15)
				local failed = false
				for _, job in ipairs(jobs.history()) do
					if job.root == repo.root and job.kind == "signal_probe" then
						failed = job.status == "error"
					end
				end
				assert(failed, "scheduler did not record signal error")
			end),
		},
		{
			"test_source_control_termination_commit_preserves_draft",
			guarded(function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX signal hook" }, 0)
				end
				setup("staged")
				for _, signal in ipairs({ "TERM", "KILL" }) do
					local f = h.make_git_fixture()
					h.exec({ "git", "add", "sample.txt" }, f.root)
					local head = h.exec({ "git", "rev-parse", "HEAD" }, f.root)
					h.write_file(f.root .. "/.git/hooks/pre-commit", "#!/bin/sh\nkill -" .. signal .. ' "$PPID"\n')
					assert(vim.uv.fs_chmod(f.root .. "/.git/hooks/pre-commit", 448))
					local state = {
						path = f.root,
						lazyvcs_commit_drafts = { [f.root] = "Keep my draft" },
						lazyvcs_repo_cache = {
							[f.root] = {
								root = f.root,
								vcs = "git",
								name = "fixture",
								counts = { staged = 1, local_changes = 1 },
							},
						},
						lazyvcs_render = function() end,
					}
					require("lazyvcs.source_control.ops").commit_repo(state, { path = f.root })
					wait(function()
						local history = require("lazyvcs.source_control.jobs").history()
						for _, job in ipairs(history) do
							if job.kind == "git_commit" and job.root == f.root then
								return true
							end
						end
					end, "commit did not settle", 15000)
					assert(state.lazyvcs_commit_drafts[f.root] == "Keep my draft", "signal cleared uncommitted draft")
					assert(h.exec({ "git", "rev-parse", "HEAD" }, f.root) == head)
					assert(h.exec({ "git", "diff", "--cached", "--name-only" }, f.root) == "sample.txt\n")
				end
			end),
		},
		{
			"test_core_ai_termination_rejects_partial_provider_output",
			guarded(function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX signal child" }, 0)
				end
				setup("staged")
				local system = vim.system
				vim.system = function(args, opts, cb)
					if args[1] == "codex" then
						return system({ "sh", "-c", "printf 'Incomplete subject'; kill -TERM $$" }, opts, cb)
					end
					return system(args, opts, cb)
				end
				local f = h.make_git_fixture()
				h.exec({ "git", "add", "sample.txt" }, f.root)
				local done, message, failure
				ai.generate({ root = f.root, vcs = "git" }, function(m, e)
					done, message, failure = true, m, e
				end)
				wait(function()
					return done
				end, "provider did not settle", 15000)
				assert(not message and failure and failure:find("15", 1, true), "provider accepted partial output")
			end),
		},
		{
			"test_core_git_pathspec_environment_is_literal",
			guarded(function()
				local f = h.make_git_fixture()
				local saved = {}
				local keys = { "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS" }
				for _, key in ipairs(keys) do
					saved[key] = vim.env[key]
				end
				local ok, err = xpcall(function()
					for _, key in ipairs(keys) do
						vim.env[key] = "1"
						local args = { "git", "ls-files", "--", "sample.txt" }
						local value, failure = util.system(args, { cwd = f.root })
						assert(value and value.stdout == "sample.txt\n", failure)
						local done, result, error_message
						util.system_start(args, { cwd = f.root }, function(v, e)
							done, result, error_message = true, v, e
						end)
						wait(function()
							return done
						end)
						assert(result and result.stdout == "sample.txt\n", error_message)
						assert(vim.env[key] == "1", "editor environment changed")
						vim.env[key] = nil
					end
				end, debug.traceback)
				for _, key in ipairs(keys) do
					vim.env[key] = saved[key]
				end
				assert(ok, err)
			end),
		},
		{
			"test_core_ai_discovers_native_copilotchat_without_loading",
			guarded(function()
				setup("staged")
				require("lazyvcs.config").get().ai.commit_message.provider = "copilotchat"
				package.loaded.CopilotChat = nil
				package.loaded["lazy.core.config"] = { plugins = {} }
				for _, name in ipairs({ "CopilotChat.lua", "CopilotChat/init.lua" }) do
					local dir = h.tempdir()
					vim.fn.mkdir(dir .. "/lua/CopilotChat", "p")
					h.write_file(dir .. "/lua/" .. name, "error('discovery must not load the module')")
					vim.opt.runtimepath:prepend(dir)
					assert(ai.available(), "runtimepath provider not discovered: " .. name)
					assert(not package.loaded.CopilotChat)
					vim.opt.runtimepath:remove(dir)
				end
			end),
		},
		{
			"test_core_ai_context_ignores_external_diff_and_color",
			guarded(function()
				local start = util.system_start
				for _, context in ipairs({ "staged", "unstaged", "staged_first" }) do
					setup(context)
					local f = h.make_git_fixture()
					local helper = h.tempdir() .. "/empty-diff.lua"
					h.write_file(helper, "vim.cmd('qa!')")
					h.exec({
						"git",
						"config",
						"diff.external",
						'"' .. vim.v.progpath:gsub("\\", "/") .. '" --headless -u NONE -i NONE -l "' .. helper .. '"',
					}, f.root)
					h.exec({ "git", "config", "color.ui", "always" }, f.root)
					if context ~= "unstaged" then
						h.exec({ "git", "add", "sample.txt" }, f.root)
					end
					local prompt, done, failure
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, cb)
						if args[1] == "git" then
							return start(args, opts, cb)
						end
						prompt = opts.stdin
						cb({ code = 0, stdout = "Subject" })
						return {}
					end
					ai.generate({ root = f.root, vcs = "git" }, function(_, e)
						done, failure = true, e
					end)
					wait(function()
						return done
					end, "context did not settle", 15000)
					assert(not failure, failure)
					assert(prompt and prompt:find("+changed", 1, true), "patch missing for " .. context)
					assert(not prompt:find("\27", 1, true), "ANSI color in context")
				end
			end),
		},
	}
end
