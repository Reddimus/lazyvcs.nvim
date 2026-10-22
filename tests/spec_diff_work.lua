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
	local left = "one\ntwo\nthree\nfour\nfive\n"
	local right = "one\n2\nthree\nfour\nfive\nsix\n"
	local opts = { algorithm = "histogram" }
	return {
		{
			"test_core_diff_work_worker_prefers_text_diff_without_upvalues",
			function()
				assert(debug.getinfo(M._worker, "u").nups == 0, "libuv workers cannot capture upvalues")
				local text, calls = vim.text, 0
				local ok, err = xpcall(function()
					if type(text) == "table" and type(text.diff) == "function" then
						vim.text = setmetatable({
							diff = function(...)
								calls = calls + 1
								return text.diff(...)
							end,
						}, { __index = text })
						local available, raw = M._worker(left, right, "indices")
						assert(available and calls == 1, "worker did not use vim.text.diff")
						---@cast raw string
						assert(
							vim.deep_equal(
								vim.mpack.decode(raw),
								text.diff(
									left,
									right,
									vim.tbl_extend("force", opts, {
										result_type = "indices",
									})
								)
							)
						)
					end
					---@diagnostic disable-next-line: deprecated
					if type(vim.diff) == "function" then
						vim.text = nil
						local available, raw = M._worker(left, right, "unified")
						---@diagnostic disable-next-line: deprecated
						local expected =
							vim.diff(left, right, vim.tbl_extend("force", opts, { result_type = "unified" }))
						assert(available and raw == expected, "worker did not fall back to vim.diff")
					end
				end, debug.traceback)
				vim.text = text
				assert(ok, err)
			end,
		},
		{
			"test_core_diff_work_thread_matches_editor_diff",
			function()
				local compat = require("lazyvcs.compat")
				for _, result_type in ipairs({ "indices", "unified" }) do
					local done
					assert(M.start(left, right, result_type, function(available, raw, failure)
						done = { available = available, raw = raw, failure = failure }
					end))
					assert(
						vim.wait(5000, function()
							return done ~= nil
						end, 10),
						"diff worker did not finish"
					)
					assert(done.available and not done.failure, vim.inspect(done))
					local expected =
						compat.diff(left, right, vim.tbl_extend("force", opts, { result_type = result_type }))
					local actual = result_type == "indices" and vim.mpack.decode(done.raw) or done.raw
					assert(vim.deep_equal(actual, expected), result_type .. " differs: " .. vim.inspect(actual))
				end
			end,
		},
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
