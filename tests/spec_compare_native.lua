return function(ctx)
	local h, compare = ctx.helpers, require("lazyvcs.compare")
	local function keys(value)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(value, true, false, true), "xt", false)
	end
	local function ready(s, path)
		ctx.wait_for(function()
			return s.preview_result and (not path or s.shown_item.relpath == path)
		end, "native comparison did not load", 15000)
	end
	local function fixture(opts)
		require("lazyvcs").setup(opts or {})
		local f = h.make_git_fixture()
		local lines = {}
		for i = 1, 60 do
			lines[i] = "alpha beta gamma " .. i
		end
		for _, path in ipairs({ "a.txt", "b.txt", "c.txt" }) do
			h.write_file(f.root .. "/" .. path, table.concat(lines, "\n") .. "\n")
		end
		h.exec({ "git", "add", "." }, f.root)
		h.exec({ "git", "commit", "-m", "native comparison base" }, f.root)
		lines[8], lines[30] = "changed eight", "changed thirty"
		for _, path in ipairs({ "a.txt", "b.txt", "c.txt" }) do
			h.write_file(f.root .. "/" .. path, table.concat(lines, "\n") .. "\n")
		end
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local s = assert(compare.open({ path = f.root, base = "HEAD" }))
		ready(s, "a.txt")
		vim.api.nvim_set_current_win(s.sidewin)
		keys("<CR>")
		return f, s
	end
	return {
		{
			"test_comparison_native_base_refresh_keeps_externally_displayed_snapshot",
			function()
				local f, s = fixture()
				local frozen = s.right
				local before = vim.api.nvim_buf_get_lines(frozen, 0, -1, false)
				local name = vim.api.nvim_buf_get_name(frozen)
				vim.cmd("tab sbuffer " .. frozen)
				local external = vim.api.nvim_get_current_tabpage()
				vim.api.nvim_set_current_win(s.rightwin)
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "advance comparison base" }, f.root)
				h.write_file(f.root .. "/a.txt", "new changed contents\n")
				compare.refresh(s)
				ready(s, "a.txt")
				assert(vim.api.nvim_buf_get_lines(s.right, 0, 1, false)[1] == "new changed contents")
				assert(s.right ~= frozen and vim.api.nvim_buf_get_name(s.right) ~= name)
				assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(frozen, 0, -1, false)))
				assert(vim.api.nvim_buf_get_name(frozen) == name and not vim.bo[frozen].modifiable)
				compare.close(s)
				vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(external))
				assert(not vim.api.nvim_buf_is_valid(frozen))
			end,
		},
		{
			"test_comparison_native_close_respects_unmodified_buffer_lifetimes",
			function()
				for _, hidden in ipairs({ "wipe", "delete", "unload" }) do
					local _, s = fixture()
					local buf = vim.api.nvim_create_buf(true, true)
					vim.bo[buf].bufhidden = hidden
					vim.cmd("split")
					vim.api.nvim_win_set_buf(0, buf)
					compare.close(s)
					if hidden == "wipe" then
						assert(not vim.api.nvim_buf_is_valid(buf), "close retained wipe buffer")
					else
						assert(not vim.api.nvim_buf_is_loaded(buf), "close retained loaded " .. hidden .. " buffer")
						if hidden == "delete" then
							assert(not vim.bo[buf].buflisted)
						end
					end
				end
			end,
		},
		{
			"test_comparison_native_empty_snapshots_remain_locked_after_filetype_plugins",
			function()
				local group = vim.api.nvim_create_augroup("lazyvcs_native_readonly_test", { clear = true })
				vim.api.nvim_create_autocmd("FileType", {
					group = group,
					pattern = "text",
					callback = function(args)
						if vim.api.nvim_buf_get_name(args.buf):find("lazyvcs://compare/", 1, true) then
							vim.bo[args.buf].modifiable = true
							vim.bo[args.buf].readonly = false
						end
					end,
				})
				local f, s = fixture()
				h.write_file(f.root .. "/empty.txt", "")
				require("lazyvcs").compare_refresh()
				ready(s)
				vim.api.nvim_set_current_win(s.sidewin)
				vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["empty.txt"], 0 })
				keys("P")
				ready(s, "empty.txt")
				vim.api.nvim_del_augroup_by_id(group)
				assert(not vim.bo[s.left].modifiable and vim.bo[s.left].readonly)
				assert(not vim.bo[s.right].modifiable and vim.bo[s.right].readonly)
				compare.close(s)
			end,
		},

		{
			"test_comparison_native_reload_during_refresh_keeps_previous_snapshot",
			function()
				local _, s = fixture()
				local snapshot, items, buf = s.snapshot, s.items, s.right
				local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				local util = require("lazyvcs.util")
				local notify, errors = util.notify, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(_, level)
					if level == vim.log.levels.ERROR then
						errors = errors + 1
					end
				end
				s.snapshot, s.items = nil, {}
				vim.cmd("edit!")
				util.notify = notify
				s.snapshot, s.items = snapshot, items
				assert(errors == 0, "reload failed while comparison was refreshing")
				assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
				compare.close(s)
			end,
		},

		{
			"test_comparison_native_close_preserves_unowned_unsaved_editor_split",
			function()
				local f, s = fixture()
				vim.cmd("split " .. vim.fn.fnameescape(f.root .. "/c.txt"))
				local buf = vim.api.nvim_get_current_buf()
				vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved editor split" })
				vim.bo[buf].bufhidden = "wipe"
				vim.cmd("split")
				compare.close(s)
				assert(
					vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified,
					"close discarded an unowned unsaved editing split"
				)
				assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "unsaved editor split")
				assert(vim.bo[buf].bufhidden == "wipe", "close lost the shared editing buffer's original lifetime")
				vim.bo[buf].bufhidden = "hide"
			end,
		},

		{
			"test_comparison_native_edit_uses_exact_path_not_partial_pattern",
			function()
				local f, s = fixture()
				local misleading = vim.fn.bufadd(f.root .. "/a.txt.local")
				h.write_file(f.root .. "/a.txt.local", "other file\n")
				vim.fn.bufload(misleading)
				require("lazyvcs").compare_action("edit")
				assert(
					vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == f.root .. "/a.txt",
					"edit opened a partial filename match"
				)
				compare.close(s)
			end,
		},
		{
			"test_comparison_native_last_tab_close_with_unowned_editor_split",
			function()
				local f, s = fixture()
				vim.cmd("split " .. vim.fn.fnameescape(f.root .. "/c.txt"))
				vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(s.origin_tab))
				local ok, err = pcall(compare.close, s)
				assert(ok, err)
				assert(not vim.api.nvim_tabpage_is_valid(s.tab) and #vim.api.nvim_list_tabpages() >= 1)
			end,
		},
		{
			"test_comparison_native_reload_failure_preserves_snapshot_marks_and_sidebar",
			function()
				local _, s = fixture()
				local buf = s.right
				local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				vim.api.nvim_win_set_cursor(s.rightwin, { 12, 3 })
				keys("mAma")
				local preview = s.provider.preview
				s.provider.preview = function(_, _, callback)
					local task = require("lazyvcs.backends.task").new(callback)
					vim.schedule(function()
						task:finish(nil, "forced reload failure")
					end)
					return task
				end
				vim.cmd("edit!")
				ctx.wait_for(function()
					return not s.preview_job and not s.buffer_cache.pairs["a.txt"].reload_job
				end, "reload did not finish")
				s.provider.preview = preview
				assert(
					vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)),
					"failed reload erased the snapshot"
				)
				assert(vim.deep_equal(vim.api.nvim_buf_get_mark(buf, "a"), { 12, 3 }), "reload changed snapshot marks")
				assert(vim.api.nvim_get_mark("A", {})[1] == 12 and vim.api.nvim_get_mark("A", {})[3] == buf)
				vim.api.nvim_set_current_win(s.sidewin)
				local sidebar = vim.api.nvim_buf_get_lines(s.sidebar, 0, -1, false)
				vim.cmd("edit!")
				assert(
					vim.deep_equal(sidebar, vim.api.nvim_buf_get_lines(s.sidebar, 0, -1, false)),
					"sidebar reload replaced file list"
				)
				compare.close(s)
			end,
		},
		{
			"test_comparison_native_presentation_buffer_never_routes_to_editor",
			function()
				local _, s = fixture()
				local origin = vim.api.nvim_win_get_buf(s.origin_win)
				local snapshot = s.right
				vim.api.nvim_win_set_buf(s.rightwin, s.message_right)
				ctx.wait_for(function()
					return vim.api.nvim_win_get_buf(s.rightwin) == snapshot
				end, "presentation buffer was not restored")
				assert(
					vim.api.nvim_get_current_win() == s.rightwin and vim.api.nvim_win_get_buf(s.origin_win) == origin,
					"presentation routed into the editor"
				)
				compare.close(s)
			end,
		},
		{
			"test_comparison_native_metadata_protects_current_pair_from_eviction",
			function()
				local _, s = fixture({ compare = { max_cached_files = 1 } })
				vim.cmd("tab sbuffer " .. s.right)
				local external = vim.api.nvim_get_current_tabpage()
				vim.api.nvim_set_current_win(s.rightwin)
				keys("]b")
				ready(s, "b.txt")
				local b = s.right
				keys("ma")
				require("lazyvcs").compare_action("metadata")
				vim.wait(50)
				assert(vim.api.nvim_buf_is_valid(b), "metadata evicted the current snapshot")
				require("lazyvcs").compare_action("metadata")
				assert(s.right == b and vim.api.nvim_buf_get_mark(b, "a")[1] > 0)
				compare.close(s)
				vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(external))
			end,
		},

		{
			"test_comparison_native_edit_base_hunk_and_large_unsaved_buffer",
			function()
				local f, s = fixture()
				vim.api.nvim_set_current_win(s.leftwin)
				vim.api.nvim_win_set_cursor(s.leftwin, { 8, 3 })
				require("lazyvcs").compare_action("edit")
				assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 8, 0 }))
				local buf = vim.api.nvim_get_current_buf()
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 1024 * 1024 + 1) })
				vim.api.nvim_set_current_win(s.rightwin)
				vim.api.nvim_win_set_cursor(s.rightwin, { 12, 3 })
				local get_lines = vim.api.nvim_buf_get_lines
				---@diagnostic disable-next-line: duplicate-set-field
				vim.api.nvim_buf_get_lines = function(target, start, finish, strict)
					assert(not (target == buf and finish == -1), "large editing buffer was read in full")
					return get_lines(target, start, finish, strict)
				end
				local ok, err = pcall(require("lazyvcs").compare_action, "edit")
				vim.api.nvim_buf_get_lines = get_lines
				assert(ok, err)
				assert(vim.api.nvim_get_current_buf() == buf and vim.bo[buf].modified)
				assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 1, 3 }))
				assert(vim.fn.readfile(f.root .. "/a.txt")[8] == "changed eight")
				compare.close(s)
			end,
		},

		{
			"test_comparison_native_cache_trims_after_external_window_closes",
			function()
				local _, s = fixture({ compare = { max_cached_files = 1 } })
				local a = s.right
				vim.cmd("tab sbuffer " .. a)
				local external_tab = vim.api.nvim_get_current_tabpage()
				vim.api.nvim_set_current_win(s.rightwin)
				keys("]b")
				ready(s, "b.txt")
				assert(s.buffer_cache.count == 2)
				vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(external_tab))
				ctx.wait_for(function()
					return s.buffer_cache.count == 1
				end, "hidden snapshot remained above cache limit")
				assert(not vim.api.nvim_buf_is_valid(a))
				compare.close(s)
			end,
		},

		{
			"test_comparison_native_visible_cache_protection_and_close_freezes_snapshot",
			function()
				local _, s = fixture({ compare = { max_cached_files = 1 } })
				local a = s.right
				vim.cmd("tab sbuffer " .. a)
				local external = vim.api.nvim_get_current_win()
				vim.api.nvim_set_current_tabpage(s.tab)
				vim.api.nvim_set_current_win(s.rightwin)
				keys("]b")
				ready(s, "b.txt")
				assert(s.buffer_cache.count == 2 and vim.api.nvim_buf_is_valid(a))
				local before = vim.api.nvim_buf_get_lines(a, 0, -1, false)
				compare.close(s)
				assert(vim.api.nvim_buf_is_valid(a) and vim.bo[a].bufhidden == "wipe")
				vim.api.nvim_set_current_win(external)
				vim.cmd("edit!")
				assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(a, 0, -1, false)))
				assert(not vim.bo[a].modifiable)
				vim.cmd.tabclose()
				assert(not vim.api.nvim_buf_is_valid(a))
			end,
		},
		{
			"test_comparison_native_hidden_reload_rejects_old_callbacks",
			function()
				local _, s = fixture()
				local pair = s.buffer_cache.pairs["a.txt"]
				local resource = require("lazyvcs.compare_buffers").resource(pair.right)
				vim.api.nvim_set_current_win(s.origin_win)
				local callbacks, cancelled = {}, 0
				local preview = s.provider.preview
				s.provider.preview = function(_, _, callback)
					callbacks[#callbacks + 1] = callback
					local task = require("lazyvcs.backends.task").new(callback)
					task:on_cancel(function()
						cancelled = cancelled + 1
					end)
					return task
				end
				s.reload(resource)
				s.reload(resource)
				local job = pair.reload_job
				callbacks[1]({ left = { "old" }, right = { "old" } })
				assert(cancelled == 1 and pair.reload_job == job)
				assert(vim.api.nvim_buf_get_lines(pair.right, 0, 1, false)[1] ~= "old")
				callbacks[2]({
					left = { "latest" },
					right = { "latest" },
					left_label = "BASE",
					right_label = "SAVED WORKTREE",
				})
				assert(pair.reload_job == nil and vim.api.nvim_buf_get_lines(pair.right, 0, 1, false)[1] == "latest")
				assert(
					s.preview_result.right[1] == "latest" and #s.navigation.saved == 0,
					"reload left stale hunk state"
				)
				assert(vim.api.nvim_get_current_win() == s.origin_win, "reload stole editing focus")
				s.reload(resource)
				local newer = vim.deepcopy(s.preview_result)
				newer.right = { "newer preview" }
				require("lazyvcs.compare_buffers").store(s, s.shown_item, newer)
				callbacks[3]({ left = { "stale" }, right = { "stale" } })
				assert(
					vim.api.nvim_buf_get_lines(pair.right, 0, 1, false)[1] == "newer preview",
					"late reload overwrote a newer preview"
				)
				s.provider.preview = preview
				compare.close(s)
			end,
		},
		{
			"test_comparison_native_edit_maps_unsaved_insertions_and_reuses_buffer",
			function()
				local f, s = fixture()
				local buf = vim.fn.bufadd(f.root .. "/a.txt")
				vim.fn.bufload(buf)
				vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "unsaved insertion" })
				vim.api.nvim_win_set_cursor(s.rightwin, { 12, 3 })
				assert(require("lazyvcs").compare_action("edit"))
				assert(vim.api.nvim_get_current_buf() == buf and vim.bo[buf].modified)
				assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 13, 3 }))
				compare.close(s)
			end,
		},
		{
			"test_comparison_native_gf_resolves_source_directory",
			function()
				local f, s = fixture()
				local target = f.root .. "/header.txt"
				h.write_file(target, "header\n")
				local lines = vim.fn.readfile(f.root .. "/a.txt")
				lines[12] = "header.txt"
				h.write_file(f.root .. "/a.txt", table.concat(lines, "\n") .. "\n")
				require("lazyvcs").compare_refresh()
				ready(s, "a.txt")
				vim.api.nvim_set_current_win(s.rightwin)
				vim.api.nvim_win_set_cursor(s.rightwin, { 12, 0 })
				keys("gf")
				ctx.wait_for(function()
					return vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == target
						and vim.api.nvim_get_current_win() == s.origin_edit_win
				end, "gf did not resolve the source directory")
				assert(vim.api.nvim_get_current_win() == s.origin_edit_win)
				compare.close(s)
			end,
		},

		{
			"test_comparison_native_jumps_restore_paired_file_and_position",
			function()
				local _, s = fixture()
				local a = s.right
				vim.api.nvim_win_set_cursor(s.rightwin, { 12, 3 })
				keys("]b")
				ready(s, "b.txt")
				local b = s.right
				keys("<C-o>")
				ready(s, "a.txt")
				assert(s.right == a and vim.deep_equal(vim.api.nvim_win_get_cursor(s.rightwin), { 12, 3 }))
				keys("<C-i>")
				ready(s, "b.txt")
				assert(s.right == b and s.shown_item.relpath == "b.txt")
				compare.close(s)
			end,
		},
		{
			"test_comparison_native_bounded_cache_and_unlimited_cache",
			function()
				for _, limit in ipairs({ 1, 0 }) do
					local _, s = fixture({ compare = { max_cached_files = limit } })
					local a = s.right
					keys("]b")
					ready(s, "b.txt")
					keys("]b")
					ready(s, "c.txt")
					if limit == 1 then
						assert(s.buffer_cache.count == 1 and not vim.api.nvim_buf_is_valid(a))
					else
						assert(s.buffer_cache.count == 3 and vim.api.nvim_buf_is_valid(a))
					end
					compare.close(s)
				end
			end,
		},
		{
			"test_comparison_native_reload_preserves_marks_and_stale_uri_is_locked",
			function()
				local f, s = fixture()
				local buf = s.right
				local uri = vim.api.nvim_buf_get_name(buf)
				vim.api.nvim_win_set_cursor(s.rightwin, { 12, 3 })
				keys("ma")
				local lines = vim.fn.readfile(f.root .. "/a.txt")
				table.insert(lines, 1, "inserted line")
				h.write_file(f.root .. "/a.txt", table.concat(lines, "\n") .. "\n")
				require("lazyvcs").compare_refresh()
				ctx.wait_for(function()
					return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "inserted line"
				end, "snapshot reload lost data")
				assert(
					vim.deep_equal(vim.api.nvim_buf_get_mark(buf, "a"), { 13, 3 }),
					vim.inspect(vim.api.nvim_buf_get_mark(buf, "a"))
				)
				assert(not vim.bo[buf].modifiable and vim.bo[buf].readonly)
				vim.cmd("edit!")
				ready(s, "a.txt")
				assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "inserted line")
				compare.close(s)
				vim.cmd.edit(vim.fn.fnameescape(uri))
				assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "Snapshot no longer available")
				assert(not vim.bo.modifiable and vim.bo.readonly and not vim.bo.buflisted)
				vim.cmd.enew()
			end,
		},
		{
			"test_comparison_native_close_preserves_pending_unsaved_wipe_buffer",
			function()
				local f, s = fixture()
				local buf = vim.fn.bufadd(f.root .. "/b.txt")
				vim.fn.bufload(buf)
				vim.bo[buf].bufhidden = "wipe"
				vim.api.nvim_win_set_buf(s.rightwin, buf)
				vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved" })
				compare.close(s)
				assert(vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified)
				assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "unsaved")
				vim.bo[buf].bufhidden = "hide"
			end,
		},
		{
			"test_comparison_native_action_and_effective_keymap_validation",
			function()
				local plugin = require("lazyvcs")
				assert(plugin.compare_action("files") == false)
				assert(not pcall(plugin.compare_action, "not_an_action"))
				local leader = vim.g.mapleader
				vim.g.mapleader = " "
				assert(not pcall(plugin.setup, { compare = { keymaps = { edit = " vf" } } }))
				assert(not pcall(plugin.setup, { compare = { keymaps = { files = "]b" } } }))
				for _, limit in ipairs({ -1, 1.5, math.huge }) do
					assert(not pcall(plugin.setup, { compare = { max_cached_files = limit } }))
				end
				vim.g.mapleader = leader
				local _, s = fixture({ compare = { keymaps = { files = false, edit = false, help = false } } })
				assert(plugin.compare_action("files") and vim.api.nvim_get_current_win() == s.sidewin)
				compare.close(s)
			end,
		},
		{
			"test_comparison_native_motions_search_macros_and_readonly",
			function()
				local _, s = fixture()
				for _, win in ipairs({ s.leftwin, s.rightwin }) do
					vim.api.nvim_set_current_win(win)
					vim.api.nvim_win_set_cursor(win, { 12, 0 })
					keys("e")
					assert(vim.api.nvim_win_get_cursor(win)[2] == 4, "e did not move to the end of the word")
					keys("b")
					assert(vim.api.nvim_win_get_cursor(win)[2] == 0, "b did not move backward")
					keys("?alpha<CR>qqjq")
					assert(not s.helpwin and not s.closed)
					assert(vim.fn.reg_recording() == "" and vim.fn.getreg("q") == "j")
					local buf = vim.api.nvim_win_get_buf(win)
					local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
					keys("0v4ly")
					assert(vim.fn.getreg('"') == "alpha", "native visual yank failed")
					for _, mutation in ipairs({ "x", "p", "P", "u", "~", "Vd" }) do
						local ok = pcall(function()
							vim.cmd("normal! " .. mutation)
						end)
						assert(not ok, "preview accepted " .. mutation)
						assert(vim.deep_equal(before, vim.api.nvim_buf_get_lines(buf, 0, -1, false)))
						keys("<Esc>")
					end
				end
				compare.close(s)
			end,
		},
		{
			"test_comparison_native_marks_survive_files_and_metadata",
			function()
				local _, s = fixture()
				local a = s.right
				vim.api.nvim_win_set_cursor(s.rightwin, { 12, 3 })
				keys("ma]b")
				ready(s, "b.txt")
				assert(s.right ~= a, "different files share the same preview buffer")
				vim.cmd("bunload " .. a)
				assert(not vim.api.nvim_buf_is_loaded(a))
				keys("[b")
				ready(s, "a.txt")
				assert(s.right == a and vim.deep_equal(vim.api.nvim_buf_get_mark(a, "a"), { 12, 3 }))
				vim.cmd("LazyVCS compare metadata")
				assert(s.mode == "metadata" and s.right ~= a)
				vim.cmd("LazyVCS compare metadata")
				assert(s.right == a and vim.deep_equal(vim.api.nvim_buf_get_mark(a, "a"), { 12, 3 }))
				compare.close(s)
			end,
		},
		{
			"test_comparison_native_picker_edits_changed_file_without_changing_review",
			function()
				local f, s = fixture()
				local review = s.right
				local buf = vim.fn.bufadd(f.root .. "/b.txt")
				vim.fn.bufload(buf)
				vim.api.nvim_win_set_buf(s.rightwin, buf)
				vim.api.nvim_win_set_cursor(s.rightwin, { 30, 3 })
				ctx.wait_for(function()
					return vim.api.nvim_get_current_win() == s.origin_edit_win and vim.api.nvim_get_current_buf() == buf
				end, "picker did not open the actual editing buffer")
				assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 30, 3 }))
				assert(s.shown_item.relpath == "a.txt" and s.right == review)
				assert(vim.api.nvim_win_get_buf(s.rightwin) == review)
				compare.close(s)
			end,
		},
	}
end
