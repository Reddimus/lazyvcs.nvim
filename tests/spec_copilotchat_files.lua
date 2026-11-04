return function(ctx)
	local h, wait, process = ctx.helpers, ctx.wait_for, require("process_helpers")
	local tests = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
	local model = assert(loadfile(tests .. "/fixtures/ai_transport_helpers.lua"))()
	local function exact_identity_cleanup(kind)
		local fs = require("lazyvcs.file_io")
		local path = h.tempdir() .. "/request"
		h.write_file(path, "owned")
		local uv_lstat, exact_lstat = vim.uv.fs_lstat, fs.fs_lstat
		local runtime = require("lazyvcs.process_runtime")
		local shutting_down = runtime.is_shutting_down
		local replaced = false
		local function metadata(exact)
			assert(uv_lstat(path))
			if exact then
				return {
					type = "file",
					identity = "windows-file-id-128",
					dev = "0000000000000001",
					ino = replaced and "00000000000000008000000000000002" or "00000000000000008000000000000001",
				}
			end
			return { type = "file", dev = 1, ino = 9007199254740992 }
		end
		---@diagnostic disable-next-line: duplicate-set-field
		vim.uv.fs_lstat = function(target, callback)
			if target ~= path then
				return uv_lstat(target, callback)
			end
			if callback then
				vim.schedule(function()
					callback(nil, metadata(false))
				end)
				return
			end
			return metadata(false)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		fs.fs_lstat = function(target, callback)
			if target ~= path then
				return exact_lstat(target, callback)
			end
			if callback then
				vim.schedule(function()
					callback(nil, metadata(true))
				end)
				return
			end
			return metadata(true)
		end
		local ok, err = xpcall(function()
			local files = require("lazyvcs.source_control.copilotchat_files").new()
			files:record(path)
			files:adopt({ body = path })
			assert(vim.uv.fs_rename(path, path .. "-old"))
			h.write_file(path, "replacement")
			replaced = true
			if kind == "shutdown" then
				---@diagnostic disable-next-line: duplicate-set-field
				runtime.is_shutting_down = function()
					return true
				end
			end
			if kind == "abandon" then
				files:abandon()
			else
				local done = false
				files:release(function()
					done = true
				end)
				wait(function()
					return done
				end, "identity cleanup did not settle")
			end
			assert(vim.fn.readfile(path)[1] == "replacement", "rounded file ID deleted a replacement")
		end, debug.traceback)
		vim.uv.fs_lstat, fs.fs_lstat, runtime.is_shutting_down = uv_lstat, exact_lstat, shutting_down
		assert(ok, err)
	end
	return {
		{
			"test_source_control_copilotchat_files_shutdown_exact_identity",
			function()
				exact_identity_cleanup("shutdown")
			end,
		},
		{
			"test_source_control_copilotchat_files_release_exact_identity",
			function()
				exact_identity_cleanup("release")
			end,
		},
		{
			"test_source_control_copilotchat_files_abandon_exact_identity",
			function()
				exact_identity_cleanup("abandon")
			end,
		},
		{
			"test_source_control_copilotchat_header_dump_uses_plenary_argument_pair",
			function()
				model.with_transport(ctx, function(f)
					local scope = assert(require("lazyvcs.source_control.copilotchat_transport").new_scope())
					local response, failure
					f.async.run(function()
						scope:run(function()
							response, failure =
								f.chat.get("offline://fixture", { headers = { Authorization = "fixture" } })
						end)
					end)
					assert(not failure, failure)
					local job = f.ready(1)
					local dump = job.options.dump
					assert(type(dump) == "table" and dump[1] == "-D", "missing curl header flag")
					assert(vim.uv.fs_stat(dump[2]), "private header file missing")
					h.write_file(f.jobs[1].path .. ".finish", "done")
					wait(function()
						return response ~= nil
					end, "header response was not parsed")
					assert(not failure and response.status == 200 and response.headers[1] == "X-Fixture: offline")
					wait(function()
						return not next(scope.jobs) and not vim.uv.fs_stat(dump[2])
					end, "completed header file or job retained")
				end)
			end,
		},
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
						local header = job.options.dump[2]
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
					local header = replaced_job.options.dump[2]
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
							f.chat.post("offline://fixture", {
								headers = { Authorization = "fixture" },
								body = external,
								dump = { "-D", external_header },
							})
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
