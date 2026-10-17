return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local pruning = require("commit_file_helpers")
	local files = require("lazyvcs.source_control.commit_files")
	local function dir()
		local path = vim.fn.stdpath("cache") .. "/lazyvcs/commit"
		vim.fn.mkdir(path, "p")
		return path
	end
	return {
		{
			"test_source_control_commit_scan_ignores_unrelated_exhaustion",
			function()
				local restore = pruning.scope(h, "Linux")
				local ok, err = xpcall(function()
					local path = dir() .. "/unrelated-handle.txt"
					h.write_file(path, "stale")
					local old = os.time() - vim.uv.uptime() - 86410
					assert(vim.uv.fs_utime(path, old, old))
					local unrelated = assert(vim.uv.fs_scandir(h.tempdir()))
					pruning.scan(function()
						files.prune()
						assert(not vim.uv.fs_scandir_next(unrelated))
					end, wait)
					assert(not vim.uv.fs_stat(path), "barrier finished before its scan removed the file")
				end, debug.traceback)
				restore()
				assert(ok, err)
			end,
		},
		{
			"test_source_control_commit_scan_rejects_skipped_prune",
			function()
				for _, platform in ipairs({ "Linux", "Darwin" }) do
					local restore = pruning.scope(h, platform)
					local next_entry = vim.uv.fs_scandir_next
					local finished = false
					rawset(vim.uv, "fs_scandir_next", function(entries)
						local name, kind = next_entry(entries)
						finished = finished or not name
						return name, kind
					end)
					local ok, err = xpcall(function()
						dir()
						-- Linux has not opened scandir yet; Darwin already has.
						files.prune()
						local accepted, failure = pcall(pruning.scan, files.prune, wait)
						-- Drain the earlier scan even if the negative assertion fails.
						wait(function()
							return finished
						end, "earlier prune did not finish", 5000)
						assert(not accepted, "skipped prune passed vacuously")
						assert(tostring(failure):find("pruning did not start a fresh scan", 1, true), failure)
						-- The caller can retry once the conflicting scan has finished.
						pruning.scan(files.prune, wait)
					end, debug.traceback)
					vim.uv.fs_scandir_next = next_entry
					restore()
					assert(ok, err)
				end
			end,
		},
		{
			"test_source_control_commit_scan_restores_stubs_after_errors",
			function()
				local scan, next_entry, stat = vim.uv.fs_scandir, vim.uv.fs_scandir_next, vim.uv.fs_stat
				local ok, err = pcall(pruning.scan, function()
					error("forced scan failure")
				end, wait)
				assert(not ok and tostring(err):find("forced scan failure", 1, true))
				assert(vim.uv.fs_scandir == scan and vim.uv.fs_scandir_next == next_entry and vim.uv.fs_stat == stat)
			end,
		},
		{
			"test_source_control_commit_notifications_are_observable_and_restored",
			function()
				local util = require("lazyvcs.util")
				local notify = util.notify
				local seen
				pruning.notified(function(notices)
					util.notify("expected cleanup warning", vim.log.levels.WARN)
					assert(#notices == 1 and notices[1] == "expected cleanup warning")
					seen = notices
				end)()
				assert(seen and util.notify == notify)
				local ok, err = pcall(pruning.notified(function(notices)
					util.notify("warning before failure")
					assert(#notices == 1)
					error("forced notification failure")
				end))
				assert(not ok and tostring(err):find("warning before failure", 1, true))
				assert(util.notify == notify)
				local skip = { lazyvcs_skip = "sentinel" }
				ok, err = pcall(pruning.notified(function()
					error(skip)
				end))
				assert(not ok and err == skip and util.notify == notify)
			end,
		},
		{
			"test_source_control_commit_prune_finishes_async_entry_before_next",
			function()
				local restore = pruning.scope(h, "Darwin")
				local originals, pending, calls = {}, 0, 0
				local next_entry = vim.uv.fs_scandir_next
				local file
				local ok, err = xpcall(function()
					file = assert(files.create("expired message"))
					local old = os.time() - vim.uv.uptime() - 86410
					assert(vim.uv.fs_utime(file.path, old, old))
					for _, name in ipairs({ "fs_lstat", "fs_open", "fs_fstat", "fs_read", "fs_close", "fs_unlink" }) do
						local original = vim.uv[name]
						originals[name] = original
						rawset(vim.uv, name, function(...)
							local args = { ... }
							local cb = args[#args]
							if type(cb) == "function" then
								pending, calls = pending + 1, calls + 1
								args[#args] = function(...)
									pending = pending - 1
									cb(...)
								end
							end
							return original(unpack(args))
						end)
					end
					rawset(vim.uv, "fs_scandir_next", function(entries)
						assert(pending == 0, "prune advanced with an entry's async work pending")
						return next_entry(entries)
					end)
					pruning.scan(files.prune, wait)
					assert(calls > 0 and pending == 0, "async entry checks were vacuous")
					assert(not vim.uv.fs_stat(file.path), "entry work did not finish")
					assert(not vim.uv.fs_stat(file.path .. ".owner"), "sidecar removal did not finish")
				end, debug.traceback)
				for name, original in pairs(originals) do
					rawset(vim.uv, name, original)
				end
				vim.uv.fs_scandir_next = next_entry
				restore()
				if file then
					files.release(file)
				end
				assert(ok, err)
			end,
		},
	}
end
