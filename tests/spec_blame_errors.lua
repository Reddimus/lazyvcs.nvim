return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, selection = t.api, require("lazyvcs.blame_selection")
	local function protected_report(request)
		assert(api.nvim_buf_is_valid(request.buf), "backend error closed the report")
		assert(vim.bo[request.buf].readonly and not vim.bo[request.buf].modifiable, "report protection was lost")
		assert(not request.handle, "report retained pending work")
		local lines = api.nvim_buf_get_lines(request.buf, 0, -1, false)
		assert(not table.concat(lines):find("Loading", 1, true), "report still loading")
		return lines
	end
	return t.cases({
		{
			"test_svn_blame_selection_renders_multiline_backend_error",
			function()
				local f = t.open(true)
				assert(vim.uv.fs_rename(f.repo, f.repo .. "-offline"))
				local request = assert(selection.open(1, 2))
				t.wait(function()
					return not request.handle
				end, "offline SVN request did not finish", 15000)
				local lines = protected_report(request)
				assert(
					#lines >= 2 and table.concat(lines):find("svn:", 1, true),
					"SVN diagnostics were not split into readable lines"
				)
				assert(#t.notices == 0, "backend diagnostic became an internal callback error")
				api.nvim_set_current_win(request.win)
				api.nvim_feedkeys("q", "xt", false)
				assert(
					not api.nvim_buf_is_valid(request.buf) and not selection._test_requests()[request.source],
					"q did not close the error report"
				)
			end,
		},
		{
			"test_blame_selection_snapshot_error_releases_handle",
			function()
				local f, buf = t.open(false)
				t.patch(require("lazyvcs.compare"), "blame_target", function()
					return {
						snapshot = { vcs = "git", root = f.root, revision = "HEAD", head = "HEAD" },
						item = { relpath = "sample.txt" },
						path = f.file,
						side = "base",
						bytes = "binary\0snapshot",
					}
				end)
				local request = assert(selection.open(1, 2))
				t.wait(function()
					return table.concat(api.nvim_buf_get_lines(request.buf, 0, -1, false)):find("Binary file", 1, true)
				end, "snapshot error was not rendered")
				local lines = protected_report(request)
				vim.bo[buf].fileformat = "dos"
				api.nvim_exec_autocmds("OptionSet", { pattern = "fileformat" })
				assert(vim.deep_equal(lines, protected_report(request)), "option change overwrote the snapshot error")
				assert(#t.notices == 0, "snapshot error became an internal callback error")
			end,
		},
		{
			"test_blame_selection_nil_base_contents_reports_error",
			function()
				local f = t.open(false)
				local done, entries, err
				local task = require("lazyvcs.backends.blame_selection").load(
					{
						snapshot = { vcs = "git", root = f.root, revision = "HEAD", head = "HEAD" },
						item = { relpath = "sample.txt" },
						path = f.file,
						side = "base",
						first = 1,
						last = 2,
					},
					nil,
					function(value, why)
						entries, err, done = value, why, true
					end
				)
				assert(not done, "invalid base completed before the task was returned")
				t.wait(function()
					return done
				end, "missing base contents did not finish")
				assert(not entries and type(err) == "string" and err ~= "", "missing base contents lost its diagnostic")
				assert(task.done and not task:is_active(), "missing base task remained active")
			end,
		},
		{
			"test_blame_selection_failed_write_restores_protection",
			function()
				t.open(false)
				local done
				t.patch(require("lazyvcs.backends.blame_selection"), "load", function(_, _, callback)
					done = callback
					return { kill = function() end }
				end)
				local request = assert(selection.open(1, 2))
				local set, failed = api.nvim_buf_set_lines, false
				t.patch(api, "nvim_buf_set_lines", function(buf, ...)
					if buf == request.buf and not failed then
						failed = true
						error("forced report\nwrite failure")
					end
					return set(buf, ...)
				end)
				done(nil, "backend\r\ndiagnostic\ncontrol\1")
				local lines = protected_report(request)
				assert(
					failed and table.concat(lines):find("Could not update", 1, true),
					"protected fallback report was not rendered"
				)
				assert(#t.notices == 0, "recoverable write failure notified an internal error")
			end,
		},
		{
			"test_blame_selection_unwritable_report_retires_request",
			function()
				t.open(false)
				local done
				t.patch(require("lazyvcs.backends.blame_selection"), "load", function(_, _, callback)
					done = callback
					return { kill = function() end }
				end)
				local request = assert(selection.open(1, 2))
				local set, attempts = api.nvim_buf_set_lines, 0
				t.patch(api, "nvim_buf_set_lines", function(buf, ...)
					if buf == request.buf then
						attempts = attempts + 1
						error("persistent\nwrite failure")
					end
					return set(buf, ...)
				end)
				done(nil, "backend error")
				assert(attempts == 2, "failed update did not attempt its single fallback")
				assert(
					request.closed and not request.handle and not selection._test_requests()[request.source],
					"unwritable report retained ownership"
				)
				assert(
					#t.notices == 1 and not t.notices[1]:find("\n"),
					"unwritable report did not issue one single-line notification"
				)
			end,
		},
	})
end
