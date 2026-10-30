return function(ctx)
	local h, wait, process = ctx.helpers, ctx.wait_for, require("process_helpers")
	local tests = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	local model = assert(loadfile(tests .. "/fixtures/ai_transport_helpers.lua"))()
	return {
		{
			"test_source_control_copilotchat_files_cancel_timeout_and_errors",
			function()
				model.with_transport(ctx, function(f)
					local source, callback_count, delivered_error = "os", 0, nil
					local tempname, tmpname = vim.fn.tempname, os.tmpname
					f.client.ask = function()
						local response, err = f.chat.post("offline://fixture", {
							headers = { Authorization = "fixture" },
							json_request = true,
							body = { diff = "PRIVATE_DIFF_SENTINEL" },
							temp_source = source,
						})
						if err then
							error(err)
						end
						return { message = { content = response.body } }
					end
					local adapter = require("lazyvcs.source_control.copilotchat")
					local function request(timeout)
						return adapter.start("literal", { timeout_ms = timeout or 10000 }, function(_, err)
							callback_count, delivered_error = callback_count + 1, err
						end)
					end
					for index, kind in ipairs({ "cancel", "timeout", "transport", "success", "http" }) do
						source = index % 2 == 0 and "vim" or "os"
						local defer, deadline = vim.defer_fn, nil
						if kind == "timeout" then
							vim.defer_fn = function(fn)
								deadline = fn
								return assert(vim.uv.new_timer())
							end
						end
						local handle = request(kind == "timeout" and 250 or nil)
						vim.defer_fn = defer
						local job = f.ready(index)
						local path = job.options.body
						local header = job.options.dump
						if vim.fn.has("win32") == 0 then
							assert(bit.band(vim.uv.fs_stat(header).mode, 511) == 384, "header dump is not private")
						end
						assert(
							vim.fn.readfile(path, "b")[1]:find("PRIVATE_DIFF_SENTINEL"),
							"fixture request body missing"
						)
						assert(
							os.tmpname == tmpname and vim.fn.tempname == tempname,
							"temporary name wrappers escaped leaf"
						)
						if kind == "cancel" then
							handle:cancel()
						elseif kind == "timeout" then
							assert(deadline)()
						elseif kind == "transport" then
							job.handle:kill(9)
						else
							job.options.http_error = kind == "http"
							h.write_file(f.jobs[index].path .. ".finish", "done")
						end
						wait(function()
							return process.reaped(job.pid)
						end, kind .. " transport not reaped", 5000)
						wait(function()
							return vim.uv.fs_stat(path) == nil
						end, kind .. " retained private request file", 2000)
						wait(function()
							return vim.uv.fs_stat(header) == nil
						end, kind .. " retained header dump", 2000)
						if kind ~= "cancel" then
							wait(function()
								return callback_count == index - 1
							end, "request callback missing")
						end
						if kind == "timeout" then
							assert(delivered_error == "CopilotChat timed out")
						end
					end
					assert(callback_count == 4, "request callback duplicated")
				end)
			end,
		},
		{
			"test_source_control_copilotchat_files_preserve_unowned_paths",
			function()
				model.with_transport(ctx, function(f)
					local transport = require("lazyvcs.source_control.copilotchat_transport")
					local scope = assert(transport.new_scope())
					local names, tempname = {}, vim.fn.tempname
					---@diagnostic disable-next-line: duplicate-set-field
					vim.fn.tempname = function()
						local path = f.dir .. "/name-" .. (#names + 1)
						names[#names + 1] = path
						return path
					end
					local options = {
						headers = { Authorization = "fixture" },
						json_request = true,
						body = { diff = "private" },
						temp_source = "vim",
						unused_name = true,
					}
					f.async.run(function()
						scope:run(function()
							f.chat.post("offline://fixture", options)
						end)
					end)
					vim.fn.tempname = tempname
					local job = f.ready(1)
					assert(
						vim.deep_equal(options.body, { diff = "private" }) and options.json_request,
						"request options changed"
					)
					scope:cancel()
					wait(function()
						return process.reaped(job.pid) and not vim.uv.fs_stat(names[1])
					end, "owned body was not released", 5000)
					assert(vim.fn.readfile(names[2])[1] == "unrelated", "unmatched generated path was deleted")
					local replaced = assert(transport.new_scope())
					f.async.run(function()
						replaced:run(function()
							f.chat.post("offline://fixture", {
								headers = { Authorization = "fixture" },
								json_request = true,
								body = { diff = "private" },
								temp_source = "vim",
							})
						end)
					end)
					local replaced_job = f.ready(2)
					local path = replaced_job.options.body
					-- Keep the old inode allocated so replacement cannot reuse its identity.
					assert(vim.uv.fs_rename(path, f.dir .. "/old-body"))
					h.write_file(path, "replacement")
					local header = replaced_job.options.dump
					assert(vim.uv.fs_rename(header, f.dir .. "/old-header"))
					h.write_file(header, "replacement header")
					replaced:cancel()
					wait(function()
						return process.reaped(replaced_job.pid) and not next(replaced.jobs)
					end, "replacement job retained", 5000)
					vim.wait(30)
					assert(vim.fn.readfile(path)[1] == "replacement", "replaced file was deleted")
					assert(vim.fn.readfile(header)[1] == "replacement header", "replaced header was deleted")
					local external = f.dir .. "/external"
					h.write_file(external, "external body")
					local external_header = f.dir .. "/external-header"
					h.write_file(external_header, "external header")
					local other = assert(transport.new_scope())
					f.async.run(function()
						other:run(function()
							f.chat.post(
								"offline://fixture",
								{ headers = { Authorization = "fixture" }, body = external, dump = external_header }
							)
						end)
					end)
					local outside = f.ready(3)
					other:cancel()
					wait(function()
						return process.reaped(outside.pid)
					end, "external-body child not reaped", 5000)
					assert(vim.fn.readfile(external)[1] == "external body", "caller file was deleted")
					assert(vim.fn.readfile(external_header)[1] == "external header", "caller header was deleted")
				end)
			end,
		},
		{
			"test_source_control_copilotchat_files_release_after_spawn_failure",
			function()
				model.with_transport(ctx, function(f)
					local scope = assert(require("lazyvcs.source_control.copilotchat_transport").new_scope())
					local tempname, tmpname, path = vim.fn.tempname, os.tmpname, f.dir .. "/request.json"
					local scoped_tempname = function()
						return path
					end
					---@diagnostic disable-next-line: duplicate-set-field
					vim.fn.tempname = scoped_tempname
					local failure
					f.async.run(function()
						scope:run(function()
							local _, err = f.chat.post("offline://fixture", {
								headers = { Authorization = "fixture" },
								json_request = true,
								body = { diff = "private" },
								temp_source = "vim",
								fail_request = true,
							})
							failure = err
						end)
					end)
					assert(
						vim.fn.tempname == scoped_tempname and os.tmpname == tmpname,
						"temporary name wrappers escaped failed leaf"
					)
					vim.fn.tempname = tempname
					assert(
						failure and failure:find("fixture request failure") and #f.jobs == 0,
						"spawn error contract changed"
					)
					wait(function()
						return not vim.uv.fs_stat(path) and not vim.uv.fs_stat(path .. "-lazyvcs-headers")
					end, "spawn failure retained private request file or header", 2000)
				end)
			end,
		},
	}
end
