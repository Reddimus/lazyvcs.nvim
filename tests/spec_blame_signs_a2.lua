return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local s = require("signs_helpers")(ctx)
	local api, blame = vim.api, require("lazyvcs.blame")
	local function write_bytes(path, bytes)
		local file = assert(io.open(path, "wb"))
		file:write(bytes)
		file:close()
	end
	local function split(buf)
		assert(blame.blame_split())
		t.wait(function()
			local v = blame._test_blame_views()[buf]
			return v and v.winid
		end, "split absent", 15000)
		return blame._test_blame_views()[buf]
	end
	local function folds()
		local saved = {}
		for _, name in ipairs({ "foldmethod", "foldexpr", "foldlevel", "foldenable" }) do
			saved[name] = { vim.api.nvim_get_option_value(name, { scope = "global" }), vim.wo[name] }
		end
		t.cleanups[#t.cleanups + 1] = function()
			for name, values in pairs(saved) do
				api.nvim_set_option_value(name, values[1], { scope = "global" })
				vim.wo[name] = values[2]
			end
		end
		vim.cmd("set foldmethod=expr foldexpr=1 foldlevel=0 foldenable")
	end
	local function commit_reloads(svn)
		local f, buf, win = t.open(svn, { source_control = { confirm_mutations = false } })
		api.nvim_win_set_cursor(win, { 2, 0 })
		blame.blame()
		local _, before = t.loaded(buf)
		assert(before.entries[2].uncommitted)
		local v = split(buf)
		assert(api.nvim_buf_get_lines(v.bufnr, 1, 2, false)[1]:find("Uncommitted", 1, true))
		if not svn then
			t.h.exec({ "git", "add", "sample.txt" }, f.root)
		end
		require("lazyvcs.source_control.ops").commit_repo({
			path = f.root,
			lazyvcs_repo_cache = {
				[f.root] = {
					root = f.root,
					name = "fixture",
					vcs = svn and "svn" or "git",
					counts = { staged = svn and 0 or 1, local_changes = 1 },
				},
			},
			lazyvcs_commit_drafts = { [f.root] = "blame regression" },
			lazyvcs_render = function() end,
		}, { path = f.root })
		t.wait(function()
			local job = require("lazyvcs.state").get_repo_job(f.root)
			return not job or job.status ~= "running"
		end, "commit did not settle", 15000)
		t.wait(function()
			local _, live = t.inline(buf)
			return live
				and live.entries
				and not live.entries[2].uncommitted
				and not api.nvim_buf_get_lines(v.bufnr, 1, 2, false)[1]:find("Uncommitted", 1, true)
		end, "commit left stale inline or split blame", 2000)
	end
	local cases = t.cases({
		{
			"test_svn_blame_commit_reloads_inline_and_split",
			function()
				commit_reloads(true)
			end,
		},
		{
			"test_blame_commit_reloads_inline_and_split",
			function()
				commit_reloads(false)
			end,
		},
		{
			"test_blame_split_aligns_native_diff_filler",
			function()
				local _, buf, win = t.open(false)
				t.cleanups[#t.cleanups + 1] = function()
					vim.cmd("diffoff!")
				end
				vim.cmd("leftabove vnew")
				local other = api.nvim_get_current_win()
				api.nvim_win_set_width(other, 20)
				api.nvim_buf_set_lines(0, 0, -1, false, { "one", "inserted", "changed", "three" })
				vim.cmd("diffthis")
				api.nvim_set_current_win(win)
				vim.cmd("diffthis")
				vim.cmd("diffupdate")
				assert(vim.fn.diff_filler(2) == 1, "fixture has no filler")
				local v = split(buf)
				local function aligned()
					t.wait(function()
						vim.cmd.redraw()
						return vim.fn.screenpos(win, 2, 1).row == vim.fn.screenpos(v.winid, 2, 1).row
					end, "native filler misaligns blame", 1000)
				end
				aligned()
				api.nvim_win_call(win, function()
					vim.fn.winrestview({ lnum = 2, topline = 2, topfill = 1 })
				end)
				api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win) })
				aligned()
				assert(api.nvim_win_call(v.winid, vim.fn.winsaveview).topfill == 1, "filler scroll offset lost")
				api.nvim_buf_set_lines(api.nvim_win_get_buf(other), 1, 2, false, {})
				vim.cmd("diffupdate")
				aligned()
				assert(vim.wo[win].diff and vim.wo[other].diff, "blame changed the diff session")
			end,
		},
		{
			"test_blame_hidden_tab_skips_virtual_row_reads",
			function()
				local _, buf, win = t.open(false)
				local v = split(buf)
				local tab = api.nvim_get_current_tabpage()
				local get, reads = api.nvim_buf_get_extmarks, 0
				t.patch(api, "nvim_buf_get_extmarks", function(b, ns, first, last, opts)
					if b == buf and opts and opts.type == "virt_lines" then
						reads = reads + 1
					end
					return get(b, ns, first, last, opts)
				end)
				vim.cmd("tabnew")
				vim.wait(50)
				reads = 0
				local ns = api.nvim_create_namespace("lazyvcs_a2_hidden")
				api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_lines = { { { "hidden change", "Normal" } } } })
				for _ = 1, 3 do
					vim.cmd.redraw()
				end
				assert(reads == 0, "hidden blame scanned source extmarks: " .. reads)
				api.nvim_set_current_tabpage(tab)
				t.wait(function()
					vim.cmd.redraw()
					return vim.fn.screenpos(win, 2, 1).row == vim.fn.screenpos(v.winid, 2, 1).row
				end, "visible blame did not reconcile padding", 1000)
				assert(reads > 0)
			end,
		},
		{
			"test_blame_selection_disables_inherited_folds",
			function()
				local _, _, win = t.open(false)
				folds()
				local request = assert(require("lazyvcs.blame_selection").open(1, 3))
				t.wait(function()
					return not request.handle
				end, "selection absent", 15000)
				assert(request.entries, "selection failed")
				assert(api.nvim_win_call(request.win, function()
					return vim.fn.foldclosed(1)
				end) == -1, "report is folded")
				assert(vim.wo[win].foldenable and vim.go.foldenable, "report changed source/global folds")
				api.nvim_win_close(request.win, true)
			end,
		},
		{
			"test_blame_split_reserves_date_cells",
			function()
				for _, author in ipairs({
					"Ordinary Author",
					"A very long author name that exceeds the split",
					"長い著者の名前と追加の文字列",
				}) do
					local f, buf = t.open(false)
					t.h.exec({ "git", "config", "user.name", author }, f.root)
					t.h.write_file(f.file, "authored one\nauthored two\nauthored three\n")
					t.h.exec({ "git", "commit", "-am", "authored" }, f.root)
					vim.cmd("edit!")
					local v = split(buf)
					local line = api.nvim_buf_get_lines(v.bufnr, 0, 1, false)[1]
					local width = api.nvim_win_get_width(v.winid)
					assert(vim.fn.strdisplaywidth(line) <= width, "date clipped at width " .. width .. ": " .. line)
					assert(line:match("%d%d%d%d%-%d%d%-%d%d$"), "complete date absent")
					blame.blame_split()
				end
			end,
		},
	})
	cases[#cases + 1] = {
		"test_blame_history_change_cancels_pending_and_scopes_reloads",
		t.guard(function()
			local f, buf, _, backend = t.open(false)
			local run, pending, killed = backend.blame_lines_async, {}, 0
			t.patch(backend, "blame_lines_async", function(_, callback)
				pending[#pending + 1] = callback
				return {
					kill = function()
						killed = killed + 1
					end,
				}
			end)
			blame.blame()
			assert(blame.blame_split())
			t.wait(function()
				return #pending == 2
			end, "pending views absent", 15000)
			local _, inline = t.inline(buf)
			local v = blame._test_blame_views()[buf]
			local inline_generation, split_generation = inline.generation, v.generation
			local unrelated = blame.begin_history_change(t.h.tempdir())
			blame.finish_history_change(unrelated)
			assert(
				inline.generation == inline_generation and v.generation == split_generation,
				"unrelated root invalidated blame"
			)
			local change = blame.begin_history_change(f.root)
			assert(killed == 2, "mutation did not cancel pending views")
			local stale = assert(backend.blame_lines(f.file))
			for _, callback in ipairs(pending) do
				callback(stale)
			end
			api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
			vim.wait(60)
			assert(not inline.entries and not v.winid and #pending == 2, "unsettled history published or reloaded")
			t.patch(backend, "blame_lines_async", run)
			blame.finish_history_change(change)
			blame.finish_history_change(change)
			t.loaded(buf)
			t.wait(function()
				return v.winid
			end, "settled split did not reload", 15000)
		end),
	}
	cases[#cases + 1] = {
		"test_blame_split_narrow_width_keeps_date",
		t.guard(function()
			for _, width in ipairs({ 24, 20, 16, 10 }) do
				local f, buf = t.open(false, { blame = { split_min_width = 10, split_max_width = width } })
				t.h.exec({ "git", "commit", "-am", "committed" }, f.root)
				local v = split(buf)
				local line = api.nvim_buf_get_lines(v.bufnr, 0, 1, false)[1]
				assert(vim.fn.strdisplaywidth(line) <= width, "narrow row overflowed")
				assert(line:match("%d%d%d%d%-%d%d%-%d%d$"), "narrow split clipped date")
				blame.blame_split()
			end
		end),
	}
	cases[#cases + 1] = {
		"test_blame_split_clamped_width_keeps_date",
		t.guard(function()
			local columns = vim.o.columns
			t.cleanups[#t.cleanups + 1] = function()
				vim.o.columns = columns
			end
			local f, buf = t.open(false)
			t.h.exec({ "git", "commit", "-am", "committed" }, f.root)
			vim.o.columns = 20
			vim.cmd("vsplit | only")
			local v = split(buf)
			local line = api.nvim_buf_get_lines(v.bufnr, 0, 1, false)[1]
			assert(vim.fn.strdisplaywidth(line) <= api.nvim_win_get_width(v.winid), "clamped split overflowed")
			assert(line:match("%d%d%d%d%-%d%d%-%d%d$"), "clamped split clipped date")
		end),
	}
	for _, variant in ipairs({ "latin1", "bom", "eof", "normalized", "encoding_change", "cp1252" }) do
		cases[#cases + 1] = {
			"test_blame_legacy_saved_document_" .. variant,
			t.guard(function()
				local f, buf = t.open(false)
				local bytes = variant == "cp1252" and "price \128\ntwo\nthree\n"
					or variant == "encoding_change" and "café\ntwo\nthree\n"
					or variant == "latin1" and "caf\233\ntwo\nthree\n"
					or variant == "bom" and "\239\187\191one\ntwo\nthree\n"
					or "one\ntwo\nthree\n"
				if variant == "normalized" then
					t.h.write_file(f.root .. "/.gitattributes", "sample.txt working-tree-encoding=UTF-16\n")
					bytes = "\255\254" .. vim.iconv(bytes, "utf-8", "utf-16le")
				end
				write_bytes(f.file, bytes)
				t.h.exec({ "git", "add", "." }, f.root)
				t.h.exec({ "git", "commit", "--allow-empty", "-m", "encoded" }, f.root)
				if variant == "encoding_change" then
					write_bytes(f.file, "caf\233\ntwo\nthree\n")
				end
				vim.cmd(
					variant == "cp1252" and "edit! ++enc=cp1252"
						or (variant == "latin1" or variant == "encoding_change") and "edit! ++enc=latin1"
						or "edit!"
				)
				if variant == "eof" then
					vim.bo[buf].fixendofline, vim.bo[buf].endofline = false, false
				end
				local c = assert(require("lazyvcs.compare_text").capture_file(buf, 1048576))
				local backend = require("lazyvcs.backends.blame_selection")
				backend._test_reset_legacy_git()
				t.cleanups[#t.cleanups + 1] = backend._test_reset_legacy_git
				local process = require("lazyvcs.backends.process")
				local run = process.lines
				t.patch(process, "lines", function(args, opts, callback)
					if args[2] == "blame" and vim.tbl_contains(args, "--contents") then
						vim.schedule(function()
							callback(nil, "cannot use --contents with final commit object name")
						end)
						return { kill = function() end }
					end
					return run(args, opts, callback)
				end)
				local revision = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
				local done, entries, err
				backend.load(
					{
						snapshot = { vcs = "git", root = f.root, head = revision },
						item = { relpath = "sample.txt" },
						path = f.file,
						side = "saved",
						bytes = c.bytes,
						text = c.text,
						first = 1,
						last = 3,
					},
					c.bytes,
					function(value, why)
						entries, err, done = value, why, true
					end
				)
				t.wait(function()
					return done
				end, "legacy selection absent", 15000)
				assert(entries, err)
				assert(not entries[1].uncommitted and not entries[2].uncommitted, "unchanged encoded text lost history")
				assert((entries[3].uncommitted or false) == (variant == "eof"), "EOF history incorrect")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_signs_large_revert_serialized_empty_eof_row",
		s.guard(function()
			local f, buf = s.fixture(false, { use_gitsigns = true, signs = { max_file_bytes = 1 } })
			write_bytes(f.file, "alpha")
			s.h.exec({ "git", "add", "sample.txt" }, f.root)
			vim.cmd("edit!")
			vim.bo[buf].fixendofline = false
			vim.cmd("normal! Go")
			package.loaded.gitsigns = {
				get_hunks = function()
					return {
						{
							removed = { start = 1, count = 1, lines = { "alpha" }, no_nl_at_eof = true },
							added = { start = 1, count = 1, lines = { "alpha" } },
						},
					}
				end,
			}
			local done
			require("lazyvcs.backends").resolve_async(f.file, function()
				done = true
			end)
			s.wait(function()
				return done
			end, "resolve absent", 15000)
			api.nvim_win_set_cursor(0, { 1, 0 })
			vim.cmd("LazyVCS hunk revert")
			s.wait(function()
				return (s.signs.current_state(buf).native_holds or 0) == 0
			end, "revert absent", 15000)
			assert(
				vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), { "alpha" }),
				"revert retained empty EOF row"
			)
			assert(not vim.bo[buf].endofline)
			vim.cmd("silent write")
			assert(table.concat(vim.fn.readfile(f.file, "b"), "\n") == "alpha", "saved bytes differ")
		end),
	}
	cases[#cases + 1] = {
		"test_signs_large_index_revert_uses_gitsigns_fallback",
		s.guard(function()
			local f, buf = s.fixture(false, { use_gitsigns = true, signs = { max_file_bytes = 64 } })
			local base = string.rep("base", 30)
			s.h.write_file(f.file, base .. "\n")
			s.h.exec({ "git", "add", "sample.txt" }, f.root)
			s.h.write_file(f.file, "changed\n")
			vim.cmd("edit!")
			package.loaded.gitsigns = {
				get_hunks = function()
					return {
						{
							removed = { start = 1, count = 1, lines = { base } },
							added = { start = 1, count = 1, lines = { "changed" } },
						},
					}
				end,
			}
			vim.cmd("LazyVCS hunk revert")
			s.wait(function()
				return api.nvim_buf_get_lines(buf, 0, 1, false)[1] == base
			end, "oversized index revert did not fall back", 2000)
			assert((s.signs.current_state(buf).native_holds or 0) == 0, "native ownership leaked")
		end),
	}
	cases[#cases + 1] = {
		"test_signs_profile_correction_retries_suspended_base",
		s.guard(function()
			local f, buf = s.fixture(false)
			write_bytes(f.file, "\255\254" .. vim.iconv("one\ntwo\nthree\n", "utf-8", "utf-16le"))
			s.h.exec({ "git", "add", "sample.txt" }, f.root)
			vim.cmd("edit!")
			s.edit(buf, { "one", "changed", "three" })
			s.refresh(buf, true)
			assert(#s.marks(buf) == 1)
			vim.bo[buf].fileencoding = "utf-8"
			api.nvim_exec_autocmds("OptionSet", { pattern = "fileencoding" })
			s.wait(function()
				return s.signs.current_state(buf).unavailable_reason ~= nil
			end, "decoding did not suspend", 15000)
			local generation = s.signs.current_state(buf).base_generation
			s.edit(buf, { "one", "CHANGED", "three" })
			vim.wait(50)
			assert(s.signs.current_state(buf).base_generation == generation, "edit retried failed profile")
			vim.bo[buf].fileencoding = "utf-16le"
			api.nvim_exec_autocmds("OptionSet", { pattern = "fileencoding" })
			s.wait(function()
				return #s.marks(buf) == 1
			end, "corrected profile left signs suspended", 2000)
		end),
	}
	cases[#cases + 1] = {
		"test_signs_preview_disables_inherited_folds",
		t.guard(function()
			local _, _, win = t.open(false)
			folds()
			vim.cmd("LazyVCS preview")
			t.wait(function()
				return api.nvim_get_current_win() ~= win
			end, "preview absent", 15000)
			assert(vim.bo.filetype == "diff")
			assert(vim.fn.foldclosed(1) == -1, "preview is folded")
			assert(vim.wo[win].foldenable and vim.go.foldenable, "preview changed source/global folds")
			api.nvim_win_close(0, true)
		end),
	}
	return cases
end
