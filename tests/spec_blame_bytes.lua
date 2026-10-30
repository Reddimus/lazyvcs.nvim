return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local text, api = require("lazyvcs.compare_text"), vim.api
	local function profile(encoding, format, bom)
		return {
			fileencoding = encoding,
			fileformat = format or "unix",
			bomb = bom or false,
			binary = false,
			key = "test",
		}
	end
	local function write(path, bytes)
		local file = assert(io.open(path, "wb"))
		file:write(bytes)
		file:close()
	end
	local formats = {
		{ "latin1", "caf\233\nsecond\nlast\n", "++enc=latin1" },
		{ "bom", "\239\187\191café\nsecond\nlast\n", "++enc=utf-8" },
		{ "noeol", "café\nsecond\nlast", "++enc=utf-8" },
		{ "crlf", "café\r\nsecond\r\nlast\r\n", "++enc=utf-8" },
	}
	local function fixture(format, svn)
		local f, buf, win, backend = t.open(svn)
		write(f.file, format[2])
		if not svn then
			t.h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
		end
		t.h.exec(svn and { "svn", "commit", "-m", "encoded", f.file } or { "git", "commit", "-am", "encoded" }, f.root)
		vim.cmd("edit! " .. format[3])
		return f, buf, win, backend
	end
	local function committed(entries, label)
		assert(entries and #entries == 3, label .. ": expected three editor entries")
		for i, entry in ipairs(entries) do
			assert(not entry.uncommitted, label .. ": unchanged line " .. i .. " lost committed attribution")
		end
	end
	local function source_capture(buf)
		local context = require("lazyvcs.blame_context")
		local contents, err, capture = context.contents(assert(context.capture(buf, api.nvim_get_current_win())), 1024)
		assert(contents, err)
		return capture or { bytes = contents }
	end
	local function backend_entries(f, backend, capture, extra)
		local done, rows, err
		backend.blame_lines_async(
			f.file,
			function(value, why)
				rows, err, done = value, why, true
			end,
			vim.tbl_extend("force", {
				contents = capture.bytes,
				text = capture.text,
				profile = capture.profile,
				root = f.root,
			}, extra or {})
		)
		t.wait(function()
			return done
		end, "blame backend did not finish", 15000)
		return rows and backend.parse_blame_entries(rows), err
	end

	return t.cases({
		{
			"test_svn_blame_rejects_undecodable_base",
			function()
				for _, format in ipairs({
					formats[1],
					{ "latin1-crlf", "caf\233\r\nsecond\r\nlast\r\n", "++enc=latin1" },
				}) do
					local f, buf, _, backend = fixture(format, true)
					vim.bo[buf].fileencoding = "utf-8"
					vim.cmd.write()
					local entries, err = backend_entries(f, backend, source_capture(buf))
					assert(not entries and err, format[1] .. ": undecodable SVN BASE was accepted")
				end
			end,
		},
		{
			"test_blame_ascii_compatible_encodings_keep_bounded_ranges",
			function()
				local f, buf, _, backend = t.open(false)
				local process = require("lazyvcs.backends.process")
				local run, requests = process.lines, {}
				t.patch(process, "lines", function(args, opts, callback)
					if args[2] == "blame" then
						requests[#requests + 1] = vim.deepcopy(args)
					end
					return run(args, opts, callback)
				end)
				for _, encoding in ipairs({ "cp1252", "sjis", "euc-jp", "koi8-r" }) do
					vim.bo[buf].fileencoding = encoding
					local entries, err =
						backend_entries(f, backend, source_capture(buf), { line_start = 2, line_end = 2 })
					assert(entries and #entries == 1, err)
				end
				for _, args in ipairs(requests) do
					assert(
						vim.tbl_contains(args, "-L") and vim.tbl_contains(args, "2,2"),
						"ASCII-compatible blame requested full file: " .. table.concat(args, " ")
					)
				end
				assert(#requests == 4)
			end,
		},
		{
			"test_blame_snapshot_validates_line_models",
			function()
				local f = t.open(false)
				local process = require("lazyvcs.backends.process")
				local run, requests = process.lines, {}
				t.patch(process, "lines", function(args, opts, callback)
					if args[2] == "blame" then
						requests[#requests + 1] = vim.deepcopy(args)
					end
					return run(args, opts, callback)
				end)
				for _, format in ipairs({
					{ "ascii", "one\nsecond\nlast\n", 2, true },
					{ "mac", "one\rsecond\rlast\r", 1, false },
					{ "utf16", "\255\254o\0n\0e\0\n\0", 1, false },
				}) do
					write(f.file, format[2])
					t.h.exec({ "git", "commit", "-am", format[1] }, f.root)
					local head = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
					for _, side in ipairs({ "base", "saved" }) do
						requests = {}
						local done, entries, err
						require("lazyvcs.backends.blame_selection").load(
							{
								snapshot = { vcs = "git", root = f.root, revision = head, head = head },
								item = { relpath = "sample.txt" },
								path = f.file,
								side = side,
								bytes = format[2],
								first = format[3],
								last = format[3],
							},
							format[2],
							function(value, why)
								entries, err, done = value, why, true
							end
						)
						t.wait(function()
							return done
						end, "snapshot blame did not finish", 15000)
						if format[1] == "utf16" then
							assert(not entries and err, "binary snapshot was assigned editor attribution")
						else
							assert(entries and entries[format[3]] and not entries[format[3]].uncommitted, err)
							assert(#requests > 0)
						end
						for _, args in ipairs(requests) do
							assert(
								vim.tbl_contains(args, "-L") == format[4],
								format[1] .. " snapshot used the wrong Git line model: " .. table.concat(args, " ")
							)
						end
					end
				end
			end,
		},
		{
			"test_blame_file_encoder_preserves_exact_bytes",
			function()
				for _, item in ipairs({
					{ "café\nlast", profile("utf-8") },
					{ "caf\233\n", profile("latin1", "unix", true) },
					{ "caf\233\r\nlast\r\n", profile("latin1", "dos") },
					{ "\239\187\191café\n", profile("utf-8", "unix", true) },
					{ "\239\187\191", profile("utf-8", "unix", true) },
					{ "a\rb\r", profile("utf-8", "mac") },
					{ "\255\254a\0\n\0", profile("utf-16le", "unix", true) },
					{ "\254\255\0a\0\n", profile("utf-16", "unix", true) },
					{ "\0\0\254\255\0\0\0a\0\0\0\n", profile("ucs-4", "unix", true) },
					{ "\255\254\0\0a\0\0\0\n\0\0\0", profile("ucs-4le", "unix", true) },
					{ "", profile("utf-8") },
					{ "\n", profile("utf-8") },
				}) do
					local decoded = assert(text.decode(item[1], item[2], 1024))
					local bytes, err = text.encode_file(decoded, item[2], 1024)
					assert(bytes == item[1], err or ("encoder changed file bytes: " .. vim.inspect(item)))
				end
			end,
		},
		{
			"test_blame_file_capture_preserves_eof_and_buffer_state",
			function()
				local buf = api.nvim_create_buf(false, false)
				local ok, err = xpcall(function()
					api.nvim_buf_set_lines(buf, 0, -1, false, { "café", "last" })
					vim.bo[buf].fileencoding, vim.bo[buf].fileformat = "latin1", "dos"
					vim.bo[buf].endofline, vim.bo[buf].modified = false, false
					local tick, undo = api.nvim_buf_get_changedtick(buf), api.nvim_buf_call(buf, vim.fn.undotree)
					assert(assert(text.capture_file(buf, 1024)).bytes == "caf\233\r\nlast")
					assert(not vim.bo[buf].modified and not vim.bo[buf].endofline)
					assert(tick == api.nvim_buf_get_changedtick(buf))
					assert(vim.deep_equal(undo, api.nvim_buf_call(buf, vim.fn.undotree)))
					vim.bo[buf].modified = true
					assert(assert(text.capture_file(buf, 1024)).bytes == "caf\233\r\nlast\r\n")
					vim.bo[buf].fixendofline = false
					assert(assert(text.capture_file(buf, 1024)).bytes == "caf\233\r\nlast")
				end, debug.traceback)
				api.nvim_buf_delete(buf, { force = true })
				assert(ok, err)
			end,
		},
		{
			"test_blame_file_encoder_rejects_loss_and_limits",
			function()
				local doc = assert(text.decode("€\n", profile("utf-8"), 1024))
				local bytes, err = text.encode_file(doc, profile("latin1"), 1024)
				assert(not bytes and err and err:find("without loss", 1, true), "lossy conversion accepted")
				assert(not text.encode_file(doc, profile("not-an-encoding"), 1024), "invalid codec accepted")
				local empty = assert(text.decode("", profile("utf-8"), 1024))
				assert(
					not text.encode_file(empty, profile("not-an-encoding"), 1024),
					"empty content accepted an invalid codec"
				)
				assert(not text.encode_file(doc, profile("utf-16le", "unix", true), 5), "encoded limit ignored")
				local buf = api.nvim_create_buf(false, false)
				api.nvim_buf_set_lines(buf, 0, -1, false, { "éé" })
				assert(not text.capture_file(buf, 3), "decoded limit ignored")
				vim.bo[buf].binary = true
				assert(not text.capture_file(buf, 1024), "binary capture accepted")
				api.nvim_buf_delete(buf, { force = true })
			end,
		},
		{
			"test_blame_editor_formats_preserve_committed_attribution",
			function()
				local blame = require("lazyvcs.blame")
				for _, format in ipairs(formats) do
					local f, buf, win = fixture(format)
					assert(blame.blame())
					local _, inline = t.loaded(buf)
					committed(inline.entries, format[1] .. " inline")
					blame.blame_clear()
					assert(blame.blame_split())
					t.wait(function()
						local v = blame._test_blame_views()[buf]
						return v and v.winid
					end, "split absent", 15000)
					local split = blame._test_blame_views()[buf]
					local rows = api.nvim_buf_get_lines(split.bufnr, 0, -1, false)
					assert(
						#rows == 3 and not table.concat(rows):find("Uncommitted", 1, true),
						format[1] .. " split lost attribution"
					)
					api.nvim_set_current_win(win)
					blame.blame_split()
					local request = assert(require("lazyvcs.blame_selection").open(1, 3))
					t.wait(function()
						return request.entries
					end, "selection did not load", 15000)
					committed(request.entries, format[1] .. " selection")
					api.nvim_win_close(request.win, true)
					api.nvim_set_current_win(win)
					local revision = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
					for _, line in ipairs({ 1, 3 }) do
						api.nvim_win_set_cursor(win, { line, 0 })
						assert(blame.line_log())
						t.wait(function()
							local v = blame._test_line_log_views()[buf]
							return v and v.winid
						end, "line log did not open: " .. format[1], 15000)
						local view = blame._test_line_log_views()[buf]
						assert(
							vim.inspect(api.nvim_win_get_config(view.winid).title):find(revision, 1, true),
							"line log chose wrong revision"
						)
						api.nvim_win_close(view.winid, true)
					end
				end
			end,
		},
		{
			"test_blame_unsaved_edits_preserve_file_representation",
			function()
				for _, format in ipairs(formats) do
					local f, buf, _, backend = fixture(format)
					api.nvim_buf_set_lines(buf, 1, 2, false, { "unsaved" })
					vim.bo[buf].fixendofline = false
					local before = assert(text.identity(buf))
					local undo = api.nvim_buf_call(buf, vim.fn.undotree)
					local entries, err = backend_entries(f, backend, source_capture(buf))
					assert(entries, err)
					assert(
						not entries[1].uncommitted and entries[2].uncommitted and not entries[3].uncommitted,
						format[1] .. ": edit shifted attribution"
					)
					assert(
						vim.deep_equal(before, text.identity(buf))
							and vim.deep_equal(undo, api.nvim_buf_call(buf, vim.fn.undotree)),
						"blame changed buffer state"
					)
					local file = assert(io.open(f.file, "rb"))
					local bytes = file:read("*a")
					file:close()
					assert(bytes == format[2], "blame wrote the source")
					vim.bo[buf].modified = false
				end
			end,
		},
		{
			"test_svn_blame_uses_decoded_current_lines",
			function()
				local f, buf, _, backend = fixture(formats[1], true)
				api.nvim_buf_set_lines(buf, 1, 2, false, { "unsaved" })
				local entries, err = backend_entries(f, backend, source_capture(buf))
				assert(entries, err)
				assert(
					not entries[1].uncommitted and entries[2].uncommitted and not entries[3].uncommitted,
					"SVN mapped encoded bytes as editor lines"
				)
			end,
		},
		{
			"test_blame_saved_snapshot_preserves_original_bytes",
			function()
				local process = require("lazyvcs.backends.process")
				local run, run_bytes = process.lines, process.bytes
				for _, legacy in ipairs({ false, true }) do
					-- Force the pre-2.41 rejection, but run every fallback command with real Git.
					t.patch(package.loaded, "lazyvcs.backends.blame_selection", nil)
					local rejected, historical = 0, 0
					t.patch(process, "lines", function(args, opts, callback)
						if args[2] == "blame" and vim.tbl_contains(args, "--contents") and legacy then
							rejected = rejected + 1
							vim.schedule(function()
								callback(nil, "cannot use --contents with final commit object name")
							end)
							return { kill = function() end }
						end
						return run(args, opts, callback)
					end)
					-- The fallback reads the committed blob as bytes so it can decode it.
					t.patch(process, "bytes", function(args, opts, callback)
						if args[2] == "show" then
							historical = historical + 1
						end
						return run_bytes(args, opts, callback)
					end)
					for _, format in ipairs(formats) do
						local f = fixture(format)
						local head = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
						local snapshot = { vcs = "git", root = f.root, revision = head, head = head, base = "HEAD" }
						local item = { relpath = "sample.txt", status = "M" }
						local result
						require("lazyvcs.backends.compare_git").preview(snapshot, item, function(value)
							result = value
						end)
						t.wait(function()
							return result
						end, "snapshot did not load", 15000)
						local target = {
							snapshot = snapshot,
							item = item,
							path = f.file,
							side = "saved",
							first = 1,
							last = 3,
							bytes = result.right_bytes,
						}
						local done, entries, err
						require("lazyvcs.backends.blame_selection").load(
							target,
							require("lazyvcs.util").join_lines(result.right),
							function(value, why)
								entries, err, done = value, why, true
							end
						)
						t.wait(function()
							return done
						end, "snapshot blame did not load", 15000)
						assert(entries, err)
						committed(entries, format[1] .. " saved snapshot")
						write(f.file, (format[2]:gsub("second", "saved edit")))
						local compare = require("lazyvcs.compare")
						local session = assert(compare.open({ editable = false, path = f.root, base = "HEAD" }))
						t.cleanups[#t.cleanups + 1] = function()
							compare.close(session)
						end
						t.wait(function()
							return session.preview_result
						end, "Compare pane did not load", 15000)
						write(f.file, "later disk contents\n")
						api.nvim_set_current_win(session.rightwin)
						local request = assert(require("lazyvcs.blame_selection").open(1, 3))
						t.wait(function()
							return request.entries
						end, "Compare selection did not load", 15000)
						assert(
							not request.entries[1].uncommitted
								and request.entries[2].uncommitted
								and not request.entries[3].uncommitted,
							format[1]
								.. ": Compare blame lost its captured file bytes (legacy="
								.. tostring(legacy)
								.. ")"
						)
						api.nvim_win_close(request.win, true)
						compare.close(session)
					end
					if legacy then
						assert(
							rejected >= 1 and historical == 2 * #formats,
							"legacy mapping was not exercised for every format: "
								.. vim.inspect({ rejected, historical })
						)
					end
				end
			end,
		},
		{
			"test_blame_git_processing_and_unsupported_line_models",
			function()
				local f, buf, _, backend = t.open(false)
				for _, format in ipairs({
					{ "utf-8", "mac", false, "a\rb\r", false },
					{ "utf-16le", "unix", true, "\255\254a\0\n\0b\0\n\0", false },
					{ "utf-16le", "unix", true, "\255\254a\0\n\0b\0\n\0", true },
				}) do
					write(f.file, format[4])
					write(
						f.root .. "/.gitattributes",
						format[5] and "sample.txt working-tree-encoding=UTF-16\n" or "sample.txt -text\n"
					)
					t.h.exec({ "git", "add", "." }, f.root)
					t.h.exec({ "git", "commit", "--allow-empty", "-m", "representation" }, f.root)
					vim.cmd("edit! ++enc=" .. format[1] .. " ++ff=" .. format[2])
					local capture = source_capture(buf)
					local entries, err = backend_entries(f, backend, capture, { line_start = 2, line_end = 2 })
					if format[5] then
						assert(
							entries and #entries == 1 and not entries[1].uncommitted,
							err or "Git encoding attribute was bypassed"
						)
					else
						assert(
							not entries and err:find("Unsupported blame line format", 1, true),
							"incompatible Git lines were projected into editor lines"
						)
					end
				end
				local filter = f.root .. "/filter.lua"
				write(
					filter,
					'local bytes = io.read("*a"); io.write((bytes:gsub("TRAIL +", "TRAIL"))); vim.cmd("qa!")\n'
				)
				local command = "'"
					.. vim.v.progpath:gsub("'", "'\\''")
					.. "' --headless -u NONE -l '"
					.. filter:gsub("'", "'\\''")
					.. "'"
				t.h.exec({ "git", "config", "filter.blame-test.clean", command }, f.root)
				write(f.root .. "/.gitattributes", "sample.txt text eol=crlf filter=blame-test\n")
				write(f.file, "TRAIL  \r\nb\r\n")
				t.h.exec({ "git", "add", "." }, f.root)
				t.h.exec({ "git", "commit", "-m", "filter" }, f.root)
				vim.cmd("edit! ++enc=utf-8 ++ff=dos")
				local entries, err = backend_entries(f, backend, source_capture(buf))
				assert(
					entries and #entries == 2 and not entries[1].uncommitted and not entries[2].uncommitted,
					err or "Git clean filter or CRLF attribute was bypassed"
				)
			end,
		},
		{
			"test_blame_representation_identity_rejects_pending_results",
			function()
				local _, buf, win, backend = fixture(formats[1])
				local context = require("lazyvcs.blame_context")
				for _, item in ipairs({
					{ "fileencoding", "utf-8" },
					{ "fileformat", "dos" },
					{ "bomb", true },
					{ "endofline", false },
					{ "fixendofline", false },
					{ "binary", true },
					{ "modified", true },
				}) do
					local option, value = item[1], item[2]
					local captured = assert(context.capture(buf, win))
					local before = vim.bo[buf][option]
					vim.bo[buf][option] = value
					assert(not context.valid(captured), option .. " did not invalidate blame identity")
					vim.bo[buf][option] = before
				end
				local callback
				t.patch(backend, "blame_lines_async", function(_, done)
					callback = done
					return { kill = function() end }
				end)
				local request = assert(require("lazyvcs.blame_selection").open(1, 3))
				t.wait(function()
					return callback
				end, "selection backend absent", 15000)
				vim.bo[buf].bomb = true
				callback({})
				assert(not request.entries and not request.handle, "stale selection accepted")
				assert(
					table.concat(api.nvim_buf_get_lines(request.buf, 0, -1, false)):find("Source changed", 1, true),
					"selection did not report the changed representation"
				)
				api.nvim_win_close(request.win, true)
			end,
		},
	})
end
