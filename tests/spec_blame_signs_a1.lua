return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local s = require("signs_helpers")(ctx)
	local api, text = vim.api, require("lazyvcs.compare_text")
	local function write_bytes(path, bytes)
		local file = assert(io.open(path, "wb"))
		file:write(bytes)
		file:close()
	end
	local function captured(buf)
		return assert(text.capture_file(buf, 1024 * 1024))
	end
	local function selection(target)
		local done, entries, err
		require("lazyvcs.backends.blame_selection").load(target, target.bytes, function(value, why)
			entries, err, done = value, why, true
		end)
		t.wait(function()
			return done
		end, "selection did not finish", 15000)
		return entries, err
	end
	local function snapshot(f, buf, svn, side)
		local c = captured(buf)
		local revision = svn and "3" or vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
		return {
			snapshot = {
				vcs = svn and "svn" or "git",
				root = f.root,
				revision = revision,
				head = revision,
				url = svn and t.h.file_url(f.repo) or nil,
			},
			item = { relpath = "sample.txt" },
			path = f.file,
			side = side,
			bytes = c.bytes,
			text = c.text,
			first = 1,
			last = #c.text.lines,
		}
	end
	local cases = t.cases({
		{
			"test_svn_blame_base_preview_rejects_unsupported_documents",
			function()
				for _, value in ipairs({ "Ċ first\nold\nlast\n", "first\nold\nlast" }) do
					local f, buf = t.open(true)
					t.h.exec({ "svn", "propset", "svn:mime-type", "text/plain", f.file }, f.root)
					local function write(content)
						local file = assert(io.open(f.file, "wb"))
						file:write("\255\254" .. vim.iconv(content, "utf-8", "utf-16le"))
						file:close()
					end
					write(value)
					t.h.exec({ "svn", "commit", "-m", "encoded", f.file }, f.root)
					write(value:gsub("old", "SECOND"))
					t.h.exec({ "svn", "commit", "-m", "second", f.file }, f.root)
					vim.cmd("edit! ++enc=utf-16le")
					local target = snapshot(f, buf, true, "base")
					local entries, err = selection(target)
					assert(
						not entries and err and err:find("Unsupported blame line format", 1, true),
						"unsafe BASE preview accepted"
					)
				end
			end,
		},
		{
			"test_svn_blame_eof_edits_preserve_document_mapping",
			function()
				for _, base_eol in ipairs({ false, true }) do
					local f, buf, _, backend = t.open(true)
					write_bytes(f.file, "first\nlast" .. (base_eol and "\n" or ""))
					t.h.exec({ "svn", "commit", "-m", "EOF base", f.file }, f.root)
					vim.cmd("edit!")
					vim.bo[buf].fixendofline, vim.bo[buf].endofline = false, not base_eol
					vim.cmd("silent write")
					for _, mode in ipairs({ "decoded", "contents", "disk", "preview" }) do
						local c, done, rows, err = captured(buf)
						local opts = { root = f.root }
						if mode ~= "disk" then
							opts.contents = c.bytes
						end
						if mode == "decoded" then
							opts.text, opts.profile = c.text, c.profile
						end
						if mode == "preview" then
							opts.text, opts.preview = c.text, true
						end
						backend.blame_lines_async(f.file, function(value, why)
							rows, err, done = value, why, true
						end, opts)
						t.wait(function()
							return done
						end, "EOF blame absent", 15000)
						local entries = rows and backend.parse_blame_entries(rows)
						assert(
							entries and #entries == 2 and not entries[1].uncommitted and entries[2].uncommitted,
							mode .. ": EOF edit kept historical attribution: " .. tostring(err)
						)
					end
					-- Removing an unterminated last line leaves the surviving line unchanged.
					if not base_eol then
						api.nvim_buf_set_lines(buf, 1, -1, false, {})
						vim.bo[buf].endofline = true
						local c, done, rows = captured(buf)
						backend.blame_lines_async(f.file, function(value)
							rows, done = value, true
						end, { root = f.root, contents = c.bytes, text = c.text, profile = c.profile })
						t.wait(function()
							return done
						end, "deletion blame absent", 15000)
						assert(
							rows and not backend.parse_blame_entries(rows)[1].uncommitted,
							"unchanged surviving line lost history"
						)
					end
				end
			end,
		},
		{
			"test_blame_git_saved_preview_uses_decoded_utf16",
			function()
				local process = require("lazyvcs.backends.process")
				local run = process.lines
				for _, legacy in ipairs({ false, true }) do
					t.patch(package.loaded, "lazyvcs.backends.blame_selection", nil)
					t.patch(process, "lines", function(args, opts, callback)
						if args[2] == "blame" and vim.tbl_contains(args, "--contents") and legacy then
							vim.schedule(function()
								callback(nil, "cannot use --contents with final commit object name")
							end)
							return { kill = function() end }
						end
						return run(args, opts, callback)
					end)
					for _, encoding in ipairs({ { "utf-16le", "UTF-16", true }, { "latin1", "ISO-8859-1", false } }) do
						local f, buf = t.open(false)
						t.h.write_file(
							f.root .. "/.gitattributes",
							"sample.txt working-tree-encoding=" .. encoding[2] .. "\n"
						)
						vim.bo[buf].fileencoding, vim.bo[buf].bomb = encoding[1], encoding[3]
						api.nvim_buf_set_lines(buf, 0, -1, false, { "café", "two", "three" })
						vim.cmd("silent write")
						t.h.exec({ "git", "add", "." }, f.root)
						t.h.exec({ "git", "commit", "-m", "encoded" }, f.root)
						api.nvim_buf_set_lines(buf, 1, 2, false, { "changed" })
						vim.cmd("silent write")
						local entries, err = selection(snapshot(f, buf, false, "saved"))
						assert(
							entries
								and not entries[1].uncommitted
								and entries[2].uncommitted
								and not entries[3].uncommitted,
							"decoded saved preview failed: " .. tostring(err)
						)
					end
				end
			end,
		},
		{
			"test_blame_git_renamed_line_history_contains_commit",
			function()
				local f, buf, win, backend = t.open(false)
				local revision = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
				t.h.exec({ "git", "mv", "sample.txt", "renamed.txt" }, f.root)
				t.h.exec({ "git", "commit", "-m", "rename" }, f.root)
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/renamed.txt"))
				buf = api.nvim_get_current_buf()
				local rows, err = backend.revision_log(f.root .. "/renamed.txt", revision)
				assert(
					rows and table.concat(rows, "\n"):find(revision, 1, true),
					"renamed synchronous history empty: " .. tostring(err)
				)
				api.nvim_win_set_cursor(win, { 1, 0 })
				assert(require("lazyvcs.blame").line_log())
				t.wait(function()
					local v = require("lazyvcs.blame")._test_line_log_views()[buf]
					return v and v.winid
				end, "history absent", 15000)
				local v = require("lazyvcs.blame")._test_line_log_views()[buf]
				assert(
					table.concat(api.nvim_buf_get_lines(v.bufnr, 0, -1, false), "\n"):find(revision, 1, true),
					"renamed popup empty"
				)
			end,
		},
		{
			"test_blame_git_line_history_forces_utf8",
			function()
				local f, buf, _, backend = t.open(false)
				t.h.exec({ "git", "config", "user.name", "José" }, f.root)
				t.h.exec({ "git", "config", "i18n.logOutputEncoding", "ISO-8859-1" }, f.root)
				t.h.write_file(f.file, "café\ntwo\nthree\n")
				t.h.exec({ "git", "commit", "-am", "café" }, f.root)
				vim.cmd("edit!")
				local revision = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
				local rows = assert(backend.revision_log(f.file, revision))
				assert(
					table.concat(rows, "\n"):find("José", 1, true) and table.concat(rows, "\n"):find("café", 1, true),
					"history contains legacy bytes"
				)
				assert(require("lazyvcs.blame").line_log())
				t.wait(function()
					local v = require("lazyvcs.blame")._test_line_log_views()[buf]
					return v and v.winid
				end, "UTF8 history absent", 15000)
				local v = require("lazyvcs.blame")._test_line_log_views()[buf]
				local content = table.concat(api.nvim_buf_get_lines(v.bufnr, 0, -1, false), "\n")
				assert(content:find("José", 1, true) and content:find("café", 1, true), "popup contains legacy bytes")
			end,
		},
		{
			"test_blame_split_mirrors_diagnostic_virtual_rows",
			function()
				local _, buf, win = t.open(false)
				local ns = api.nvim_create_namespace("lazyvcs_a1_diagnostics")
				t.cleanups[#t.cleanups + 1] = function()
					vim.diagnostic.reset(ns, buf)
				end
				vim.diagnostic.config({ virtual_lines = true, virtual_text = false }, ns)
				vim.diagnostic.set(
					ns,
					buf,
					{ { lnum = 0, col = 0, message = "first\nsecond", severity = vim.diagnostic.severity.ERROR } }
				)
				assert(require("lazyvcs.blame").blame_split())
				t.wait(function()
					local v = require("lazyvcs.blame")._test_blame_views()[buf]
					return v and v.winid
				end, "split absent", 15000)
				local v = require("lazyvcs.blame")._test_blame_views()[buf]
				local function aligned(first, last)
					t.wait(function()
						vim.cmd.redraw()
						for line = first or 1, last or 3 do
							local a, b = vim.fn.screenpos(win, line, 1).row, vim.fn.screenpos(v.winid, line, 1).row
							if a == 0 or a ~= b then
								return false
							end
						end
						return true
					end, "virtual rows misalign attribution", 1000)
				end
				aligned()
				vim.diagnostic.config({ virtual_lines = false }, ns)
				vim.wait(100)
				aligned()
				vim.diagnostic.config({ virtual_lines = { current_line = true } }, ns)
				api.nvim_win_set_cursor(win, { 2, 0 })
				api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
				vim.wait(100)
				aligned()
				api.nvim_win_set_cursor(win, { 1, 0 })
				api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
				vim.wait(100)
				aligned()
				vim.diagnostic.config({ virtual_lines = true }, ns)
				aligned()
				api.nvim_win_call(win, function()
					vim.fn.winrestview({ lnum = 2, topline = 2, topfill = 1 })
				end)
				api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
				aligned(2, 3)
				local source_view = api.nvim_win_call(win, vim.fn.winsaveview)
				local blame_view = api.nvim_win_call(v.winid, vim.fn.winsaveview)
				assert(source_view.topfill == 1 and blame_view.topfill == 1, "virtual viewport offset was lost")
				vim.diagnostic.reset(ns, buf)
				api.nvim_win_call(win, function()
					vim.fn.winrestview({ lnum = 1, topline = 1, topfill = 0 })
				end)
				aligned()
			end,
		},
		{
			"test_blame_split_skips_invalid_virtual_rows_and_restores_them_on_undo",
			function()
				local _, buf, win = t.open(false)
				local ns = api.nvim_create_namespace("lazyvcs_a1_invalid_virtual_rows")
				t.cleanups[#t.cleanups + 1] = function()
					if api.nvim_buf_is_valid(buf) then
						api.nvim_buf_clear_namespace(buf, ns, 0, -1)
					end
				end
				local mark = api.nvim_buf_set_extmark(buf, ns, 0, 0, {
					end_row = 1,
					invalidate = true,
					virt_lines = { { { "virtual row", "Normal" } } },
				})
				local blame = require("lazyvcs.blame")
				assert(blame.blame_split())
				t.wait(function()
					local v = blame._test_blame_views()[buf]
					return v and v.winid
				end, "split absent", 15000)
				local v = blame._test_blame_views()[buf]
				local function aligned(count)
					t.wait(function()
						vim.cmd.redraw()
						if api.nvim_buf_line_count(v.bufnr) ~= count then
							return false
						end
						for line = 1, count do
							local a = vim.fn.screenpos(win, line, 1).row
							local b = vim.fn.screenpos(v.winid, line, 1).row
							if a == 0 or a ~= b then
								return false
							end
						end
						return true
					end, "invalidated virtual rows misalign attribution", 15000)
				end
				aligned(3)
				assert(vim.fn.screenpos(win, 2, 1).row == vim.fn.screenpos(win, 1, 1).row + 2)
				vim.cmd("normal! ggdd")
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				local details = api.nvim_buf_get_extmark_by_id(buf, ns, mark, { details = true })[3]
				-- Neovim 0.11 keeps virtual-line marks visible after their range is deleted.
				local invalidates = vim.fn.has("nvim-0.12") == 1
				assert(details and (details.invalid or false) == invalidates, "unexpected extmark invalidation state")
				aligned(2)
				local gap = invalidates and 1 or 2
				assert(vim.fn.screenpos(win, 2, 1).row == vim.fn.screenpos(win, 1, 1).row + gap)
				vim.cmd("silent undo")
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				details = api.nvim_buf_get_extmark_by_id(buf, ns, mark, { details = true })[3]
				assert(details and not details.invalid, "undo did not restore the virtual-line extmark")
				aligned(3)
				assert(vim.fn.screenpos(win, 2, 1).row == vim.fn.screenpos(win, 1, 1).row + 2)
			end,
		},
		{
			"test_files_picker_contains_deferred_switch_errors",
			function()
				local f, buf, win = t.open(false)
				local picker, choose = require("lazyvcs.picker"), nil
				t.patch(picker, "select", function(_, _, callback)
					choose = callback
				end)
				local hidden = vim.o.hidden
				t.cleanups[#t.cleanups + 1] = function()
					vim.o.hidden = hidden
					if api.nvim_win_is_valid(win) then
						require("lazyvcs.util").set_win_option(win, "winfixbuf", false)
					end
				end
				for _, mode in ipairs({ "winfixbuf", "modified" }) do
					require("lazyvcs.util").set_win_option(win, "winfixbuf", false)
					choose = nil
					require("lazyvcs.buffer_ops").files()
					t.wait(function()
						return choose ~= nil
					end, "files picker absent", 15000)
					if mode == "winfixbuf" then
						require("lazyvcs.util").set_win_option(win, "winfixbuf", true)
					else
						require("lazyvcs.util").set_win_option(win, "winfixbuf", false)
						vim.o.hidden = false
						api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved" })
					end
					local count = #t.notices
					local done, ok, err
					vim.schedule(function()
						ok, err = pcall(assert(choose), { absolute_path = f.root .. "/other.txt" })
						done = true
					end)
					t.wait(function()
						return done
					end, "selection callback absent")
					assert(ok, "picker callback escaped: " .. tostring(err))
					assert(
						api.nvim_win_get_buf(win) == buf
							and #t.notices == count + 1
							and not t.notices[#t.notices]:find("\n"),
						"switch refusal was not reported once"
					)
				end
			end,
		},
	})
	for _, svn in ipairs({ false, true }) do
		cases[#cases + 1] = {
			(svn and "test_svn_" or "test_") .. "signs_revert_unterminated_trailing_empty_row",
			s.guard(function()
				local f, buf = s.fixture(svn)
				write_bytes(f.file, "alpha")
				s.h.exec(svn and { "svn", "commit", "-m", "no EOF", f.file } or { "git", "add", "sample.txt" }, f.root)
				vim.cmd("edit!")
				vim.bo[buf].fixendofline = false
				vim.cmd("normal! Go")
				assert(vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), { "alpha", "" }))
				s.refresh(buf, true)
				api.nvim_win_set_cursor(0, { 1, 0 })
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return (s.signs.current_state(buf).native_holds or 0) == 0
				end, "revert absent", 15000)
				assert(
					vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), { "alpha" }),
					"revert left terminal empty row"
				)
				assert(not vim.bo[buf].endofline)
				vim.cmd("silent write")
				assert(table.concat(vim.fn.readfile(f.file, "b"), "\n") == "alpha", "saved revert changed EOF")
			end),
		}
	end
	for _, phase in ipairs({ "mutation", "reload" }) do
		cases[#cases + 1] = {
			"test_signs_obsolete_worker_preserves_command_during_" .. phase,
			s.guard(function()
				local f, buf = s.fixture(false)
				s.refresh(buf, true)
				local work, deliver
				vim.uv.new_work = function(_, callback)
					work = {
						queue = function()
							return true
						end,
					}
					deliver = callback
					return work
				end
				local lines = {}
				for i = 1, 10000 do
					lines[i] = "row " .. i
				end
				api.nvim_buf_set_lines(buf, 0, -1, false, lines)
				api.nvim_win_set_cursor(0, { 1, 0 })
				vim.cmd("LazyVCS hunk next")
				assert(deliver, "large diff worker absent")
				local state = s.signs.current_state(buf)
				assert(state.compute_waiters and #state.compute_waiters > 0)
				local change = s.signs.begin_base_change(f.root)
				local backends, load = require("lazyvcs.backends"), require("lazyvcs.backends").load_base_async
				local held
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_base_async = function(_, callback)
					held = callback
					return { kill = function() end }
				end
				if phase == "reload" then
					s.signs.finish_base_change(change)
					s.wait(function()
						return held ~= nil
					end, "replacement base absent", 15000)
				end
				deliver(true, vim.mpack.encode({ { 1, 3, 1, 10000 } }))
				vim.wait(30)
				assert(
					state.compute_waiters and #state.compute_waiters > 0 and state.native_holds > 0,
					"obsolete worker consumed pending command"
				)
				if phase == "mutation" then
					s.signs.finish_base_change(change)
					s.wait(function()
						return held ~= nil
					end, "settlement load absent", 15000)
				end
				-- Keep worker completion deterministic for the replacement comparison.
				held({ root = f.root, relpath = "sample.txt", base_lines = { "one", "two", "three" } })
				if state.computing then
					deliver(true, vim.mpack.encode({ { 1, 3, 1, 10000 } }))
				end
				backends.load_base_async = load
				s.wait(function()
					return (state.native_holds or 0) == 0
				end, "waiting command did not resume", 15000)
			end),
		}
	end
	cases[#cases + 1] = {
		"test_signs_large_render_yields_and_cancels_obsolete_batches",
		s.guard(function()
			local _, buf = s.fixture(false)
			s.refresh(buf, true)
			local lines = {}
			for i = 1, 100000 do
				lines[i] = "x"
			end
			local set, delete = api.nvim_buf_set_extmark, api.nvim_buf_del_extmark
			local calls, per_turn, maximum = 0, 0, 0
			local function count_operation()
				per_turn = per_turn + 1
				maximum = math.max(maximum, per_turn)
				if per_turn == 1 then
					vim.schedule(function()
						per_turn = 0
					end)
				end
			end
			local active, heartbeat, largest_gap, last = true, 0, 0, vim.uv.hrtime()
			local timer = assert(vim.uv.new_timer())
			timer:start(
				1,
				1,
				vim.schedule_wrap(function()
					if not active then
						return
					end
					heartbeat = heartbeat + 1
					local now = vim.uv.hrtime()
					largest_gap, last = math.max(largest_gap, (now - last) / 1e6), now
				end)
			)
			---@diagnostic disable-next-line: duplicate-set-field
			api.nvim_buf_set_extmark = function(b, ns, row, col, opts)
				if b == buf and opts.sign_text then
					calls = calls + 1
					count_operation()
				end
				return set(b, ns, row, col, opts)
			end
			---@diagnostic disable-next-line: duplicate-set-field
			api.nvim_buf_del_extmark = function(b, ns, id)
				if b == buf then
					count_operation()
				end
				return delete(b, ns, id)
			end
			local ok, err = xpcall(function()
				s.edit(buf, lines)
				s.refresh(buf, false)
				s.wait(function()
					return calls >= #lines
				end, "large signs did not finish", 15000)
				assert(maximum <= 1000, "sign rendering monopolized one turn: " .. maximum)
				assert(heartbeat > 1, "rendering did not yield to timers")
				print(
					string.format(
						"SIGN_RENDER heartbeat=%d max_gap_ms=%.1f max_marks_per_turn=%d",
						heartbeat,
						largest_gap,
						maximum
					)
				)
				-- A changed buffer must cancel its pending decorations.
				s.edit(buf, { "one", "changed", "three" })
				s.refresh(buf, false)
				s.wait(function()
					return s.signs.current_state(buf).sign_render == nil
				end, "obsolete decorations survived replacement", 15000)
				assert(#s.marks(buf) == 1, "replacement retained obsolete signs")
				local before = calls
				s.edit(buf, lines)
				s.signs.refresh(buf, false)
				s.wait(function()
					return calls > before
				end, "replacement batch did not start", 15000)
				assert(calls < before + #lines, "replacement batch did not yield")
				s.edit(buf, { "one", "changed", "three" })
				s.signs.refresh(buf, false)
				s.wait(function()
					return not s.signs.current_state(buf).sign_render and #s.signs.current_state(buf).hunks == 1
				end, "superseded batch did not retire", 15000)
				assert(#s.marks(buf) == 1, "superseded batch restored old signs")
				assert(maximum <= 1000, "sign deletion monopolized one turn: " .. maximum)
				api.nvim_buf_delete(buf, { force = true })
				vim.wait(30)
			end, debug.traceback)
			active = false
			timer:stop()
			timer:close()
			api.nvim_buf_set_extmark, api.nvim_buf_del_extmark = set, delete
			assert(ok, err)
		end),
	}
	return cases
end
