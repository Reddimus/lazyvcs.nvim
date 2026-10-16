return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local util = require("lazyvcs.util")
	local ai = require("lazyvcs.source_control.ai")
	local function guarded(fn)
		return function()
			local start = util.system_start
			ai._test_reset_privacy()
			ai._test_set_executable_checker(function()
				return true
			end)
			local ok, err = xpcall(fn, debug.traceback)
			util.system_start = start
			ai._test_reset_privacy()
			assert(ok, err)
		end
	end
	local function setup(context)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			ai = {
				commit_message = {
					provider = "codex",
					confirm_privacy = false,
					context = context or "staged_first",
				},
			},
		})
	end
	local function scheduler(vcs)
		local jobs = require("lazyvcs.source_control.jobs")
		for _, context in ipairs({ "staged_first", "all" }) do
			setup(context)
			require("lazyvcs.config").get().source_control.background.git_workers = 1
			require("lazyvcs.config").get().source_control.background.svn_workers = 1
			local started, requests, owner, callbacks = {}, {}, {}, 0
			local repo = { root = h.tempdir(), vcs = vcs }
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, _, done)
				assert(args[1] == vcs, "provider should not start before context")
				started[#started + 1] = done
				return {
					kill = function()
						done(nil, "cancelled", { code = 130, cancelled = true })
					end,
				}
			end
			local ok, err = xpcall(function()
				for _ = 1, 6 do
					requests[#requests + 1] = ai.generate(repo, function()
						callbacks = callbacks + 1
					end, { owner = owner })
				end
				assert(#started == 1, "AI context bypassed scheduler worker limit: " .. #started)
				assert(jobs.cancel_owner(owner) == 6, "context commands lack repository ownership")
				assert(callbacks == 6, "cancelled context requests did not complete")
			end, debug.traceback)
			for _, request in ipairs(requests) do
				request:cancel()
			end
			jobs.cancel_owner(owner)
			assert(ok, err)
		end
	end
	return {
		{
			"test_ai_codex_approval_option_is_global",
			guarded(function()
				setup()
				local argv, prompt, completed
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "git" then
						done({ code = 0, stdout = "staged change", stderr = "" })
					else
						argv, prompt = args, opts.stdin
						done({ code = 0, stdout = "Summarize staged change", stderr = "" })
					end
					return {}
				end
				ai.generate({ root = h.tempdir(), vcs = "git" }, function(message)
					assert(message == "Summarize staged change")
					completed = true
				end)
				wait(function()
					return completed
				end)
				assert(
					vim.deep_equal(argv, {
						"codex",
						"--ask-for-approval",
						"never",
						"exec",
						"--skip-git-repo-check",
						"--ephemeral",
						"--sandbox",
						"read-only",
						"-",
					}),
					"Codex approval option is not global"
				)
				assert(prompt:find("staged change", 1, true), "context was not passed over stdin")
			end),
		},
		{
			"test_ai_context_errors_stop_fallback",
			guarded(function()
				setup()
				for _, context in ipairs({ "staged_first", "all" }) do
					setup(context)
					local calls, completed, failure = 0, 0, nil
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(_, _, done)
						calls = calls + 1
						done(
							nil,
							"staged diff failed",
							{ code = 1, stdout = "partial private content", stderr = "failed" }
						)
						return {}
					end
					ai.generate({ root = h.tempdir(), vcs = "git" }, function(_, err)
						completed, failure = completed + 1, err
					end)
					wait(function()
						return completed > 0
					end)
					assert(
						calls == 1 and completed == 1 and failure == "staged diff failed",
						"context failure fell through to other changes: " .. tostring(failure)
					)
				end
				setup()
				local calls, completed = 0, false
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					calls = calls + 1
					if calls == 1 then
						done({ code = 0, stdout = "", stderr = "" })
					elseif args[1] == "git" then
						done({ code = 0, stdout = "unstaged control", stderr = "" })
					else
						assert(opts.stdin:find("unstaged control", 1, true))
						done({ code = 0, stdout = "Control", stderr = "" })
					end
					return {}
				end
				ai.generate({ root = h.tempdir(), vcs = "git" }, function(message)
					completed = message == "Control"
				end)
				wait(function()
					return completed
				end)
				assert(calls == 3, "successful empty context must fall back")
			end),
		},
		{
			"test_ai_context_rejects_truncated_fallback",
			guarded(function()
				setup()
				local failure, calls, completed = nil, 0, false
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(_, _, done)
					calls = calls + 1
					done({ code = 0, stdout = "partial context", stdout_truncated = true })
					return {}
				end
				ai.generate({ root = h.tempdir(), vcs = "git" }, function(_, err)
					failure, completed = err, true
				end)
				wait(function()
					return completed
				end)
				assert(
					calls == 1 and failure and failure:find("output limit", 1, true),
					"truncated context reached provider"
				)
			end),
		},
		{
			"test_svn_ai_status_context_accepts_at_paths",
			guarded(function()
				local f = h.make_svn_fixture()
				local root = util.normalize_literal_path(f.root .. "@copy")
				assert(vim.uv.fs_rename(f.root, root))
				local start, prompts = util.system_start, {}
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "svn" then
						return start(args, opts, done)
					end
					prompts[#prompts + 1] = opts.stdin
					done({ code = 0, stdout = "Summarize changes", stderr = "" })
					return {}
				end
				for _, context in ipairs({ "status", "staged_first", "all", "staged_first" }) do
					if #prompts == 3 then
						h.exec({ "svn", "revert", "sample.txt" }, root)
						h.write_file(root .. "/untracked.txt", "untracked\n")
					end
					setup(context)
					local finished, failure
					ai.generate({ root = root, vcs = "svn" }, function(message, err)
						finished, failure = message or false, err
					end)
					wait(function()
						return finished ~= nil
					end, "SVN context did not complete", 15000)
					assert(finished, failure)
					assert(prompts[#prompts]:find(#prompts == 4 and "untracked.txt" or "sample.txt", 1, true))
				end
			end),
		},
		{ "test_ai_context_scheduler_bounds_collectors", guarded(function()
			scheduler("git")
		end) },
		{ "test_svn_ai_context_scheduler_bounds_collectors", guarded(function()
			scheduler("svn")
		end) },
		{
			"test_source_control_ai_cancellation_reaches_context_and_provider",
			guarded(function()
				if vim.env.LAZYVCS_AI_CONTEXT_CHILD ~= "1" then
					local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
					local result = vim.system(
						{ vim.v.progpath, "--headless", "-u", "NONE", "-l", root .. "/tests/run.lua" },
						{
							text = true,
							env = {
								LAZYVCS_TEST_GROUP = "source_control",
								LAZYVCS_TEST_CASE = "test_source_control_ai_cancellation_reaches_context_and_provider",
								LAZYVCS_AI_CONTEXT_CHILD = "1",
							},
						}
					)
						:wait()
					assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
					return
				end
				setup()
				require("lazyvcs.config").get().source_control.background.git_workers = 1
				local ops = require("lazyvcs.source_control.ops")
				local root = h.tempdir()
				local repo = { root = root, vcs = "git", name = "repo" }
				local state = {
					path = root,
					lazyvcs_commit_drafts = {},
					lazyvcs_repo_cache = { [root] = repo },
					lazyvcs_render = function() end,
				}
				local node = { path = root }
				local active, peak, providers, requests = 0, 0, 0, {}
				local notify, notices = util.notify, {}
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(message)
					notices[#notices + 1] = message
				end
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, _, done)
					active = active + 1
					peak = math.max(peak, active)
					if args[1] == "codex" then
						providers = providers + 1
					end
					local request = { active = true }
					function request:complete(message)
						if not self.active then
							return
						end
						self.active = false
						active = active - 1
						done({ code = 0, stdout = message, stderr = "" })
					end
					function request:kill()
						if not self.active then
							return
						end
						self.active = false
						active = active - 1
						done(nil, "cancelled", { code = 130, cancelled = true })
					end
					requests[#requests + 1] = request
					return request
				end
				local ok, err = xpcall(function()
					for _ = 1, 12 do
						ops.generate_commit_message(state, node)
					end
					assert(peak == 1 and active == 1, "repeated generation fanned out context requests")
					requests[#requests]:complete("current staged context")
					assert(providers == 1 and active == 1)
					ops.generate_commit_message(state, node)
					assert(active == 1, "supersession retained provider")
					requests[#requests]:complete("new staged context")
					assert(providers == 2)
					ops.cancel_repo(state, node)
					assert(
						active == 0 and not state.lazyvcs_commit_drafts[root],
						"repository cancellation retained provider work"
					)
					assert(#notices == 1, "obsolete cancellation reported errors")
				end, debug.traceback)
				if ops.cancel_commit_generations then
					ops.cancel_commit_generations(state)
				end
				for _, request in ipairs(requests) do
					request:kill()
				end
				util.notify = notify
				assert(ok, err)
			end),
		},
	}
end
