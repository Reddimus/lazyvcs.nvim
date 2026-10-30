return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, blame = t.api, require("lazyvcs.blame")
	local function fixture()
		local f, buf, win, backend = t.open(true)
		t.h.write_file(f.file, "one\nTWO\nthree\n")
		t.h.exec({ "svn", "commit", "-m", "second line", f.file }, f.root)
		t.h.write_file(f.file, "one\nTWO\nTHREE\n")
		t.h.exec({ "svn", "commit", "-m", "third line", f.file }, f.root)
		vim.cmd("edit!")
		return f, buf, win, backend
	end
	local function save(buf, lines)
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.cmd("silent write")
	end
	local function revisions(entries)
		local out = {}
		for _, entry in ipairs(entries) do
			out[#out + 1] = entry.revision
		end
		return out
	end
	local function expect_entries(entries, expected, label)
		assert(entries, label .. ": no blame entries")
		assert(vim.deep_equal(revisions(entries), expected), label .. ": " .. vim.inspect(revisions(entries)))
		for i, revision in ipairs(expected) do
			assert((entries[i].uncommitted == true) == (revision == "-"), label .. ": wrong local marker")
		end
	end
	local function load(f, buf, backend, mode)
		local opts = { root = f.root }
		if mode ~= "disk" then
			local captured = assert(require("lazyvcs.compare_text").capture_file(buf, 1024 * 1024))
			opts.contents = captured.bytes
			if mode == "decoded" then
				opts.profile, opts.text = captured.profile, captured.text
			end
		end
		local done, rows, err
		backend.blame_lines_async(f.file, function(value, why)
			rows, err, done = value, why, true
		end, opts)
		t.wait(function()
			return done
		end, "saved SVN blame did not finish", 15000)
		assert(rows, err)
		return backend.parse_blame_entries(rows)
	end
	return t.cases({
		{
			"test_svn_blame_saved_structural_edits_keep_revision_positions",
			function()
				local f, buf, _, backend = fixture()
				for _, mode in ipairs({ "decoded", "contents", "disk" }) do
					for _, case in ipairs({
						{ "insert first", { "new", "one", "TWO", "THREE" }, { "-", "1", "2", "3" } },
						{ "insert middle", { "one", "new", "TWO", "THREE" }, { "1", "-", "2", "3" } },
						{ "insert last", { "one", "TWO", "THREE", "new" }, { "1", "2", "3", "-" } },
						{ "delete first", { "TWO", "THREE" }, { "2", "3" } },
						{ "delete middle", { "one", "THREE" }, { "1", "3" } },
						{ "delete last", { "one", "TWO" }, { "1", "2" } },
						{ "empty", {}, {} },
					}) do
						save(buf, case[2])
						expect_entries(load(f, buf, backend, mode), case[3], mode .. ": " .. case[1])
					end
				end
			end,
		},
		{
			"test_svn_blame_saved_equal_count_edits_preserve_unchanged_history",
			function()
				local f, buf, _, backend = fixture()
				for _, mode in ipairs({ "decoded", "contents", "disk" }) do
					save(buf, { "one", "new", "TWO" })
					expect_entries(load(f, buf, backend, mode), { "1", "-", "2" }, mode)
				end
				-- Unsaved contents can restore BASE while disk still contains a different row layout.
				api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "TWO", "THREE" })
				expect_entries(load(f, buf, backend, "decoded"), { "1", "2", "3" }, "unsaved restore")
			end,
		},
		{
			"test_svn_blame_saved_edits_use_file_base_in_mixed_revision_working_copy",
			function()
				local f, buf, _, backend = fixture()
				local other = t.h.tempdir() .. "/other"
				t.h.exec({ "svn", "checkout", t.h.file_url(f.repo), other }, f.root)
				t.h.write_file(other .. "/sample.txt", "remote\nTWO\nTHREE\n")
				t.h.exec({ "svn", "commit", "-m", "remote change", other .. "/sample.txt" }, other)
				t.h.exec({ "svn", "update", "--depth", "empty", "." }, f.root)
				save(buf, { "new", "one", "TWO", "THREE" })
				expect_entries(load(f, buf, backend, "decoded"), { "-", "1", "2", "3" }, "file BASE")
			end,
		},
		{
			"test_svn_blame_saved_insertions_preserve_supported_file_representations",
			function()
				for _, format in ipairs({
					{ "utf-8", "café\nTWO\nTHREE", false },
					{ "utf-8", "café\r\nTWO\r\nTHREE\r\n", false },
					{ "utf-8", "\239\187\191café\nTWO\nTHREE\n", true },
					{ "latin1", "caf\233\nTWO\nTHREE\n", false },
				}) do
					local f, buf, _, backend = fixture()
					local file = assert(io.open(f.file, "wb"))
					file:write(format[2])
					file:close()
					t.h.exec({ "svn", "commit", "-m", "file representation", f.file }, f.root)
					vim.cmd("edit! ++enc=" .. format[1])
					vim.bo[buf].fixendofline = false
					local baseline = revisions(load(f, buf, backend, "decoded"))
					assert(#baseline == 3)
					api.nvim_buf_set_lines(buf, 1, 1, false, { "new" })
					vim.cmd("silent write")
					expect_entries(
						load(f, buf, backend, "decoded"),
						{ baseline[1], "-", baseline[2], baseline[3] },
						format[1] .. ": " .. vim.bo[buf].fileformat
					)
					assert(vim.bo[buf].bomb == format[3], "blame changed the BOM option")
					local saved = assert(io.open(f.file, "rb"))
					local bytes = saved:read("*a")
					saved:close()
					assert(bytes:sub(-1) == format[2]:sub(-1), "save changed final newline state")
				end
			end,
		},
		{
			"test_svn_blame_saved_edits_use_one_bounded_command_chain",
			function()
				local f, buf, _, backend = fixture()
				local lines = { "one", "new", "TWO", "THREE" }
				for i = 1, 1000 do
					lines[#lines + 1] = "local line " .. i
				end
				save(buf, lines)
				-- Finish BufWritePost repository revalidation before counting blame's chain.
				local resolved = false
				require("lazyvcs.backends").resolve_async(f.file, function()
					resolved = true
				end, { revalidate = true })
				t.wait(function()
					return resolved
				end, "repository revalidation did not finish", 15000)
				local util, commands = require("lazyvcs.util"), {}
				local run = util.system_start
				t.patch(util, "system_start", function(args, opts, callback)
					if args[1] == "svn" then
						commands[#commands + 1] = args[2]
					end
					return run(args, opts, callback)
				end)
				local entries = load(f, buf, backend, "decoded")
				assert(#entries == #lines and entries[3].revision == "2" and entries[#lines].uncommitted)
				assert(vim.deep_equal(commands, { "status", "blame", "cat" }), vim.inspect(commands))
			end,
		},
		{
			"test_svn_blame_saved_edits_reach_inline_split_selection_and_history",
			function()
				local f, buf, win = fixture()
				save(buf, { "one", "new", "TWO", "THREE" })
				api.nvim_win_set_cursor(win, { 3, 0 })
				assert(blame.blame())
				local _, inline = t.loaded(buf)
				expect_entries(inline.entries, { "1", "-", "2", "3" }, "inline")
				local mark = assert(t.inline(buf))
				assert(mark[2] == 2 and vim.inspect(mark[4].virt_text):find("r2", 1, true), "wrong inline text")
				blame.blame_clear()
				assert(blame.blame_split())
				t.wait(function()
					local view = blame._test_blame_views()[buf]
					return view and view.winid
				end, "saved SVN split did not open", 15000)
				local split = blame._test_blame_views()[buf]
				local rows = api.nvim_buf_get_lines(split.bufnr, 0, -1, false)
				assert(#rows == 4 and rows[2]:find("Uncommitted", 1, true), "split lost local row")
				assert(rows[3]:match("^%s*2%s"), "split lost second-line revision")
				blame.blame_split()
				api.nvim_set_current_win(win)
				local request = assert(require("lazyvcs.blame_selection").open(2, 3))
				t.wait(function()
					return not request.handle
				end, "saved SVN selection did not finish", 15000)
				expect_entries({ request.entries[2], request.entries[3] }, { "-", "2" }, "selection")
				api.nvim_win_close(request.win, true)
				api.nvim_set_current_win(win)
				api.nvim_win_set_cursor(win, { 3, 0 })
				assert(blame.line_log())
				t.wait(function()
					local view = blame._test_line_log_views()[buf]
					return view and view.winid
				end, "saved SVN history did not open", 15000)
				local history = blame._test_line_log_views()[buf]
				assert(vim.inspect(api.nvim_win_get_config(history.winid).title):find("SVN 2", 1, true))
				assert(#t.notices == 0, table.concat(t.notices, "\n"))
				assert(t.h.exec({ "svn", "cat", "-r", "BASE", f.file }, f.root) == "one\nTWO\nTHREE\n")
			end,
		},
	})
end
