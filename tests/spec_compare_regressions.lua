return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare = require("lazyvcs.compare")
	local common = require("lazyvcs.backends.comparison")
	local util = require("lazyvcs.util")
	local cases, sessions = {}, {}
	local function keys(value)
		api.nvim_feedkeys(api.nvim_replace_termcodes(value, true, false, true), "xt", false)
	end
	local function await(start)
		local done, value, failure
		start(function(result, err)
			done, value, failure = true, result, err
		end)
		ctx.wait_for(function()
			return done
		end, "comparison request did not finish", 15000)
		return value, failure
	end
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job and not s.job
		end, "comparison preview did not load", 15000)
	end
	local function open(f, opts)
		local s = assert(compare.open(vim.tbl_extend("force", {
			path = f.root,
			base = f.repo and h.file_url(f.repo) .. "@2" or "HEAD",
		}, opts or {})))
		sessions[#sessions + 1] = s
		ready(s)
		return s
	end
	local function add(name, fn)
		cases[#cases + 1] = {
			name,
			function()
				local start = util.system_start
				local ok, err = xpcall(fn, function(e)
					return type(e) == "table" and e or debug.traceback(e)
				end)
				util.system_start = start
				for _, s in ipairs(sessions) do
					pcall(compare.close, s)
				end
				sessions = {}
				if not ok then
					error(err)
				end
			end,
		}
	end
	local function bytes(path, value)
		local file = assert(io.open(path, "wb"))
		assert(file:write(value))
		file:close()
	end
	local function fixture(vcs, mixed)
		local f = vcs == "svn" and h.make_svn_fixture() or h.make_git_fixture()
		local lines = {}
		for i = 1, 40 do
			lines[i] = "line " .. i
		end
		if mixed then
			lines[1] = lines[1] .. "\r"
		end
		bytes(f.file, table.concat(lines, "\n") .. "\n")
		h.exec(vcs == "svn" and { "svn", "commit", "-m", "base" } or { "git", "commit", "-am", "base" }, f.root)
		lines[5] = "changed 5"
		bytes(f.file, table.concat(lines, "\n") .. "\n")
		return f, lines
	end
	add("test_compare_snapshot_controls_require_owned_focus", function()
		local f = h.make_git_transfer_fixture()
		local s = open(f, { editable = false })
		api.nvim_set_current_win(s.rightwin)
		local snapshot = s.right
		local callback = assert(vim.fn.maparg("\\ve", "n", false, true).callback)
		vim.cmd("tab sbuffer " .. snapshot)
		assert(compare.current() == nil)
		assert(vim.fn.maparg("\\ve", "n") == "", "snapshot retained Compare controls outside its pane")
		local external = api.nvim_get_current_win()
		vim.keymap.set("n", "\\ve", "<Nop>", { buffer = snapshot, desc = "user mapping" })
		api.nvim_set_current_win(s.rightwin)
		keys("]b")
		ready(s)
		api.nvim_set_current_win(external)
		callback()
		assert(
			api.nvim_get_current_win() == external and api.nvim_get_current_buf() == snapshot,
			"detached callback opened another file"
		)
		assert(vim.fn.maparg("\\ve", "n", false, true).desc == "user mapping")
	end)
	add("test_compare_repository_dedup_preserves_editable_override", function()
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local s = open(f)
		for _, override in ipairs({ false, true, false }) do
			api.nvim_set_current_win(s.origin_win)
			local pending = assert(compare.open({ path = f.file, base = "HEAD", editable = override }))
			sessions[#sessions + 1] = pending
			ctx.wait_for(function()
				return pending.closed and s.preview_result and not s.job
			end, "repository dedup did not finish", 15000)
			assert(s.editable == override, "repository dedup ignored editable override")
			assert((s.worktree ~= nil) == override)
		end
		api.nvim_set_current_win(s.origin_win)
		local pending = assert(compare.open({ path = f.file, base = "HEAD" }))
		sessions[#sessions + 1] = pending
		ctx.wait_for(function()
			return pending.closed and s.preview_result and not s.job
		end, "repository dedup did not finish", 15000)
		assert(s.editable == false, "omitted override reset editability")
	end)
	add("test_compare_editable_file_cycle_native_jumplist", function()
		local f = h.make_git_transfer_fixture()
		local s = open(f)
		api.nvim_set_current_win(s.rightwin)
		local first = s.right
		api.nvim_win_set_cursor(s.rightwin, { 3, 2 })
		vim.cmd("clearjumps")
		keys("]b")
		ready(s)
		assert(#vim.fn.getjumplist()[1] > 0, "editable file cycling omitted its departure mark")
		assert(api.nvim_buf_is_loaded(first) and not vim.bo[first].buflisted)
		local second = s.right
		keys("<C-O>")
		ctx.wait_for(function()
			return s.shown_item.relpath == "alpha.txt" and s.mode == "text" and not s.preview_job
		end, "native jump did not restore the comparison pair", 15000)
		assert(api.nvim_get_current_win() == s.rightwin and s.right == first)
		assert(vim.deep_equal(api.nvim_win_get_cursor(s.rightwin), { 3, 2 }))
		assert(s.preview_result.left[1] == "one")
		-- Clean buffers created only for Compare are still disposable at close.
		compare.close(s)
		assert(not api.nvim_buf_is_loaded(second), "private jump target survived Compare close")
	end)
	add("test_compare_editable_file_cycle_native_forward_jumplist", function()
		local f = h.make_git_transfer_fixture()
		local s = open(f)
		api.nvim_set_current_win(s.rightwin)
		keys("]b")
		ready(s)
		local second = s.right
		api.nvim_win_set_cursor(s.rightwin, { 5, 1 })
		keys("<C-O>")
		ctx.wait_for(function()
			return s.shown_item.relpath == "alpha.txt" and not s.preview_job
		end, "native backward jump did not restore the comparison pair", 15000)
		keys("<C-I>")
		ctx.wait_for(function()
			return s.shown_item.relpath == "beta.txt" and s.mode == "text" and not s.preview_job
		end, "native forward jump did not restore the comparison pair", 15000)
		assert(api.nvim_get_current_win() == s.rightwin and s.right == second)
		assert(vim.deep_equal(api.nvim_win_get_cursor(s.rightwin), { 5, 1 }))
	end)
	for _, route in ipairs({ "edit", "buffer", "set_buf" }) do
		for _, search in ipairs({ false, true }) do
			add(
				"test_compare_picker_reviewed_file_" .. route .. (search and "_search_position" or "_editor_cursor"),
				function()
					local f = h.make_git_transfer_fixture()
					local s = open(f)
					api.nvim_set_current_win(s.rightwin)
					local first = s.right
					api.nvim_win_set_cursor(s.rightwin, { 3, 2 })
					keys("]b")
					ready(s)
					local review = s.right
					local review_position = api.nvim_win_get_cursor(s.rightwin)
					-- Pickers replace the focused pane before the router restores
					-- Compare and opens the selection in the original editor.
					if route == "edit" then
						vim.cmd.edit(vim.fn.fnameescape(f.file1))
					elseif route == "buffer" then
						-- Snacks lists its selection and uses :buffer, then sets the
						-- requested grep position after the buffer switch returns.
						vim.bo[first].buflisted = true
						vim.cmd.buffer(first)
					else
						api.nvim_win_set_buf(s.rightwin, first)
					end
					local expected = search and { 4, 1 } or { 1, 0 }
					if search then
						api.nvim_win_set_cursor(s.rightwin, expected)
					end
					ctx.wait_for(function()
						return api.nvim_get_current_win() == s.origin_edit_win and api.nvim_buf_get_name(0) == f.file1
					end, "picker did not open the reviewed file in the editor", 15000)
					assert(
						vim.deep_equal(api.nvim_win_get_cursor(0), expected),
						"picker cursor changed: " .. vim.inspect(api.nvim_win_get_cursor(0))
					)
					assert(s.shown_item.relpath == "beta.txt" and s.right == review)
					assert(api.nvim_win_get_buf(s.rightwin) == review)
					assert(vim.deep_equal(api.nvim_win_get_cursor(s.rightwin), review_position))
				end
			)
		end
	end
	for _, close_pane in ipairs({ false, true }) do
		add("test_compare_recovered_" .. (close_pane and "closed" or "retained") .. "_pane_native_jumps", function()
			local f = h.make_git_transfer_fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			local s = open(f)
			local function cycle()
				api.nvim_set_current_win(s.rightwin)
				api.nvim_win_set_cursor(s.rightwin, { 3, 2 })
				vim.cmd("clearjumps")
				keys("]b")
				ready(s)
				assert(s.shown_item.relpath == "beta.txt")
				keys("<C-O>")
				ctx.wait_for(function()
					return s.shown_item.relpath == "alpha.txt" and not s.preview_job
				end, "native jump did not restore the recovered comparison pair", 3000)
				assert(api.nvim_get_current_win() == s.rightwin)
				assert(vim.deep_equal(api.nvim_win_get_cursor(s.rightwin), { 3, 2 }))
				keys("<C-I>")
				ctx.wait_for(function()
					return s.shown_item.relpath == "beta.txt" and not s.preview_job
				end, "forward jump did not restore the comparison pair", 3000)
				assert(api.nvim_get_current_win() == s.rightwin)
				keys("[b")
				ready(s)
			end
			cycle()
			local original = s.right
			if close_pane then
				api.nvim_win_close(s.rightwin, true)
			end
			api.nvim_buf_delete(original, { force = true })
			ctx.wait_for(function()
				return not s.closed and s.preview_result and not s.worktree and s.right ~= original
			end, "buffer deletion did not recover to a snapshot", 15000)
			api.nvim_set_current_win(s.sidewin)
			api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["alpha.txt"], 0 })
			keys("<CR>")
			ready(s)
			assert(s.worktree, "reselection did not reacquire the real buffer")
			cycle()
		end)
	end
	add("test_compare_layout_preserves_open_diff_folds", function()
		local columns = vim.o.columns
		local ok, err = xpcall(function()
			vim.o.columns = 160
			local f = h.make_git_fixture()
			local lines = {}
			for i = 1, 150 do
				lines[i] = "line " .. i
			end
			h.write_file(f.file, table.concat(lines, "\n") .. "\n")
			h.exec({ "git", "commit", "-am", "long base" }, f.root)
			lines[20] = "changed twenty"
			h.write_file(f.file, table.concat(lines, "\n") .. "\n")
			local s = open(f)
			assert(not s.stacked)
			local levels = {}
			for _, win in ipairs({ s.leftwin, s.rightwin }) do
				api.nvim_win_call(win, function()
					vim.cmd("normal! zR")
					levels[win] = vim.wo.foldlevel
					assert(vim.fn.foldclosed(60) == -1)
				end)
			end
			for _, width in ipairs({ 80, 160 }) do
				vim.o.columns = width
				api.nvim_exec_autocmds("VimResized", {})
				assert(s.stacked == (width == 80))
				for _, win in ipairs({ s.leftwin, s.rightwin }) do
					api.nvim_win_call(win, function()
						assert(vim.wo.foldlevel == levels[win], "layout reset the pane's foldlevel")
						assert(vim.fn.foldclosed(60) == -1, "layout collapsed opened diff context")
					end)
				end
			end
		end, debug.traceback)
		vim.o.columns = columns
		assert(ok, err)
	end)
	for _, operation in ipairs({ "insertion", "deletion" }) do
		add(
			operation == "insertion" and "test_compare_immediate_edit_keeps_native_cursor"
				or "test_compare_immediate_edit_after_deletion_keeps_native_cursor",
			function()
				local f = fixture("git")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local s = open(f)
				local buf = s.right
				api.nvim_set_current_win(s.rightwin)
				-- One macro keeps the edit action ahead of the deferred preview capture.
				keys((operation == "insertion" and "ggOinserted<Esc>" or "ggdd") .. "30G02l<leader>ve")
				assert(api.nvim_get_current_win() == s.origin_win and api.nvim_get_current_buf() == buf)
				assert(s.preview_result.right[30] == "line 30", "preview unexpectedly caught up before the action")
				assert(
					vim.deep_equal(api.nvim_win_get_cursor(s.origin_win), { 30, 2 }),
					"edit projected a live cursor twice: " .. vim.inspect(api.nvim_win_get_cursor(s.origin_win))
				)
				assert(api.nvim_get_current_line() == (operation == "insertion" and "line 29" or "line 31"))
			end
		)
	end
	add("test_compare_jump_observer_namespaces_reuse_after_close", function()
		local first = h.make_git_fixture()
		local second = h.make_git_transfer_fixture()
		local s = open(first)
		local t = open(second)
		local callbacks = vim.on_key()
		assert(callbacks >= 2, "simultaneous sessions need separate observers")
		local function count()
			local total = 0
			for name in pairs(api.nvim_get_namespaces()) do
				if name:match("^lazyvcs_compare_jumps_") then
					total = total + 1
				end
			end
			return total
		end
		local peak = count()
		compare.close(s)
		assert(vim.on_key() == callbacks - 1, "closing one session removed another observer")
		compare.close(s)
		assert(vim.on_key() == callbacks - 1, "repeated close released an observer twice")
		for _ = 1, 4 do
			local next_session = open(first)
			assert(vim.on_key() == callbacks, "reopened session replaced an active observer")
			compare.close(next_session)
		end
		assert(count() == peak, "closed sessions accumulated jump-observer namespaces")
		api.nvim_set_current_win(t.rightwin)
		keys("]b")
		ready(t)
		assert(t.shown_item.relpath == "beta.txt")
		keys("<C-O>")
		ctx.wait_for(function()
			return t.shown_item.relpath == "alpha.txt" and not t.preview_job
		end, "namespace reuse broke the other session's jump routing", 3000)
		assert(api.nvim_get_current_win() == t.rightwin)
		compare.close(t)
		assert(vim.on_key() == callbacks - 2, "closing all sessions leaked observers")
	end)
	add("test_compare_reacquired_worktree_keeps_live_updates_after_clearjumps", function()
		local f = h.make_git_transfer_fixture()
		local s = open(f)
		api.nvim_set_current_win(s.rightwin)
		local first = s.right
		assert(s.worktree and not vim.bo[first].buflisted)
		keys("]b")
		ready(s)
		assert(s.shown_item.relpath == "beta.txt")
		keys("[b")
		ready(s)
		assert(s.shown_item.relpath == "alpha.txt" and s.right == first)
		assert(s.jump_buffers[first], "the reacquired buffer has no jump retention to trim")
		vim.cmd("clearjumps")
		-- A profile change rebuilds the preview and trims expired jump targets.
		keys(":setlocal fileformat=dos<CR>")
		ctx.wait_for(function()
			return not s.jump_buffers[first] and not s.preview_job
		end, "expired jump retention was not trimmed", 3000)
		assert(vim.bo[first].modifiable and s.right == first)
		api.nvim_buf_set_lines(first, 0, -1, false, { "one", "two", "three", "edited four", "five" })
		ctx.wait_for(function()
			return s.preview_result.right[4] == "edited four"
				and #s.navigation.saved == 1
				and s.navigation.saved[1].current_start == 4
		end, "trimming jump retention disconnected the active pane's live updates", 3000)
		api.nvim_win_set_cursor(s.rightwin, { 1, 0 })
		keys("]v")
		assert(api.nvim_win_get_cursor(s.rightwin)[1] == 4, "hunk navigation used stale text")
	end)
	for _, vcs in ipairs({ "git", "svn" }) do
		add("test_compare_" .. vcs .. "_metadata_reacquire_updates_hunks", function()
			local f, lines = fixture(vcs)
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local s = open(f)
			assert(s.navigation.saved[1].current_start == 5)
			s.actions.metadata()
			lines[5], lines[20] = "line 5", "changed 20"
			api.nvim_buf_set_lines(vim.fn.bufnr(f.file), 0, -1, false, lines)
			s.actions.metadata()
			assert(s.navigation.saved[1].current_start == 20, "metadata return reused stale hunks")
			api.nvim_set_current_win(s.rightwin)
			keys("]v")
			assert(api.nvim_win_get_cursor(s.rightwin)[1] == 20)
			local navigation = s.navigation
			s.actions.metadata()
			s.actions.metadata()
			assert(s.navigation == navigation, "unchanged documents reset review state")
			s.actions.metadata()
			lines[20], lines[30] = "line 20", "changed 30"
			api.nvim_buf_set_lines(vim.fn.bufnr(f.file), 0, -1, false, lines)
			keys("]v")
			assert(api.nvim_win_get_cursor(s.rightwin)[1] == 30, "metadata hunk intent used stale coordinates")
		end)
		add("test_compare_" .. vcs .. "_external_reread_updates_base_navigation", function()
			local f, lines = fixture(vcs)
			local s = open(f)
			local buf, record = s.right, s.worktree
			assert(record and not record.retained and not vim.bo[buf].buflisted)
			api.nvim_set_current_win(s.leftwin)
			vim.bo[buf].autoread = true
			lines[5], lines[20] = "line 5", "external 20"
			lines[41] = "external extra line"
			bytes(f.file, table.concat(lines, "\n") .. "\n")
			vim.cmd("checktime " .. buf)
			assert(api.nvim_buf_get_lines(buf, 19, 20, false)[1] == "external 20")
			ctx.wait_for(function()
				return s.navigation.saved[1] and s.navigation.saved[1].current_start == 20
			end, "external reread left navigation stale", 3000)
			keys("]v")
			assert(api.nvim_win_get_cursor(s.leftwin)[1] == 20)
			assert(not record.retained and not vim.bo[buf].buflisted, "reread adopted private buffer")
			compare.close(s)
			assert(not api.nvim_buf_is_loaded(buf))
		end)
		add("test_compare_" .. vcs .. "_editable_mixed_newlines_match_base", function()
			local f = fixture(vcs, true)
			local s = open(f)
			assert(s.worktree and vim.bo[s.right].fileformat == "unix")
			assert(api.nvim_buf_get_lines(s.left, 0, 1, false)[1] == "line 1\r", "base lost the real buffer's CR")
			assert(
				#s.navigation.saved == 1 and s.navigation.saved[1].current_start == 5,
				"mixed newlines invented an unchanged hunk"
			)
			compare.close(s)
			s = open(f, { editable = false })
			assert(s.preview_result.left[1] == "line 1" and s.preview_result.right[1] == "line 1")
		end)
		add("test_compare_" .. vcs .. "_snapshot_eof_only_navigation", function()
			local f, lines = fixture(vcs)
			lines[5] = "line 5"
			bytes(f.file, table.concat(lines, "\n"))
			local s = open(f, { editable = false })
			assert(s.preview_result.left_document.eol and not s.preview_result.right_document.eol)
			assert(#s.navigation.saved == 1 and s.navigation.saved[1].covers_eof, "snapshot lost EOF-only hunk")
			keys("<CR>")
			assert(api.nvim_get_current_win() == s.rightwin and api.nvim_win_get_cursor(s.rightwin)[1] == 40)
		end)
	end
	local function submodule()
		local sub, f = h.make_git_fixture(), h.make_git_fixture()
		h.exec({ "git", "commit", "--allow-empty", "-m", "unique submodule commit" }, sub.root)
		h.exec({ "git", "-c", "protocol.file.allow=always", "submodule", "add", sub.root, "sub" }, f.root)
		h.exec({ "git", "commit", "-am", "submodule base" }, f.root)
		return f,
			sub,
			{ root = f.root, base = "HEAD", revision = util.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root)) }
	end
	add("test_compare_deleted_gitlinks_use_submodule_summary", function()
		local f, _, snapshot = submodule()
		h.exec({ "git", "rm", "-f", "sub" }, f.root)
		for _, editable in ipairs({ false, true }) do
			local result, err = await(function(done)
				common
					.provider("git")
					.preview(snapshot, { status = "D", relpath = "sub" }, done, { editable = editable })
			end)
			assert(result, "deleted submodule preview failed: " .. tostring(err))
			assert(result.right_label == "SUBMODULE / DIRECTORY" and #result.left == 0)
			assert(table.concat(result.right, "\n"):find("Submodule sub", 1, true))
		end
		-- A gitlink replaced by a regular file must display the replacement patch.
		h.write_file(f.root .. "/sub", "replacement text\n")
		h.exec({ "git", "add", "sub" }, f.root)
		local result = assert(await(function(done)
			common.provider("git").preview(snapshot, { status = "T", relpath = "sub" }, done)
		end))
		assert(result.right_label == "SUBMODULE / DIRECTORY")
		assert(
			table.concat(result.right, "\n"):find("+replacement text", 1, true),
			"replacement file patch disappeared"
		)
	end)
	add("test_compare_submodule_preview_disables_forced_colors", function()
		local f, sub, snapshot = submodule()
		h.exec({ "git", "commit", "-am", "changed submodule" }, sub.root)
		h.exec({ "git", "-C", f.root .. "/sub", "fetch", sub.root }, f.root)
		h.exec({ "git", "-C", f.root .. "/sub", "checkout", "FETCH_HEAD" }, f.root)
		h.exec({ "git", "config", "color.ui", "always" }, f.root)
		local result = assert(await(function(done)
			common.provider("git").preview(snapshot, { status = "M", relpath = "sub" }, done)
		end))
		assert(not table.concat(result.right):find("\27", 1, true), "submodule preview contains ANSI escapes")
	end)
	add("test_compare_submodule_preview_enforces_byte_limit", function()
		local f, sub, snapshot = submodule()
		local message = sub.root .. "/message"
		bytes(message, string.rep("x", common.max_file_bytes + 100) .. "\n")
		h.exec({ "git", "commit", "-am", "placeholder" }, sub.root)
		h.exec({ "git", "commit", "--amend", "-F", message }, sub.root)
		h.exec({ "git", "-C", f.root .. "/sub", "fetch", sub.root }, f.root)
		h.exec({ "git", "-C", f.root .. "/sub", "checkout", "FETCH_HEAD" }, f.root)
		local result, err = await(function(done)
			common.provider("git").preview(snapshot, { status = "M", relpath = "sub" }, done)
		end)
		assert(not result and err and err:find("1 MiB", 1, true), "oversized submodule log entered preview")
	end)
	add("test_compare_sparse_index_revalidated_after_summary", function()
		local f = h.make_git_fixture()
		vim.fn.mkdir(f.root .. "/excluded", "p")
		h.write_file(f.root .. "/excluded/file", "base\n")
		h.exec({ "git", "add", "." }, f.root)
		h.exec({ "git", "commit", "-m", "base" }, f.root)
		h.write_file(f.root .. "/excluded/file", "old index\n")
		h.exec({ "git", "commit", "-am", "index" }, f.root)
		h.exec({ "git", "sparse-checkout", "init", "--cone" }, f.root)
		h.exec({ "git", "sparse-checkout", "set", "visible" }, f.root)
		local provider = common.provider("git")
		local snapshot = assert(await(function(done)
			provider.resolve({ root = f.root }, "HEAD^", done)
		end))
		local start, changed = util.system_start, false
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, done)
			return start(args, opts, function(raw)
				if vim.tbl_contains(args, "--summary") then
					local oid = util.trim(h.exec({ "git", "rev-parse", "HEAD^:excluded/file" }, f.root))
					h.exec({ "git", "update-index", "--cacheinfo", "100644," .. oid .. ",excluded/file" }, f.root)
					h.exec({ "git", "update-index", "--skip-worktree", "excluded/file" }, f.root)
					changed = true
				end
				done(raw)
			end)
		end
		local result, err = await(function(done)
			provider.preview(snapshot, { status = "M", relpath = "excluded/file" }, done)
		end)
		assert(changed)
		assert(not result and err and err:find("Index changed", 1, true), "summary published stale sparse contents")
	end)
	add("test_compare_svn_deleted_file_property_removals", function()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "propset", "custom:value", "BEFORE VALUE", "sample.txt" }, f.root)
		h.exec({ "svn", "commit", "-m", "properties" }, f.root)
		h.exec({ "svn", "delete", "sample.txt" }, f.root)
		local provider = common.provider("svn")
		local snapshot = assert(await(function(done)
			provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@2", done)
		end))
		local items = assert(await(function(done)
			provider.list(snapshot, false, done)
		end))
		local item = assert(items[1])
		assert(item.status == "D" and not item.properties)
		for _, mode in ipairs({ "text", "metadata" }) do
			local result = assert(await(function(done)
				provider.preview(snapshot, item, done, { mode = mode })
			end))
			assert(
				result.properties and table.concat(result.properties, "\n"):find("Deleted: custom:value", 1, true),
				"deleted SVN file lost its properties"
			)
		end
		local start = util.system_start
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, done)
			if vim.tbl_contains(args, "proplist") then
				return h.failed_system_spawn(start, args, opts, done)
			end
			return start(args, opts, done)
		end
		local result = assert(await(function(done)
			provider.preview(snapshot, item, done)
		end))
		assert(
			result.loaded.text and result.left[1] == "one" and result.details,
			"optional property failure hid the deleted file's text"
		)
	end)
	add("test_compare_svn_discovery_omits_canceled_file_changes", function()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "commit", "-m", "changed" }, f.root)
		h.write_file(f.file, "one\ntwo\nthree\n")
		local provider = common.provider("svn")
		local snapshot = assert(await(function(done)
			provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@1", done)
		end))
		local function list()
			return assert(await(function(done)
				provider.list(snapshot, false, done)
			end))
		end
		assert(#list() == 0, "net-clean SVN file remained in comparison")
		h.exec({ "svn", "propset", "custom:value", "changed", "sample.txt" }, f.root)
		assert(#list() == 1, "different properties were suppressed")
		h.exec({ "svn", "propdel", "custom:value", "sample.txt" }, f.root)
		local start = util.system_start
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, done)
			if vim.tbl_contains(args, "cat") then
				return h.failed_system_spawn(start, args, opts, done)
			end
			return start(args, opts, done)
		end
		assert(#list() == 1, "failed validation removed a candidate")
		util.system_start = start
	end)
	return cases
end
