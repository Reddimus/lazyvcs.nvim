return function(ctx)
	local h, wait, process = ctx.helpers, ctx.wait_for, require("process_helpers")
	local tests = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
	return {
		{
			"test_source_control_copilotchat_cancel_and_timeout_stop_transport",
			function()
				local names = {
					"CopilotChat",
					"CopilotChat.client",
					"CopilotChat.utils.curl",
					"plenary.curl",
					"lazy",
					"plenary.async",
					"plenary.job",
				}
				local defer = vim.defer_fn
				local previous = {}
				for _, name in ipairs(names) do
					previous[name] = package.loaded[name]
				end
				local fixture = assert(loadfile(tests .. "/fixtures/ai_transport_helpers.lua"))()
				local async = fixture.async()
				local dir, chunks, callbacks = h.tempdir(), 0, 0
				local curl, chat_curl, Job, jobs = fixture.transport(dir, tests .. "/fixtures/ai_transport.lua", async)
				local requests = {}
				package.loaded["plenary.async"] = async
				package.loaded["plenary.job"] = Job
				package.loaded["plenary.curl"] = curl
				package.loaded["CopilotChat.utils.curl"] = chat_curl
				package.loaded["lazy"] = { load = function() end }
				package.loaded["CopilotChat"] = { config = { model = "fixture" } }
				local client = { models = function() end, get_providers = function() end }
				package.loaded["CopilotChat.client"] = client
				local function ready(index)
					wait(function()
						return jobs[index] and process.pid(jobs[index].path) ~= nil
					end, "Plenary child did not start", 15000)
					return jobs[index], process.pid(jobs[index].path)
				end
				local adapter = require("lazyvcs.source_control.copilotchat")
				local function request(timeout, done)
					local handle = adapter.start("literal", { timeout_ms = timeout or 10000 }, done or function()
						callbacks = callbacks + 1
					end)
					requests[#requests + 1] = handle
					return handle
				end
				local ok, err = xpcall(function()
					---@diagnostic disable-next-line: duplicate-set-field
					client.ask = function()
						local response = chat_curl.post("offline://fixture", {
							headers = { Authorization = "fixture" },
							stream = function()
								chunks = chunks + 1
							end,
						})
						return { message = { content = response and response.body or "late" } }
					end
					local first, second = request(), request()
					local _, first_pid = ready(1)
					local second_job, second_pid = ready(2)
					first:cancel()
					assert(
						vim.wait(1000, function()
							return not process.alive(first_pid)
						end, 10),
						"cancelled CopilotChat transport still alive"
					)
					assert(process.alive(second_pid), "cancellation stopped another request")
					assert(callbacks == 0 and chunks == 0, "cancelled request delivered output")
					second:cancel()
					wait(function()
						return not process.alive(second_pid)
					end, "second transport survived cancellation", 3000)
					assert(second_job.job.is_shutdown, "Job shutdown was not called")
					local timeout_count, timeout_error = 0, nil
					local timeout_timer, timeout_callback
					-- Hold only this deadline until the child is ready; startup can be slow.
					---@diagnostic disable-next-line: duplicate-set-field
					vim.defer_fn = function(callback, delay)
						assert(delay == 250)
						timeout_timer = assert(vim.uv.new_timer())
						timeout_callback = callback
						return timeout_timer
					end
					request(250, function(_, failure)
						timeout_count = timeout_count + 1
						timeout_error = failure
					end)
					vim.defer_fn = defer
					-- Exercise readiness observed later than the configured deadline.
					vim.wait(300)
					local _, timeout_pid = ready(3)
					assert(timeout_count == 0 and process.alive(timeout_pid), "deadline fired before child readiness")
					assert(timeout_timer):start(250, 0, vim.schedule_wrap(assert(timeout_callback)))
					wait(function()
						return timeout_count == 1
					end, "timeout callback missing")
					assert(timeout_error == "CopilotChat timed out")
					wait(function()
						return not process.alive(timeout_pid)
					end, "timed-out transport still alive", 3000)
					vim.wait(30)
					assert(timeout_count == 1 and callbacks == 0 and chunks == 0, "late timeout output delivered")
					local wrapper, chat_wrapper = curl.post, chat_curl.post
					local ordinary_done = false
					local ordinary = curl.get("offline://fixture", {
						headers = { Authorization = "fixture" },
						callback = function()
							ordinary_done = true
						end,
					})
					local outside, outside_pid = ready(4)
					---@diagnostic disable-next-line: duplicate-set-field
					client.ask = function()
						chat_curl.get("offline://fixture", { headers = { Authorization = "fixture" } })
						local response =
							chat_curl.post("offline://fixture", { headers = { Authorization = "fixture" } })
						return { message = { content = response.body } }
					end
					local chained = request()
					local auth = ready(5)
					h.write_file(auth.path .. ".finish", "done")
					local _, final_pid = ready(6)
					chained:cancel()
					wait(function()
						return not process.alive(final_pid)
					end, "post-auth transport survived cancellation", 3000)
					assert(process.alive(outside_pid) and ordinary == outside.job, "ordinary curl call changed")
					assert(curl.post == wrapper and chat_curl.post == chat_wrapper, "curl wrapper installed twice")
					h.write_file(outside.path .. ".finish", "done")
					wait(function()
						return ordinary_done
					end, "ordinary curl callback lost", 15000)
					local success
					---@diagnostic disable-next-line: duplicate-set-field
					client.ask = function()
						local response = chat_curl.post("offline://fixture", {
							headers = { Authorization = "fixture" },
							stream = function()
								chunks = chunks + 1
							end,
						})
						return { message = { content = response.body } }
					end
					request(nil, function(message, failure)
						assert(not failure)
						success = message
					end)
					local final = ready(7)
					h.write_file(final.path .. ".finish", "done")
					wait(function()
						return success ~= nil
					end, "successful stream did not complete", 15000)
					assert(success == "Generated subject" and chunks > 0)
					local transport = require("lazyvcs.source_control.copilotchat_transport")
					local options = { headers = { Authorization = "fixture" } }
					-- Errors before and inside curl must clear the handoff before another request.
					for _, failure in ipairs({ "fail_leaf", "fail_request" }) do
						local scope = assert(transport.new_scope())
						local failure_received
						async.run(function()
							scope:run(function()
								local response, err = chat_curl.post(
									"offline://fixture",
									vim.tbl_extend("force", options, {
										[failure] = true,
									})
								)
								assert(not response and err:find("fixture"), "leaf error did not reach caller")
								failure_received = true
							end)
						end)
						assert(failure_received, "leaf failure escaped scheduler")
						local outside_done
						local index = #jobs + 1
						async.run(function()
							local response = chat_curl.get("offline://fixture", options)
							outside_done = response.body
						end)
						local outside_job, pid = ready(index)
						scope:cancel()
						assert(
							process.alive(pid) and not outside_job.job.is_shutdown,
							"failed handoff captured outside request"
						)
						h.write_file(outside_job.path .. ".finish", "done")
						wait(function()
							return outside_done ~= nil
						end, "outside async call lost its return value")
						assert(outside_done == "Generated subject")
					end
					-- Cancellation can resume a caller that issues another request while unwinding.
					local late_index = #jobs + 2
					local late_error
					---@diagnostic disable-next-line: duplicate-set-field
					client.ask = function()
						chat_curl.get("offline://fixture", options)
						local response, err = chat_curl.post("offline://fixture", options)
						assert(not response)
						late_error = err
						return { message = { content = "late" } }
					end
					local late = request()
					ready(late_index - 1)
					late:cancel()
					wait(function()
						return late_error ~= nil
					end, "late leaf error callback missing")
					assert(jobs[late_index].job.is_shutdown and late_error == "cancelled")
					wait(function()
						return not process.alive(jobs[late_index].job.pid)
					end, "late leaf child survived cancellation")
					assert(callbacks == 0, "late request delivered a result")
					local closed = assert(transport.new_scope())
					closed:close()
					local closed_index, closed_error = #jobs + 1, nil
					async.run(function()
						closed:run(function()
							local _, err = chat_curl.get("offline://fixture", options)
							closed_error = err
						end)
					end)
					wait(function()
						return closed_error ~= nil and not process.alive(jobs[closed_index].job.pid)
					end, "closed scope did not stop late child through its error callback")
					assert(closed_error == "cancelled")
					local called = false
					---@diagnostic disable-next-line: duplicate-set-field
					client.ask = function()
						called = true
					end
					package.loaded["plenary.curl"] = {}
					local requirement
					request(nil, function(_, failure)
						requirement = failure
					end)
					wait(function()
						return requirement ~= nil
					end, "missing transport error not reported")
					assert(not called and requirement:find("requires"), "missing transport started client")
				end, debug.traceback)
				vim.defer_fn = defer
				for _, handle in ipairs(requests) do
					handle:cancel()
				end
				for _, item in ipairs(jobs) do
					local pid = process.pid(item.path)
					if process.alive(pid) then
						pcall(vim.uv.kill, pid, 9)
					end
					pcall(item.job.shutdown, item.job)
				end
				vim.wait(50)
				for _, name in ipairs(names) do
					package.loaded[name] = previous[name]
				end
				assert(ok, err)
			end,
		},
	}
end
