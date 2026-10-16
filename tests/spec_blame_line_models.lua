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
	local function snapshot_result(f, buf, side, bytes)
		local head = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
		local done, entries, err
		require("lazyvcs.backends.blame_selection").load(
			{
				snapshot = { vcs = "git", root = f.root, revision = head, head = head },
				item = { relpath = "sample.txt" },
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
				local f, buf = filter_fixture("drop")
				local entries, err = snapshot_result(f, buf, "saved")
				assert(
					not entries and err and err:find("Unsupported blame line format", 1, true),
					"saved filter accepted unsafe rows"
				)
				local process = require("lazyvcs.backends.process")
				local run = process.lines
				t.patch(process, "lines", function(args, opts, callback)
					if args[2] == "blame" and vim.tbl_contains(args, "--contents") and args[#args - 2] ~= "-" then
						-- Older Git rejects --contents with an explicit revision.
						local dash = vim.fn.index(args, "--") + 1
						if args[dash - 1] ~= "-" then
							vim.schedule(require("lazyvcs.util").safe_callback(function()
								callback(nil, "cannot use --contents with final commit object name")
							end))
							return { kill = function() end }
						end
					end
					return run(args, opts, callback)
				end)
				entries, err = snapshot_result(f, buf, "saved")
				assert(
					not entries and err and err:find("Unsupported blame line format", 1, true),
					"legacy mapping accepted unsafe rows"
				)
				-- The legacy capability cache may already have selected the fallback.
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
