return function(ctx)
	local h, util = ctx.helpers, require("lazyvcs.util")
	local function preflight_case(cancel)
		local starter = require("lazyvcs.source_control.mutation_start")
		local start = util.system_start
		local f = h.make_git_fixture()
		local calls, completions, terminations = 0, 0, 0
		local result
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, cb)
			calls = calls + 1
			assert(args[2] == "symbolic-ref", "mutation started after interrupted preflight")
			return start(
				{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "sleep 10", "-c", "qa!" },
				opts,
				cb
			)
		end
		local ok, err = xpcall(function()
			local handle = starter.start({ root = f.root, vcs = "git" }, { "git", "merge", "--ff-only", "HEAD" }, {
				cwd = f.root,
				timeout = cancel and 10000 or 40,
				kill_grace_ms = 10,
				on_terminate = function()
					terminations = terminations + 1
				end,
			}, { branch_ref = "refs/heads/main" }, function(_, _, raw)
				completions, result = completions + 1, raw
			end)
			if cancel then
				handle:cancel("test")
				handle:cancel("again")
			end
			ctx.wait_for(function()
				return completions > 0
			end, "interrupted preflight did not complete", 15000)
			vim.wait(50)
			assert(
				calls == 1 and completions == 1 and terminations == 1,
				"preflight must terminate and complete exactly once"
			)
			assert(cancel and result.cancelled or not cancel and result.timed_out, "preflight lost interruption status")
		end, debug.traceback)
		util.system_start = start
		assert(ok, err)
	end
	return {
		{
			"test_source_control_mutation_timeout_during_preflight",
			function()
				preflight_case(false)
			end,
		},
		{
			"test_source_control_mutation_cancellation_during_preflight",
			function()
				preflight_case(true)
			end,
		},
		{
			"test_source_control_mutation_preflight_with_all_workers_busy",
			function()
				local starter = require("lazyvcs.source_control.mutation_start")
				local jobs = require("lazyvcs.source_control.jobs")
				require("lazyvcs").setup({ source_control = { background = { git_workers = 2 } } })
				local f = h.make_git_fixture()
				local repo = { root = f.root, vcs = "git" }
				local ref = util.trim(h.exec({ "git", "symbolic-ref", "HEAD" }, f.root))
				local exits, completed, started = {}, 0, false
				for _ = 1, 2 do
					jobs.command(repo, "blocker", { "git", "status" }, {
						start = function(_, _, cb)
							exits[#exits + 1] = cb
							return {}
						end,
					}, function() end)
				end
				jobs.command(repo, "mutation", { "git", "update-ref", "refs/heads/guarded", "HEAD" }, {
					timeout_ms = 5000,
					start = function(args, opts, cb)
						started = true
						return starter.start(repo, args, opts, { branch_ref = ref }, cb)
					end,
				}, function(_, err)
					assert(not err, err)
					completed = completed + 1
				end)
				assert(not started, "mutation must wait for a worker")
				exits[1]({ code = 0, stdout = "", stderr = "" })
				ctx.wait_for(function()
					return completed > 0
				end, "preflight deadlocked with all other workers occupied", 15000)
				assert(completed == 1)
				assert(
					h.exec({ "git", "rev-parse", "guarded" }, f.root) == h.exec({ "git", "rev-parse", "HEAD" }, f.root)
				)
				exits[2]({ code = 0, stdout = "", stderr = "" })
			end,
		},
	}
end
