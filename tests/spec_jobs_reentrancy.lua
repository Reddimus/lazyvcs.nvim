return function(ctx)
	return {
		{
			"test_source_control_jobs_reentrant_supersession_skips_stale_generation",
			function()
				local jobs = require("lazyvcs.source_control.jobs")
				local repo = { root = ctx.helpers.tempdir(), vcs = "git" }
				local owner, started, completions = {}, {}, {}
				local enqueue
				enqueue = function(generation, callback)
					return jobs.command(repo, "reentrant", { tostring(generation) }, {
						owner = owner,
						scope = "supersession",
						generation = generation,
						start = function(_, _, done)
							started[#started + 1] = generation
							completions[generation] = done
							return {
								cancel = function()
									done(nil, "cancelled", { code = 130, cancelled = true })
								end,
							}
						end,
					}, callback or function() end)
				end
				local stale
				local ok, err = xpcall(function()
					enqueue(1, function()
						enqueue(3)
					end)
					enqueue(2, function(_, _, raw)
						stale = raw
					end)
					assert(completions[3], "reentrant current generation did not start")
					completions[3]({ code = 0, stdout = "" })
					assert(vim.deep_equal(started, { 1, 3 }), "superseded generation started after its replacement")
					assert(stale and stale.cancelled, "superseded caller was not notified")
				end, debug.traceback)
				jobs.cancel(function(job)
					return job.owner == owner
				end, "test cleanup")
				assert(ok, err)
			end,
		},
	}
end
