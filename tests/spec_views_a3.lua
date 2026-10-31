return function(ctx)
	local api, h = vim.api, ctx.helpers
	local signs = require("signs_helpers")(ctx)
	local text, diff = require("lazyvcs.compare_text"), require("lazyvcs.diff")
	local function guard(fn)
		return function()
			local options = vim.o.diffopt
			local ok, err = xpcall(fn, debug.traceback)
			vim.o.diffopt = options
			h.cleanup()
			assert(ok, err)
		end
	end
	return {
		{
			"test_core_views_a3_native_diff_options_and_empty_base_reset",
			guard(function()
				vim.o.diffopt = "internal,filler,closeoff,linematch:40"
				local base = { lines = { "b", "a", "a", "a" }, eol = true, empty = false }
				local current = { lines = { "b", "c", "a", "c", "a", "a" }, eol = true, empty = false }
				local hunks = diff.compute_text_hunks(base, current)
				assert(#hunks == 2 and hunks[1].current_start == 2 and hunks[2].current_start == 4)
				local buf = api.nvim_create_buf(false, true)
				api.nvim_buf_set_lines(buf, 0, -1, false, current.lines)
				diff.reset_text_hunk(buf, base, current, hunks[1])
				assert(vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), { "b", "a", "c", "a", "a" }))
				local empty = { lines = {}, eol = false, empty = true }
				local captured = assert(text.capture(buf, 100000))
				local hunk = diff.compute_text_hunks(empty, captured)[1]
				diff.reset_text_hunk(buf, empty, captured, hunk)
				assert(vim.bo[buf].endofline and vim.bo[buf].fixendofline, "empty reset changed future write options")
				api.nvim_buf_delete(buf, { force = true })
			end),
		},
		{
			"test_core_views_a3_dos_endoffile_roundtrip",
			guard(function()
				local profile =
					{ fileencoding = "utf-8", fileformat = "dos", binary = false, bomb = false, key = "dos" }
				for _, bytes in ipairs({ "one\r\n\26", "one\26" }) do
					local document = assert(text.decode(bytes, profile, 100000))
					assert(document.eof_marker and document.lines[1] == "one")
					assert(text.encode_file(document, profile, 100000) == bytes, "DOS marker roundtrip changed bytes")
					local plain = vim.deepcopy(document)
					plain.eof_marker = false
					local hunks = diff.compute_text_hunks(document, plain)
					assert(#hunks == 1 and hunks[1].covers_eof, "marker loss was hidden")
					assert(#diff.compute_text_hunks(document, document) == 0)
				end
				local unix =
					assert(text.decode("one\26", vim.tbl_extend("force", profile, { fileformat = "unix" }), 100000))
				assert(not unix.eof_marker and unix.lines[1] == "one\26")
			end),
		},
		{
			"test_signs_a3_noncurrent_buffer_edits_refresh",
			signs.guard(function()
				local f, buf = signs.fixture(false)
				assert(signs.refresh(buf, true))
				vim.cmd("vnew")
				local other = api.nvim_get_current_buf()
				api.nvim_buf_set_lines(buf, 1, 2, false, { "cross-window edit" })
				signs.wait(function()
					local s = signs.signs.current_state(buf)
					return s and s.current_text and s.current_text.lines[2] == "cross-window edit"
				end, "noncurrent signs stale", 15000)
				assert(api.nvim_get_current_buf() == other and #signs.marks(buf) > 0)
				assert(f.file)
			end),
		},
		{
			"test_signs_a3_attached_preview_is_whole_buffer_off_hunk",
			signs.guard(function()
				local _, buf = signs.fixture(false, { use_gitsigns = true })
				local calls = 0
				package.loaded.gitsigns = {
					get_hunks = function()
						return {
							{
								added = { start = 2, count = 1, lines = { "changed" } },
								removed = {
									start = 2,
									count = 1,
									lines = { "two" },
								},
							},
						}
					end,
					preview_hunk = function()
						calls = calls + 1
					end,
				}
				api.nvim_win_set_cursor(0, { 1, 0 })
				vim.cmd("LazyVCS preview")
				signs.wait(function()
					return vim.bo.filetype == "diff"
				end, "native whole-buffer preview missing", 15000)
				assert(
					calls == 0 and table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("+changed", 1, true)
				)
				api.nvim_win_close(0, true)
				assert(api.nvim_get_current_buf() == buf)
			end),
		},
		{
			"test_live_diff_a3_conflicting_sessions_get_separate_tabs",
			guard(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_transfer_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file1))
				local state = require("lazyvcs.state")
				require("lazyvcs.actions").open()
				ctx.wait_for(function()
					return state.get(api.nvim_get_current_buf())
				end, "first session pending", 15000)
				local first = assert(state.current())
				vim.cmd("vsplit " .. vim.fn.fnameescape(f.file2))
				local buf = api.nvim_get_current_buf()
				require("lazyvcs.actions").open()
				ctx.wait_for(function()
					return state.get(buf)
				end, "second session pending", 15000)
				local second = assert(state.get(buf))
				assert(first.tabpage ~= second.tabpage, "native diff groups merged")
				assert(api.nvim_get_current_win() == second.editable_win)
			end),
		},
		{
			"test_live_diff_a3_large_refresh_uses_worker_and_rejects_stale_result",
			guard(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
					debounce_ms = 5,
				})
				local f = h.make_git_fixture()
				local rows = {}
				for i = 1, 1200 do
					rows[i] = "line " .. i .. string.rep("x", 40)
				end
				h.write_file(f.file, table.concat(rows, "\n") .. "\n")
				h.exec({ "git", "add", "sample.txt" }, f.root)
				rows[200], rows[900] = "changed one", "changed two"
				h.write_file(f.file, table.concat(rows, "\n") .. "\n")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local buf = api.nvim_get_current_buf()
				local worker = require("lazyvcs.diff_work")
				local start, starts = worker.start, 0
				local compat = require("lazyvcs.compat")
				local compute = compat.diff
				---@diagnostic disable-next-line: duplicate-set-field
				worker.start = function(...)
					starts = starts + 1
					return start(...)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				compat.diff = function()
					error("large live diff ran on the editor thread")
				end
				local ok, err = xpcall(function()
					require("lazyvcs.actions").open()
					local state = require("lazyvcs.state")
					ctx.wait_for(function()
						local live = state.get(buf)
						return live and live.hunk_cache and #live.hunks == 2
					end, "large initial hunks missing", 15000)
					local live = assert(state.get(buf))
					local previous = starts
					api.nvim_buf_set_lines(buf, 399, 400, false, { "third change" })
					ctx.wait_for(function()
						return starts > previous and live.hunk_cache and #live.hunks == 3
					end, "large edited hunks missing", 15000)
					assert(live.hunk_cache.identity.changedtick == api.nvim_buf_get_changedtick(buf))
					api.nvim_buf_set_lines(buf, 399, 400, false, { "  " .. rows[400] })
					require("lazyvcs.actions").jump_to_hunk("next")
					vim.opt.diffopt:append("iwhiteall")
					ctx.wait_for(function()
						return live.hunk_cache and live.hunk_cache.diffopt == vim.o.diffopt and #live.hunks == 2
					end, "old diffopt worker result published", 15000)
				end, debug.traceback)
				worker.start, compat.diff = start, compute
				assert(ok, err)
			end),
		},
		{
			"test_core_views_a3_highlight_mapping_survives_late_tokens",
			guard(function()
				vim.cmd("tabnew")
				local win = api.nvim_get_current_win()
				local highlighting = require("lazyvcs.highlighting")
				local old = vim.wo[win].winhighlight
				api.nvim_set_hl(0, "@lsp.type.lazyvcsA3Late", { link = "Identifier" })
				vim.wo[win].winhighlight = "normal:errormsg"
				local before = api.nvim_get_hl_ns({ winid = win })
				highlighting.apply(win, "syntax")
				assert(
					api.nvim_get_hl_ns({ winid = win }) == before,
					"case-insensitive native mapping treated as explicit theme"
				)
				vim.wo[win].winhighlight = "NormalNC:Comment"
				api.nvim_exec_autocmds(
					"LspTokenUpdate",
					{ buffer = api.nvim_get_current_buf(), data = { token = { type = "lazyvcsA3Late" } } }
				)
				assert(highlighting.user_winhighlight(win) == "NormalNC:Comment")
				highlighting.release(win)
				assert(vim.wo[win].winhighlight == "NormalNC:Comment", "late token overwrote user mapping")
				vim.wo[win].winhighlight = old
			end),
		},
		{
			"test_live_diff_a3_icase_refuses_hidden_ranges_and_confirmation_change",
			guard(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local buf = api.nvim_get_current_buf()
				local actions = require("lazyvcs.actions")
				actions.open()
				local state = require("lazyvcs.state")
				ctx.wait_for(function()
					local live = state.get(buf)
					return live and live.hunk_cache
				end, "initial hunks absent", 15000)
				local live = assert(state.get(buf))
				api.nvim_set_current_win(live.editable_win)
				api.nvim_win_set_cursor(0, { 2, 0 })
				local before = api.nvim_buf_get_lines(buf, 0, -1, false)
				vim.opt.diffopt:append("icase")
				assert(not actions.revert_hunk())
				actions.jump_to_hunk("next")
				assert(
					vim.deep_equal(before, api.nvim_buf_get_lines(buf, 0, -1, false))
						and api.nvim_win_get_cursor(0)[1] == 2
				)
				vim.opt.diffopt:remove("icase")
				local confirm = require("lazyvcs.source_control.confirm")
				local mutation = confirm.mutation
				local entered = false
				---@diagnostic disable-next-line: duplicate-set-field
				confirm.mutation = function(opts, apply)
					entered = true
					vim.opt.diffopt:append("icase")
					assert(opts.before_confirm() == false, "icase change passed confirmation guard")
					return apply()
				end
				local ok, err = xpcall(function()
					assert(not actions.revert_hunk())
				end, debug.traceback)
				confirm.mutation = mutation
				assert(ok, err)
				assert(entered and vim.deep_equal(before, api.nvim_buf_get_lines(buf, 0, -1, false)))
			end),
		},
		{
			"test_live_diff_a3_closed_folds_bound_wrapped_measurements",
			guard(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
					base_window = { align_wrapped = "auto" },
				})
				local f = h.make_git_fixture()
				local rows = {}
				for i = 1, 25000 do
					rows[i] = "line " .. i
				end
				h.write_file(f.file, table.concat(rows, "\n") .. "\n")
				h.exec({ "git", "add", "sample.txt" }, f.root)
				rows[12500] = "changed"
				h.write_file(f.file, table.concat(rows, "\n") .. "\n")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local buf = api.nvim_get_current_buf()
				require("lazyvcs.actions").open()
				local state = require("lazyvcs.state")
				ctx.wait_for(function()
					local live = state.get(buf)
					return live and live.hunk_cache
				end, "large folded hunks absent", 15000)
				local live = assert(state.get(buf))
				for _, win in ipairs({ live.base_win, live.editable_win }) do
					vim.wo[win].wrap = true
					vim.wo[win].foldenable = true
					vim.wo[win].foldlevel = 0
				end
				vim.cmd.redraw()
				local measure, calls = api.nvim_win_text_height, 0
				---@diagnostic disable-next-line: duplicate-set-field
				api.nvim_win_text_height = function(...)
					calls = calls + 1
					return measure(...)
				end
				local ok, err = pcall(require("lazyvcs.align").apply, live)
				api.nvim_win_text_height = measure
				assert(ok, err)
				assert(calls < 200, "closed folds caused " .. calls .. " measurements")
			end),
		},
		{
			"test_live_diff_a3_replaced_base_cannot_route_hunk_commands",
			guard(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local buf = api.nvim_get_current_buf()
				local actions = require("lazyvcs.actions")
				actions.open()
				local state = require("lazyvcs.state")
				ctx.wait_for(function()
					local live = state.get(buf)
					return live and live.hunk_cache
				end, "initial hunks missing", 15000)
				local live = assert(state.get(buf))
				api.nvim_win_set_cursor(live.editable_win, { 2, 0 })
				local foreign = api.nvim_create_buf(true, false)
				api.nvim_buf_set_lines(foreign, 0, -1, false, { "foreign one", "foreign two", "foreign three" })
				api.nvim_set_current_win(live.base_win)
				vim.cmd("noautocmd buffer " .. foreign)
				api.nvim_win_set_cursor(0, { 2, 0 })
				local confirm = require("lazyvcs.source_control.confirm")
				local mutation, calls = confirm.mutation, 0
				---@diagnostic disable-next-line: duplicate-set-field
				confirm.mutation = function()
					calls = calls + 1
					return false
				end
				local ok, err = xpcall(function()
					assert(not actions.revert_hunk())
					assert(calls == 0, "foreign base selected a source hunk")
					api.nvim_win_set_cursor(0, { 3, 0 })
					actions.jump_to_hunk("next")
					assert(
						api.nvim_get_current_buf() == foreign and api.nvim_win_get_cursor(0)[1] == 3,
						"foreign base received hunk navigation"
					)
				end, debug.traceback)
				confirm.mutation = mutation
				pcall(api.nvim_buf_delete, foreign, { force = true })
				assert(ok, err)
			end),
		},
		{
			"test_core_views_a3_initial_worker_does_not_focus_borrowed_pane",
			guard(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				local rows = {}
				for i = 1, 2000 do
					rows[i] = "line " .. i .. string.rep("x", 30)
				end
				h.write_file(f.file, table.concat(rows, "\n") .. "\n")
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "large preview base" }, f.root)
				rows[200] = "changed"
				h.write_file(f.file, table.concat(rows, "\n") .. "\n")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local worker = require("lazyvcs.diff_work")
				local start, request = worker.start, nil
				---@diagnostic disable-next-line: duplicate-set-field
				worker.start = function(_, _, _, done)
					request = done
					return {}
				end
				local compare = require("lazyvcs.compare")
				local session, foreign
				local ok, err = xpcall(function()
					session = assert(compare.open({ path = f.root, base = "HEAD", editable = false }))
					ctx.wait_for(function()
						return request ~= nil and session.navigation and session.navigation.pending
					end, "initial worker absent", 15000)
					api.nvim_set_current_win(session.sidewin)
					session.actions.review()
					foreign = api.nvim_create_buf(true, false)
					local temporary = {}
					for i = 1, 300 do
						temporary[i] = "picker " .. i
					end
					api.nvim_buf_set_lines(foreign, 0, -1, false, temporary)
					api.nvim_win_set_buf(session.rightwin, foreign)
					api.nvim_win_set_cursor(session.rightwin, { 10, 0 })
					assert(request)(true, vim.mpack.encode({ { 200, 1, 200, 1 } }))
					assert(api.nvim_get_current_win() == session.sidewin, "worker stole focus during picker ownership")
					assert(api.nvim_win_get_cursor(session.rightwin)[1] == 10, "worker moved borrowed buffer cursor")
				end, debug.traceback)
				worker.start = start
				if session then
					pcall(compare.close, session, false)
				end
				if foreign then
					pcall(api.nvim_buf_delete, foreign, { force = true })
				end
				assert(ok, err)
			end),
		},
		{
			"test_live_diff_a3_isolated_copy_does_not_retain_native_diff_on_close",
			guard(function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				local f = h.make_git_fixture()
				vim.cmd.tabnew()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local source = api.nvim_get_current_win()
				vim.cmd.vnew()
				local peer = api.nvim_get_current_win()
				vim.cmd.diffthis()
				api.nvim_set_current_win(source)
				vim.cmd.diffthis()
				local buf = api.nvim_get_current_buf()
				local state = require("lazyvcs.state")
				local actions = require("lazyvcs.actions")
				actions.open()
				ctx.wait_for(function()
					return state.get(buf)
				end, "isolated native session absent", 15000)
				local live = assert(state.get(buf))
				local copied = live.editable_win
				local ok, err = xpcall(function()
					assert(live.tabpage ~= api.nvim_win_get_tabpage(source), "native pair was not isolated")
					actions.close(live)
					assert(
						api.nvim_win_is_valid(copied) and not vim.wo[copied].diff,
						"owned clone retained copied native diff mode"
					)
					assert(vim.wo[source].diff and vim.wo[peer].diff, "original native peers changed")
				end, debug.traceback)
				for _, win in ipairs({ source, peer, copied }) do
					if api.nvim_win_is_valid(win) then
						api.nvim_win_call(win, function()
							vim.cmd.diffoff()
						end)
					end
				end
				assert(ok, err)
			end),
		},
	}
end
