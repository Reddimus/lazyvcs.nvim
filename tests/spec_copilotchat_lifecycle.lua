return function(ctx)
	local h, wait, process = ctx.helpers, ctx.wait_for, require("process_helpers")
	local tests = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	local model = assert(loadfile(tests .. "/fixtures/ai_transport_helpers.lua"))()
	local function fixture(run)
		model.with_transport(ctx, run)
	end
	return {
		{
			"test_source_control_copilotchat_success_reaps_transport_before_release",
			function()
				fixture(function(f)
					local count, message, failure = 0, nil, nil
					f.client.ask = function()
						local response = f.chat.post(
							"offline://fixture",
							{ headers = { Authorization = "fixture" }, ignore_term = true }
						)
						return { message = { content = response.body } }
					end
					local adapter = require("lazyvcs.source_control.copilotchat")
					local constructor, class_shutdown = f.Job.new, f.Job._shutdown
					local handle = adapter.start("literal", { timeout_ms = 10000 }, function(value, err)
						count, message, failure = count + 1, value, err
					end)
					local job = f.ready(1)
					local outside = f.curl.get(
						"offline://fixture",
						{ headers = { Authorization = "fixture" }, callback = function() end }
					)
					f.ready(2)
					-- A complete stream asks for logical success while the child is still active.
					job:shutdown(0, 0)
					wait(function()
						return count == 1
					end, "successful stream did not complete", 5000)
					assert(not failure and message == "Generated subject", tostring(failure))
					assert(process.reaped(job.pid), "successful transport was not reaped (expected ESRCH)")
					assert(not job.closed_active, "process handle closed before exit")
					assert(process.alive(outside.pid), "success stopped an unrelated transport")
					handle:cancel()
					handle:cancel()
					h.write_file(f.jobs[2].path .. ".finish", "done")
					wait(function()
						return process.reaped(outside.pid)
					end, "ordinary EOF was not reaped", 15000)
					local eof_count = 0
					adapter.start("literal", { timeout_ms = 10000 }, function(value, err)
						assert(value == "Generated subject" and not err)
						eof_count = eof_count + 1
					end)
					local eof = f.ready(3)
					h.write_file(f.jobs[3].path .. ".finish", "done")
					wait(function()
						return eof_count == 1 and process.reaped(eof.pid)
					end, "owned EOF did not complete", 15000)
					vim.wait(30)
					assert(count == 1 and eof_count == 1, "duplicate success delivered")
					assert(f.Job.new == constructor and f.Job._shutdown == class_shutdown, "Job class was patched")
					local scope = assert(require("lazyvcs.source_control.copilotchat_transport").new_scope())
					f.async.run(function()
						scope:run(function()
							f.chat.post("offline://fixture", { headers = { Authorization = "fixture" } })
						end)
					end)
					local throwing = f.ready(4)
					throwing:add_on_exit_callback(function()
						error("fixture finalizer\nfailed")
					end)
					local notify, notices = vim.notify, {}
					vim.notify = function(value)
						notices[#notices + 1] = value
					end
					throwing:shutdown(0, 0)
					wait(function()
						return #notices == 1
					end, "finalizer failure was not reported")
					vim.notify = notify
					assert(not notices[1]:find("[\r\n]"), "multiline finalizer notification")
					assert(
						process.reaped(throwing.pid) and throwing.is_shutdown and not next(scope.jobs),
						"throwing finalizer skipped cleanup"
					)
					f.Job._shutdown = nil
					local requirement
					adapter.start("literal", { timeout_ms = 10000 }, function(_, err)
						requirement = err
					end)
					wait(function()
						return requirement ~= nil
					end, "unsupported Job error missing")
					assert(requirement:find("requires") and #f.jobs == 4, "unsupported Job started client")
				end)
			end,
		},
		{
			"test_source_control_copilotchat_cancel_and_timeout_supersede_pending_success",
			function()
				fixture(function(f)
					local scope = assert(require("lazyvcs.source_control.copilotchat_transport").new_scope())
					local response, failure
					f.async.run(function()
						scope:run(function()
							response, failure = f.chat.post(
								"offline://fixture",
								{ headers = { Authorization = "fixture" }, ignore_term = true }
							)
						end)
					end)
					local job = f.ready(1)
					job:shutdown(0, 0)
					scope:cancel()
					scope:cancel()
					wait(function()
						return process.reaped(job.pid) and failure ~= nil
					end, "cancelled success was not reaped through error path", 5000)
					assert(not response and failure == "cancelled", "cancellation delivered success")
					assert(not next(scope.jobs), "exited Job retained in scope")
					local defer, deadline, callbacks, result = vim.defer_fn, nil, 0, nil
					vim.defer_fn = function(fn)
						deadline = fn
						return assert(vim.uv.new_timer())
					end
					local transport_value, transport_err, transport_done
					f.client.ask = function()
						transport_value, transport_err = f.chat.post(
							"offline://fixture",
							{ headers = { Authorization = "fixture" }, ignore_term = true }
						)
						transport_done = true
						return { message = { content = transport_value and transport_value.body or "late" } }
					end
					require("lazyvcs.source_control.copilotchat").start(
						"literal",
						{ timeout_ms = 250 },
						function(message, err)
							assert(not message)
							callbacks, result = callbacks + 1, err
						end
					)
					vim.defer_fn = defer
					local timed_out = f.ready(2)
					timed_out:shutdown(0, 0)
					assert(deadline)()
					wait(function()
						return process.reaped(timed_out.pid) and result ~= nil
					end, "timeout did not supersede successful stream", 5000)
					wait(function()
						return transport_done
					end, "timed-out transport did not resume the request", 5000)
					assert(not transport_value and transport_err, "timeout delivered the recorded success")
					vim.wait(30)
					assert(callbacks == 1 and result == "CopilotChat timed out", "late success replaced timeout")
				end)
			end,
		},
		{
			"test_source_control_copilotchat_exit_reaps_owned_transports",
			function()
				local root = vim.fn.fnamemodify(tests, ":h")
				for _, mode in ipairs({ "running", "cancelled", "success" }) do
					local dir = h.tempdir()
					process.guarded(dir, function()
						process.editor(tests .. "/fixtures/copilotchat_shutdown.lua", dir, { root, dir, mode })
						local state = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/shutdown.json"), "\n"))
						assert(
							state.reaped,
							"CopilotChat transports were not reaped before editor exit (expected ESRCH): " .. mode
						)
						assert(state.files_removed, "shutdown retained private request files")
						assert(state.closed and state.rejected, "shutdown accepted a new transport")
						assert(state.callbacks == 0, "shutdown delivered application output")
						assert(state.elapsed_ms < 500, "transport shutdown exceeded shared deadlines")
					end)
				end
			end,
		},
	}
end
