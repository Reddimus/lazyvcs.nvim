return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api = t.api
	local function capture(buf)
		return assert(require("lazyvcs.compare_text").capture_file(buf, 1024 * 1024))
	end
	local function result(f, backend, buf, first)
		local done, rows, err
		local c = capture(buf)
		backend.blame_lines_async(f.file, function(value, why)
			rows, err, done = value, why, true
		end, {
			root = f.root,
			contents = c.bytes,
			profile = c.profile,
			text = c.text,
			line_start = first,
			line_end = first,
		})
		t.wait(function()
			return done
		end, "blame did not finish", 15000)
		return rows, err
	end
	local function unsupported(f, buf, win, backend)
		for _, first in ipairs({ 1, #api.nvim_buf_get_lines(buf, 0, -1, false) }) do
			local rows, err = result(f, backend, buf, first)
			assert(
				not rows and err and err:find("Unsupported blame line format", 1, true),
				"unsafe line model accepted: " .. tostring(err)
			)
		end
		local blame = require("lazyvcs.blame")
		assert(blame.blame())
		t.wait(function()
			return #t.notices > 0
		end, "inline accepted unsafe attribution", 15000)
		assert(t.notices[#t.notices]:find("Unsupported blame line format", 1, true))
		blame.blame_clear()
		local count = #t.notices
		assert(blame.blame_split())
		t.wait(function()
			return #t.notices > count
		end, "split accepted unsafe attribution", 15000)
		assert(not blame._test_blame_views()[buf])
		local request = assert(require("lazyvcs.blame_selection").open(1, 1))
		t.wait(function()
			return not request.handle
		end, "selection did not finish", 15000)
		assert(
			not request.entries
				and table
					.concat(api.nvim_buf_get_lines(request.buf, 0, -1, false))
					:find("Unsupported blame line format", 1, true)
		)
		api.nvim_win_close(request.win, true)
		api.nvim_set_current_win(win)
		api.nvim_win_set_cursor(win, { 1, 0 })
		count = #t.notices
		assert(blame.line_log())
		t.wait(function()
			return #t.notices > count
		end, "history accepted unsafe attribution", 15000)
		assert(t.notices[#t.notices]:find("Unsupported blame line format", 1, true))
	end
	local function filter_fixture(mode, ident)
		local f, buf, win, backend = t.open(false)
		local script = f.root .. "/filter.lua"
		t.h.write_file(
			script,
			'local s=io.read("*a"); local rows=vim.split(s,"\\n",{plain=true}); table.remove(rows); '
				.. (mode == "drop" and 'for i=#rows,1,-1 do if rows[i]=="DROP" then table.remove(rows,i) end end; ' or mode == "reverse" and "local r={}; for i=#rows,1,-1 do r[#r+1]=rows[i] end; rows=r; " or "")
				.. 'io.write((table.concat(rows,"\\n"):gsub("[ \\t]+\\n","\\n")).."\\n"); vim.cmd("qa!")'
		)
		local function quote(s)
			return vim.fn.has("win32") == 1 and ('"' .. s:gsub('"', '\\"') .. '"')
				or ("'" .. s:gsub("'", "'\\''") .. "'")
		end
		t.h.exec({
			"git",
			"config",
			"filter.blame-model.clean",
			quote(vim.v.progpath) .. " --headless -u NONE -l " .. quote(script),
		}, f.root)
		t.h.write_file(
			f.root .. "/.gitattributes",
			"sample.txt filter=blame-model" .. (ident and " ident" or "") .. "\n"
		)
		t.h.write_file(f.file, ident and "$Id: abc123 $\nB\nC\n" or "A\nDROP\nB\nC\n")
		t.h.exec({ "git", "add", "." }, f.root)
		t.h.exec({ "git", "commit", "-m", "filter" }, f.root)
		t.h.write_file(f.file, ident and "$Id: abc123 $\nBee\nC\n" or "A\nDROP\nBee\nC\n")
		t.h.exec({ "git", "commit", "-am", "change B" }, f.root)
		t.h.write_file(f.file, ident and "$Id: abc123 $\nBee\nSee\n" or "A\nDROP\nBee\nSee\n")
		t.h.exec({ "git", "commit", "-am", "change C" }, f.root)
		vim.cmd("edit!")
		return f, buf, win, backend
	end
	local function snapshot_result(f, buf, side, bytes, item)
		local head = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
		local done, entries, err
		require("lazyvcs.backends.blame_selection").load(
			{
				snapshot = { vcs = "git", root = f.root, revision = head, head = head },
				item = item or { relpath = "sample.txt" },
				path = f.file,
				side = side,
				bytes = bytes or capture(buf).bytes,
				first = 1,
				last = 3,
			},
			"",
			function(value, why)
				entries, err, done = value, why, true
			end
		)
		t.wait(function()
			return done
		end, "snapshot blame absent", 15000)
		return entries, err
	end
	local function svn_utf16(equal_count)
		local f, buf, win, backend = t.open(true)
		local function write(value)
			local file = assert(io.open(f.file, "wb"))
			file:write("\255\254" .. vim.iconv(value, "utf-8", "utf-16le"))
			file:close()
		end
		t.h.exec({ "svn", "propset", "svn:mime-type", "text/plain", f.file }, f.root)
		write(equal_count and "A\nold" or "Ċ first\nold\n")
		t.h.exec({ "svn", "commit", "-m", "encoded", f.file }, f.root)
		write(equal_count and "A\nnew" or "Ċ first\nnew\n")
		t.h.exec({ "svn", "commit", "-m", "changed second", f.file }, f.root)
		vim.cmd("edit! ++enc=utf-16le")
		unsupported(f, buf, win, backend)
	end
	return t.cases({
		{
			"test_blame_git_saved_filter_validates_before_legacy_mapping",
			function()
				local process = require("lazyvcs.backends.process")
				local run = process.lines
				for _, legacy in ipairs({ false, true }) do
					-- Each mode starts with a fresh executable capability cache, restored by the guard.
					t.patch(package.loaded, "lazyvcs.backends.blame_selection", nil)
					local explicit, validation = 0, 0
					t.patch(process, "lines", function(args, opts, callback)
						if args[2] == "blame" and vim.tbl_contains(args, "--contents") then
							local dash = vim.fn.index(args, "--") + 1
							if args[dash - 1] ~= "-" then
								explicit = explicit + 1
								if legacy then
									vim.schedule(function()
										callback(nil, "cannot use --contents with final commit object name")
									end)
									return { kill = function() end }
								end
								-- Emulate modern Git on installations that reject a revision with --contents.
								-- The fixture's saved revision is HEAD, so the real no-revision blame is equivalent.
								args = vim.deepcopy(args)
								table.remove(args, dash - 1)
							else
								validation = validation + 1
							end
						end
						return run(args, opts, callback)
					end)
					local f, buf = filter_fixture("drop")
					local entries, err = snapshot_result(f, buf, "saved")
					assert(
						not entries and err and err:find("Unsupported blame line format", 1, true),
						"unsafe saved rows accepted"
					)
					local canonical = t.h.exec({ "git", "show", "HEAD:sample.txt" }, f.root)
					entries, err = snapshot_result(f, buf, "base", canonical)
					assert(entries and not entries[2].uncommitted, err)
					local clean, cleanbuf = filter_fixture("keep", true)
					entries, err = snapshot_result(clean, cleanbuf, "saved")
					assert(
						entries
							and not entries[1].uncommitted
							and entries[2].summary == "change B"
							and entries[3].summary == "change C",
						err
					)
					assert(explicit == (legacy and 1 or 2), "explicit-revision path was hidden by the legacy cache")
					assert(validation == (legacy and 2 or 0), "validation did not exercise the selected Git capability")
				end
			end,
		},
		{
			"test_blame_saved_legacy_filter_missing_path_fallbacks",
			function()
				t.patch(package.loaded, "lazyvcs.backends.blame_selection", nil)
				local f, buf = filter_fixture("keep", true)
				t.h.write_file(f.root .. "/.gitattributes", "* filter=blame-model ident\n")
				local process = require("lazyvcs.backends.process")
				local run = process.lines
				t.patch(process, "lines", function(args, opts, callback)
					if args[2] == "blame" and vim.tbl_contains(args, "--contents") then
						local dash = vim.fn.index(args, "--") + 1
						if args[dash - 1] ~= "-" then
							vim.schedule(function()
								callback(nil, "cannot use --contents with final commit object name")
							end)
							return { kill = function() end }
						end
					end
					return run(args, opts, callback)
				end)
				local entries, err = snapshot_result(f, buf, "saved", nil, { relpath = "missing.txt" })
				assert(entries and entries[1].uncommitted and entries[2].uncommitted and entries[3].uncommitted, err)
				entries, err =
					snapshot_result(f, buf, "saved", nil, { relpath = "renamed.txt", old_path = "sample.txt" })
				assert(
					entries
						and not entries[1].uncommitted
						and entries[2].summary == "change B"
						and entries[3].summary == "change C",
					err
				)
			end,
		},
		{
			"test_blame_filter_normalizes_only_trailing_whitespace",
			function()
				local format = require("lazyvcs.backends.blame_format")
				local oid = string.rep("a", 40)
				local function raw(line)
					return { oid .. " 1 1 1", "\t" .. line }
				end
				local opts =
					{ text = { lines = { "  A B \t" } }, profile = { fileencoding = "utf-8", fileformat = "unix" } }
				local policy = format.git_policy(opts, { filter = "strip" })
				assert(format.select(raw("  A B"), opts, policy), "trailing spaces and tabs must normalize")
				assert(not format.select(raw("A B"), opts, policy), "leading whitespace must remain significant")
				assert(not format.select(raw("  A  B"), opts, policy), "internal whitespace must remain significant")
			end,
		},
		{
			"test_blame_filter_validation_uses_configured_decode_limit",
			function()
				local format, text = require("lazyvcs.backends.blame_format"), require("lazyvcs.compare_text")
				local limit = 2 * 1024 * 1024
				t.patch(require("lazyvcs.config").get().signs, "max_file_bytes", limit)
				local decode, limits = text.decode, {}
				t.patch(text, "decode", function(bytes, profile, max_bytes)
					limits[#limits + 1] = max_bytes
					return decode(bytes, profile, max_bytes)
				end)
				local opts = { text = { lines = { "one" } }, profile = { fileencoding = "utf-8", fileformat = "unix" } }
				assert(
					format.select(
						{ string.rep("a", 40) .. " 1 1 1", "\tone" },
						opts,
						format.git_policy(opts, { filter = "strip" })
					)
				)
				assert(limits[1] == limit, "Git validation imposed a hidden 1 MiB cap")
				local f, buf, _, backend = t.open(true, { signs = { max_file_bytes = limit } })
				assert(result(f, backend, buf, 1))
				assert(limits[2] == limit, "SVN validation imposed a hidden 1 MiB cap")
			end,
		},
		{
			"test_blame_validation_ignores_small_signs_limit",
			function()
				local format = require("lazyvcs.backends.blame_format")
				t.patch(require("lazyvcs.config").get().signs, "max_file_bytes", 1)
				local opts = { text = { lines = { "one" } }, profile = { fileencoding = "utf-8", fileformat = "unix" } }
				local rows, err = format.select(
					{ string.rep("a", 40) .. " 1 1 1", "\tone" },
					opts,
					format.git_policy(opts, { filter = "strip" })
				)
				assert(rows, err or "small signs limit disabled filtered Git blame")
			end,
		},
		{
			"test_svn_blame_validation_ignores_small_signs_limit",
			function()
				local f, buf, _, backend = t.open(true, { signs = { max_file_bytes = 1 } })
				local rows, err = result(f, backend, buf, 1)
				assert(rows, err or "small signs limit disabled SVN blame")
			end,
		},
		{
			"test_blame_validation_reports_decode_size_error",
			function()
				local format = require("lazyvcs.backends.blame_format")
				local line = string.rep("x", 1024 * 1024 + 1)
				local opts = { text = { lines = { line } }, profile = { fileencoding = "utf-8", fileformat = "unix" } }
				local rows, err = format.select(
					{ string.rep("a", 40) .. " 1 1 1", "\t" .. line },
					opts,
					format.git_policy(opts, { filter = "strip" })
				)
				assert(
					not rows and err and err:find("exceeds", 1, true),
					"decode limit reported a line mismatch: " .. tostring(err)
				)
			end,
		},
		{
			"test_svn_blame_decode_encoding_and_empty_base",
			function()
				local format, text = require("lazyvcs.backends.blame_format"), require("lazyvcs.compare_text")
				for _, bytes in ipairs({ "", "one\n", "\239\187\191one\n" }) do
					local profile = { fileencoding = "utf-8", fileformat = "unix" }
					local decoded = assert(text.decode(bytes, profile, 1024))
					assert(type(decoded.encoding) == "string" and decoded.encoding:lower() == "utf-8")
					local records = bytes == "" and {} or { "record" }
					assert(format.svn_base(bytes, profile, records, 1024))
					if bytes == "" then
						assert(#decoded.lines == 0 and decoded.empty)
					end
				end
				local f, buf, _, backend = t.open(true)
				vim.fn.writefile({}, f.file)
				t.h.exec({ "svn", "commit", "-m", "empty", f.file }, f.root)
				vim.cmd("edit!")
				local rows, err = result(f, backend, buf)
				assert(rows and #rows == 0, err or "empty SVN file must have zero blame records")
			end,
		},
		{
			"test_blame_git_policy_timeout_fallback",
			function()
				local timeouts = {}
				t.patch(require("lazyvcs.backends.process"), "bytes", function(_, opts, callback)
					timeouts[#timeouts + 1] = opts.timeout
					vim.schedule(function()
						callback("")
					end)
					return { kill = function() end }
				end)
				for _, opts in ipairs({ {}, { timeout_ms = 71 } }) do
					local done
					require("lazyvcs.backends.git_blame_policy").load("/tmp", "sample.txt", opts, function(value)
						assert(value)
						done = true
					end)
					t.wait(function()
						return done
					end, "policy load did not finish")
				end
				assert(timeouts[1] == 30000 and timeouts[2] == 71, "policy must share the async timeout fallback")
			end,
		},
		{
			"test_svn_blame_rejects_utf16_byte_record_mapping",
			function()
				svn_utf16(false)
			end,
		},
		{
			"test_svn_blame_rejects_equal_count_utf16_records",
			function()
				svn_utf16(true)
			end,
		},
		{
			"test_blame_git_clean_filter_rejects_shifted_rows",
			function()
				unsupported(filter_fixture("drop"))
			end,
		},
		{
			"test_blame_git_clean_filter_rejects_equal_count_reordering",
			function()
				unsupported(filter_fixture("reverse"))
			end,
		},
		{
			"test_blame_git_ident_with_filter_keeps_attribution",
			function()
				local f, buf, _, backend = filter_fixture("keep", true)
				local rows, err = result(f, backend, buf)
				assert(rows, err)
				local entries = backend.parse_blame_entries(rows)
				assert(
					#entries == 3
						and not entries[1].uncommitted
						and entries[2].summary == "change B"
						and entries[3].summary == "change C"
				)
			end,
		},
	})
end
