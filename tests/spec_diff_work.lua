return function()
	local M = require("lazyvcs.diff_work")
	local function scenario(run)
		local start, requests = M.start, {}
		---@diagnostic disable-next-line: duplicate-set-field
		M.start = function(left, right, _, done)
			requests[#requests + 1] = { left = left, right = right, done = done }
			return {}
		end
		local queue = M.latest()
		local ok, err = xpcall(function()
			run(queue, requests)
		end, debug.traceback)
		queue:close()
		M.start = start
		assert(ok, err)
	end
	return {
		{
			"test_core_diff_work_coalesces_latest_without_parallel_workers",
			function()
				scenario(function(queue, requests)
					local results = {}
					for i = 1, 100 do
						queue:request("base", tostring(i), function(raw)
							results[#results + 1] = raw[1][1]
						end)
					end
					assert(#requests == 1 and requests[1].right == "1")
					requests[1].done(true, vim.mpack.encode({ { 1 } }))
					assert(#requests == 2 and requests[2].right == "100" and #results == 0)
					requests[2].done(true, vim.mpack.encode({ { 100 } }))
					assert(vim.deep_equal(results, { 100 }))
				end)
			end,
		},
		{
			"test_core_diff_work_close_discards_running_and_pending_results",
			function()
				scenario(function(queue, requests)
					local function rejected()
						error("closed worker delivered a result")
					end
					queue:request("a", "b", rejected)
					queue:request("a", "c", rejected)
					queue:close()
					requests[1].done(true, vim.mpack.encode({}))
					queue:request("a", "d", rejected)
					assert(#requests == 1)
				end)
			end,
		},
	}
end
