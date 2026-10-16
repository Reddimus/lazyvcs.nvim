return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, blame = t.api, require("lazyvcs.blame")
	local function registry()
		if blame._test_line_log_views then
			return blame._test_line_log_views()
		end
		for i = 1, 30 do
			local name, value = debug.getupvalue(blame.line_log, i)
			if name == "line_log_views" then
				return value
			end
		end
		error("line log registry absent")
	end
	local function popup(buf)
		return registry()[buf] and registry()[buf].winid
	end
	local function history(buf, win, line, revision)
		api.nvim_win_set_cursor(win, { line, 0 })
		assert(blame.line_log())
		t.wait(function()
			return popup(buf)
		end, "line history did not open", 15000)
		assert(
			vim.inspect(api.nvim_win_get_config(popup(buf)).title):find(revision, 1, true),
			"line history chose wrong revision"
		)
	end
	local function unsaved(svn)
		local f, buf, win = t.open(svn)
		t.h.write_file(f.file, "one\nsecond revision\nthree\n")
		t.h.exec(svn and { "svn", "commit", "-m", "second", f.file } or { "git", "commit", "-am", "second" }, f.root)
		local revision = svn and "2" or vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
		vim.cmd("edit!")
		api.nvim_buf_set_lines(buf, 0, 0, false, { "new unsaved" })
		api.nvim_win_set_cursor(win, { 1, 0 })
		assert(blame.line_log())
		t.wait(function()
			return #t.notices > 0
		end, "inserted line incorrectly opened committed history", 15000)
		assert(not popup(buf) and not registry()[buf], "uncommitted line retained a popup or request")
		assert(t.notices[#t.notices]:find("No committed", 1, true))
		history(buf, win, 3, revision)
		api.nvim_buf_set_lines(buf, 0, 2, false, {})
		api.nvim_exec_autocmds("TextChanged", { buffer = buf })
		history(buf, win, 1, revision)
	end
	return t.cases({
		{
			"test_blame_line_log_maps_unsaved_contents",
			function()
				unsaved(false)
			end,
		},
		{
			"test_svn_blame_line_log_maps_unsaved_contents",
			function()
				unsaved(true)
			end,
		},
		{
			"test_blame_git_line_log_bounds_blame_to_cursor",
			function()
				local f, buf, win, backend = t.open(false)
				local rows = {}
				for i = 1, 16000 do
					rows[i] = i .. ",a,b,c"
				end
				t.h.write_file(f.file, table.concat(rows, "\n") .. "\n")
				t.h.exec({ "git", "commit", "-am", "csv" }, f.root)
				local expected = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
				vim.cmd("edit!")
				local opts = { contents = table.concat(rows, "\n") .. "\n", root = f.root }
				local original = vim.deepcopy(opts)
				local done, revision, err = false, nil, nil
				backend.line_revision_async(f.file, 8000, function(r, e)
					done, revision, err = true, r, e
				end, opts)
				t.wait(function()
					return done
				end, "bounded blame did not finish", 15000)
				assert(revision == expected, "one-line history failed: " .. tostring(err))
				assert(vim.deep_equal(opts, original), "line history mutated caller options")
				history(buf, win, 8000, expected)
				local process, seen = require("lazyvcs.backends.process"), false
				local lines = process.lines
				t.patch(process, "lines", function(args, options, callback)
					if args[2] == "blame" and args[#args] == "sample.txt" then
						local joined = table.concat(args, " ")
						assert(joined:find("-L 8000,8000", 1, true), "line history requested whole-file blame")
						seen = true
					end
					return lines(args, options, callback)
				end)
				rows[8000] = "uncommitted selected row"
				done = false
				backend.line_revision_async(f.file, 8000, function(r, e)
					done, revision, err = true, r, e
				end, { contents = rows, line_start = 1, line_end = 2 })
				t.wait(function()
					return done
				end, "uncommitted line lookup did not finish", 15000)
				assert(
					seen and not revision and type(err) == "string" and err:find("No committed", 1, true),
					"range did not reject uncommitted line"
				)
				local added = f.root .. "/added.txt"
				t.h.write_file(added, "first\nsecond\nthird\n")
				t.h.exec({ "git", "add", "added.txt" }, f.root)
				local raw
				done = false
				backend.blame_lines_async(added, function(r, e)
					done, raw, err = true, r, e
				end, { contents = { "first", "second", "third" }, line_start = 2, line_end = 2 })
				t.wait(function()
					return done
				end, "added range did not finish", 15000)
				assert(
					raw and #backend.parse_blame_entries(raw) == 1 and raw[1]:find(" 2 2 1", 1, true),
					"added-file fallback ignored requested range: " .. tostring(err)
				)
				assert(backend.parse_blame_entries(raw)[1].uncommitted)
				local unborn = t.h.tempdir()
				t.h.exec({ "git", "init" }, unborn)
				t.h.write_file(unborn .. "/added.txt", "first\nsecond\nthird\n")
				t.h.exec({ "git", "add", "added.txt" }, unborn)
				done = false
				backend.blame_lines_async(unborn .. "/added.txt", function(r, e)
					done, raw, err = true, r, e
				end, { line_start = 2, line_end = 2 })
				t.wait(function()
					return done
				end, "unborn range did not finish", 15000)
				assert(
					raw and #backend.parse_blame_entries(raw) == 1 and raw[1]:find(" 2 2 1", 1, true),
					"unborn fallback ignored requested range: " .. tostring(err)
				)
				done = false
				backend.blame_lines_async(unborn .. "/added.txt", function(r, e)
					done, raw, err = true, r, e
				end, { line_start = 2 })
				t.wait(function()
					return done
				end, "partial range did not finish", 15000)
				assert(
					raw and #backend.parse_blame_entries(raw) == 3,
					"partial range changed whole-file fallback semantics: " .. tostring(err)
				)
			end,
		},
		{
			"test_blame_line_log_releases_pending_source",
			function()
				local backends = require("lazyvcs.backends")
				for _, phase in ipairs({ "resolve", "revision", "log" }) do
					local _, buf, _, backend = t.open(false)
					local pending, killed
					local function hold(_, callback)
						pending = callback
						return {
							kill = function()
								killed = true
							end,
						}
					end
					if phase == "resolve" then
						t.patch(backends, "resolve_cached", function()
							return nil
						end)
						t.patch(backends, "resolve_async", hold)
					elseif phase == "revision" then
						t.patch(backend, "line_revision_async", function(_, _, callback)
							return hold(nil, callback)
						end)
					else
						t.patch(backend, "revision_log_async", function(_, _, callback)
							return hold(nil, callback)
						end)
					end
					assert(blame.line_log())
					t.wait(function()
						return pending ~= nil
					end, "pending phase did not start: " .. phase, 15000)
					local view = assert(registry()[buf])
					api.nvim_buf_delete(buf, { force = true })
					assert(
						killed and not registry()[buf] and view.handle == nil,
						"pending " .. phase .. " retained deleted source"
					)
					pending(nil, "late completion")
					assert(not registry()[buf], "late completion restored deleted request")
					for i = #t.patches, 2, -1 do
						local p = table.remove(t.patches, i)
						p[1][p[2]] = p[3]
					end
				end
			end,
		},
		{
			"test_blame_line_log_discards_edited_and_replaced_requests",
			function()
				local _, buf, _, backend = t.open(false)
				local callbacks, handles = {}, {}
				t.patch(backend, "line_revision_async", function(_, _, callback, opts)
					callbacks[#callbacks + 1] = callback
					local handle = {
						kill = function(self)
							self.killed = true
						end,
						contents = opts and opts.contents,
					}
					handles[#handles + 1] = handle
					return handle
				end)
				assert(blame.line_log())
				api.nvim_buf_set_lines(buf, 0, 0, false, { "edit during request" })
				callbacks[1]("old revision")
				assert(not registry()[buf], "edited request retained pending view")
				assert(blame.line_log())
				local newer = registry()[buf]
				callbacks[1](nil, "late old error")
				assert(registry()[buf] == newer, "old callback retired newer line history")
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				assert(not registry()[buf] and handles[2].killed, "edit did not cancel pending history")
			end,
		},
	})
end
