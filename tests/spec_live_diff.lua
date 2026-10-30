return function(ctx)
	local h, wait, open = ctx.helpers, ctx.wait_for, ctx.open_diff
	local state, actions, layout = require("lazyvcs.state"), require("lazyvcs.actions"), require("lazyvcs.layout")
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = { "test_live_diff_" .. name, fn }
	end
	local function fixture(opts, svn, before_open, opener)
		actions, layout = require("lazyvcs.actions"), require("lazyvcs.layout")
		require("lazyvcs").setup(
			vim.tbl_deep_extend(
				"force",
				{ signs = { enabled = false }, blame = { persist = false }, debounce_ms = 10 },
				opts or {}
			)
		)
		local f = svn and h.make_svn_transfer_fixture() or h.make_git_transfer_fixture()
		vim.cmd.tabnew()
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		if before_open then
			before_open(f)
		end
		return f, (opener or open)()
	end
	local function bound(s)
		assert(state.get(s.editable_bufnr) == s, "session identity changed")
		for _, w in ipairs({ s.editable_win, s.base_win }) do
			assert(vim.wo[w].diff, "owned pane lost diff")
			assert(vim.wo[w].scrollbind, "owned pane lost scrollbind")
			assert(vim.wo[w].cursorbind == s.opts.base_window.cursor_sync, "cursor_sync changed")
		end
	end
	local function target(path)
		local b = vim.fn.bufadd(path)
		vim.fn.bufload(b)
		return b
	end
	local function transferred(old, path)
		local replacement
		wait(function()
			replacement = state.get(vim.api.nvim_win_get_buf(old.editable_win))
			return replacement and replacement ~= old and replacement.source_path == path
		end, "transfer did not commit", ctx.async_timeout_ms)
		assert(replacement.base_win == old.base_win, "transfer destroyed base window")
		assert(replacement.base_bufnr == old.base_bufnr, "transfer replaced scratch buffer")
		assert(
			vim.bo[replacement.base_bufnr].readonly and not vim.bo[replacement.base_bufnr].modifiable,
			"scratch became writable"
		)
		assert(vim.bo[replacement.base_bufnr].buftype == "nofile" and not vim.bo[replacement.base_bufnr].buflisted)
		assert(
			vim.api.nvim_buf_get_name(replacement.base_bufnr):find(replacement.relpath, 1, true),
			"base name is stale"
		)
		bound(replacement)
		return replacement
	end
	local function float(buf, enter)
		return vim.api.nvim_open_win(
			buf or vim.api.nvim_create_buf(false, true),
			enter,
			{ relative = "editor", row = 2, col = 4, width = 35, height = 5, style = "minimal", border = "single" }
		)
	end
	local function focus_roundtrip(s, fn)
		local before = vim.api.nvim_win_call(s.editable_win, vim.fn.winsaveview)
		fn()
		bound(s)
		assert(not state.peek_pending_transfer(s.editable_win), "focus queued transfer")
		vim.api.nvim_set_current_win(s.editable_win)
		bound(s)
		assert(
			vim.deep_equal(before, vim.api.nvim_win_call(s.editable_win, vim.fn.winsaveview)),
			"focus changed editor view"
		)
	end
	local function public_open()
		local buf = vim.api.nvim_get_current_buf()
		require("lazyvcs").open()
		wait(function()
			return state.get(buf) ~= nil
		end, "public live diff session did not open", ctx.async_timeout_ms)
		return assert(state.get(buf))
	end
	for _, pane in ipairs({ "editable_win", "base_win" }) do
		add("show_text_from_" .. pane .. "_preserves_real_session", function()
			local _, s = fixture(nil, nil, nil, public_open)
			vim.api.nvim_set_current_win(s[pane])
			local buf = require("lazyvcs.util").show_text("Output", { "a" })
			local output = vim.api.nvim_get_current_win()
			assert(vim.api.nvim_win_get_buf(output) == buf and output ~= s[pane])
			vim.wait(80)
			bound(s)
			assert(not state.peek_pending_transfer(s.editable_win), "output queued transfer")
			vim.api.nvim_win_close(output, true)
			vim.wait(80)
			bound(s)
			assert(not state.peek_pending_transfer(s.editable_win), "closing output queued transfer")
		end)
		add("native_sidebar_from_" .. pane .. "_preserves_real_session", function()
			local f, s = fixture(nil, nil, nil, public_open)
			vim.api.nvim_set_current_win(s[pane])
			local native = require("lazyvcs.source_control.native")
			local sidebar = native.open({ path = f.root })
			assert(vim.api.nvim_win_is_valid(sidebar.winid) and sidebar.winid ~= s[pane])
			wait(function()
				return sidebar.lazyvcs_discovering ~= true and sidebar.lazyvcs_repo_specs ~= nil
			end, "sidebar discovery did not finish", ctx.async_timeout_ms)
			bound(s)
			assert(not state.peek_pending_transfer(s.editable_win), "sidebar queued transfer")
			native.close()
			vim.wait(80)
			assert(not sidebar.winid, "sidebar did not close")
			bound(s)
			assert(not state.peek_pending_transfer(s.editable_win), "closing sidebar queued transfer")
		end)
	end
	add("markdown_transfer_keeps_target_filetype_window_options", function()
		local wrap, linebreak, diffopt = vim.o.wrap, vim.o.linebreak, vim.o.diffopt
		local detecting = vim.fn.exists("#filetypedetect") == 1
		local group = vim.api.nvim_create_augroup("lazyvcs_test_transfer_filetype", { clear = true })
		local ok, err = xpcall(function()
			vim.o.wrap, vim.o.linebreak = false, false
			vim.opt.diffopt:append("followwrap")
			vim.cmd("filetype on")
			local f = h.make_git_markdown_transfer_fixture()
			vim.api.nvim_create_autocmd("FileType", {
				group = group,
				pattern = "markdown",
				callback = function()
					vim.opt_local.wrap, vim.opt_local.linebreak = true, true
				end,
			})
			require("lazyvcs").setup({ signs = { enabled = false }, blame = { persist = false } })
			vim.cmd.tabnew()
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			local s = public_open()
			-- An explicit change in the old pane must not override the target's FileType settings.
			vim.wo[s.editable_win].wrap, vim.wo[s.editable_win].linebreak = false, false
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			local r = transferred(s, f.file2)
			assert(vim.bo[r.editable_bufnr].filetype == "markdown", "target FileType did not run")
			assert(vim.wo[r.editable_win].wrap and vim.wo[r.editable_win].linebreak, "transfer lost Markdown options")
			actions.close(r.editable_bufnr)
			assert(vim.wo[r.editable_win].wrap and vim.wo[r.editable_win].linebreak, "close lost Markdown options")
		end, debug.traceback)
		vim.api.nvim_del_augroup_by_id(group)
		if not detecting then
			vim.cmd("filetype off")
		end
		vim.o.wrap, vim.o.linebreak, vim.o.diffopt = wrap, linebreak, diffopt
		if not ok then
			error(err, 0)
		end
	end)
	add("transfer_close_restores_target_number_foldcolumn_and_raw_winbar", function()
		local winbar = vim.api.nvim_get_option_value("winbar", { scope = "global" })
		local group = vim.api.nvim_create_augroup("lazyvcs_test_transfer_options", { clear = true })
		local ok, err = xpcall(function()
			vim.api.nvim_set_option_value("winbar", "global fallback", { scope = "global" })
			local f, s = fixture(nil, nil, function()
				vim.wo.number, vim.wo.foldcolumn, vim.wo.winbar = false, "1", "original"
			end)
			local entered = false
			vim.api.nvim_create_autocmd("BufWinEnter", {
				group = group,
				pattern = f.file2,
				callback = function()
					entered = true
					vim.wo.number, vim.wo.foldcolumn, vim.wo.winbar = true, "3", ""
				end,
			})
			vim.wo[s.editable_win].number, vim.wo[s.editable_win].foldcolumn = false, "5"
			vim.wo[s.editable_win].winbar = "user override"
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			local r = transferred(s, f.file2)
			assert(entered, "target window options were not set")
			assert(vim.wo[r.editable_win].number, "transfer lost target number")
			actions.close(r.editable_bufnr)
			assert(vim.wo[r.editable_win].number, "close lost target number")
			assert(vim.wo[r.editable_win].foldcolumn == "3", "close lost target foldcolumn")
			assert(
				require("lazyvcs.util").get_win_option(r.editable_win, "winbar") == "",
				"close lost raw target winbar"
			)
		end, debug.traceback)
		vim.api.nvim_del_augroup_by_id(group)
		vim.api.nvim_set_option_value("winbar", winbar, { scope = "global" })
		if not ok then
			error(err, 0)
		end
	end)
	add("base_focus_preserves_binding_and_view", function()
		local _, s = fixture()
		focus_roundtrip(s, function()
			vim.api.nvim_set_current_win(s.base_win)
		end)
	end)
	add("other_split_focus_preserves_session", function()
		local _, s = fixture()
		focus_roundtrip(s, function()
			vim.cmd("rightbelow vnew")
		end)
	end)
	add("picker_float_focus_preserves_session", function()
		local _, s = fixture()
		for _, enter in ipairs({ true, false }) do
			local w
			focus_roundtrip(s, function()
				w = float(nil, enter)
				vim.api.nvim_set_current_win(w)
			end)
			vim.api.nvim_win_close(w, true)
		end
	end)
	add("same_buffer_float_preserves_session", function()
		local _, s = fixture()
		focus_roundtrip(s, function()
			float(s.editable_bufnr, true)
			vim.api.nvim_set_current_win(s.base_win)
		end)
	end)
	add("picker_selection_transfers_in_editor", function()
		local f, s = fixture()
		local w = float(nil, true)
		bound(s)
		vim.api.nvim_win_close(w, true)
		vim.api.nvim_win_set_buf(s.editable_win, target(f.file2))
		local r = transferred(s, f.file2)
		assert(vim.deep_equal(vim.api.nvim_buf_get_lines(r.base_bufnr, 0, -1, false), f.base2))
	end)
	add("tree_selection_transfers_in_editor", function()
		local f, s = fixture()
		vim.cmd("leftabove vnew")
		bound(s)
		local tree = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(s.editable_win)
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		transferred(s, f.file2)
		assert(vim.api.nvim_win_is_valid(tree), "tree window closed")
	end)
	add("editor_commands_transfer", function()
		local f, s = fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		s = transferred(s, f.file2)
		vim.cmd.buffer(target(f.file1))
		s = transferred(s, f.file1)
		vim.cmd("bnext")
		transferred(s, f.file2)
	end)
	add("api_swap_from_other_window", function()
		local f, s = fixture()
		local b = target(f.file2)
		for _, other in ipairs({ false, true }) do
			if other then
				vim.cmd("rightbelow vnew")
			else
				vim.api.nvim_set_current_win(s.base_win)
			end
			local caller = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(s.editable_win, b)
			s = transferred(s, other and f.file1 or f.file2)
			assert(vim.api.nvim_get_current_win() == caller, "transfer stole focus")
			b = target(f.file1)
		end
	end)
	add("api_swap_from_other_tab", function()
		local f, s = fixture()
		local b = target(f.file2)
		vim.cmd.tabnew()
		local caller = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(s.editable_win, b)
		transferred(s, f.file2)
		assert(vim.api.nvim_get_current_win() == caller, "background transfer stole focus")
	end)
	add("split_swap_does_not_transfer_owner", function()
		local f, s = fixture()
		local b = target(f.file2)
		vim.cmd.split()
		local sw = vim.api.nvim_get_current_win()
		assert(vim.wo[sw].diff, "split must retain native diff inheritance")
		vim.api.nvim_win_set_buf(sw, b)
		vim.wait(80)
		bound(s)
		assert(vim.api.nvim_win_get_buf(s.editable_win) == s.editable_bufnr)
	end)
	local function restored_split(win, before)
		assert(not vim.wo[win].diff, "session-derived split retained diff")
		for _, name in ipairs({ "scrollbind", "cursorbind", "foldmethod" }) do
			assert(vim.wo[win][name] == before[name], "split did not restore " .. name)
		end
	end
	local function clean_pair(s)
		for _, win in ipairs({ s.editable_win, s.base_win }) do
			vim.api.nvim_win_call(win, function()
				vim.cmd("diffupdate")
				for line = 1, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) do
					assert(vim.fn.diff_hlID(line, 1) == 0, "old editable buffer leaked into native diff set")
				end
			end)
		end
	end
	local function stale_display(other_tab, base)
		local f, s = fixture(nil, nil, function()
			vim.wo.foldmethod = "indent"
		end)
		-- New target equals the base; old E differs. Any stale membership adds highlighting.
		h.write_file(f.file2, table.concat(f.base1, "\n") .. "\n")
		h.exec({ "git", "add", "beta.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "equal target" }, f.root)
		if base then
			vim.api.nvim_set_current_win(s.base_win)
		end
		vim.cmd(other_tab and "tab split" or "split")
		local duplicate = vim.api.nvim_get_current_win()
		assert(vim.wo[duplicate].diff, "split must retain native diff inheritance")
		vim.api.nvim_set_current_win(s.editable_win)
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		local r = transferred(s, f.file2)
		clean_pair(r)
		if other_tab then
			assert(vim.wo[duplicate].diff, "changed another tab's display options")
		else
			restored_split(duplicate, s.editable_window_options)
		end
	end
	add("editor_swap_with_duplicate_display", function()
		stale_display(false)
	end)
	add("editor_swap_with_other_tab_display", function()
		stale_display(true)
	end)
	add("inherited_base_split_transfer_restores_options", function()
		stale_display(false, true)
	end)
	add("inherited_split_close_restores_options", function()
		local _, s = fixture(nil, nil, function()
			vim.wo.foldmethod = "indent"
		end)
		vim.cmd.split()
		local duplicate = vim.api.nvim_get_current_win()
		assert(vim.wo[duplicate].diff, "split must retain native diff inheritance")
		vim.api.nvim_set_current_win(s.editable_win)
		vim.cmd("LazyVCS diff close")
		restored_split(duplicate, s.editable_window_options)
	end)
	add("preexisting_diff_split_survives_transfer_and_close", function()
		local duplicate
		local f, s = fixture(nil, nil, function()
			local ew = vim.api.nvim_get_current_win()
			vim.cmd.split()
			duplicate = vim.api.nvim_get_current_win()
			vim.cmd.diffthis()
			vim.api.nvim_set_current_win(ew)
		end)
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		local r = transferred(s, f.file2)
		assert(vim.wo[duplicate].diff, "transfer disabled a pre-existing diff window")
		actions.close(r.editable_bufnr)
		assert(vim.wo[duplicate].diff, "close disabled a pre-existing diff window")
	end)
	add("close_from_editable_does_not_prepare_transfer", function()
		local _, s = fixture()
		local util, aerial = require("lazyvcs.util"), require("lazyvcs.integrations.aerial")
		local notify, suspend = util.notify, aerial.suspend_win
		local messages, suspends = {}, 0
		---@diagnostic disable-next-line: duplicate-set-field
		util.notify = function(msg)
			messages[#messages + 1] = msg
		end
		---@diagnostic disable-next-line: duplicate-set-field
		aerial.suspend_win = function()
			suspends = suspends + 1
		end
		local ok, err = xpcall(function()
			vim.api.nvim_set_current_win(s.editable_win)
			vim.cmd.close()
			wait(function()
				return not state.get(s.editable_bufnr)
			end)
			assert(#messages == 0, "closing EW notified: " .. table.concat(messages, "; "))
			assert(suspends == 0, "closing EW suspended Aerial for a transfer")
			assert(s.phase == "closed" and not state.peek_pending_transfer(s.editable_win))
		end, debug.traceback)
		util.notify, aerial.suspend_win = notify, suspend
		if not ok then
			error(err, 0)
		end
	end)
	add("pending_record_from_other_session_is_disposed", function()
		local _, s = fixture()
		local disposed, killed = 0, 0
		local stale = {
			session = {},
			editable_win = s.editable_win,
			handle = {
				kill = function()
					killed = killed + 1
				end,
			},
			dispose = function()
				disposed = disposed + 1
			end,
		}
		state.set_pending_transfer(s.editable_win, stale)
		vim.api.nvim_exec_autocmds("BufWinLeave", { buffer = s.editable_bufnr })
		local pending = state.peek_pending_transfer(s.editable_win)
		assert(pending and pending ~= stale and pending.session == s, "reused another session's pending record")
		assert(stale.cancelled and killed == 1 and disposed == 1, "stale record was not fully disposed")
		wait(function()
			return not state.peek_pending_transfer(s.editable_win)
		end)
		bound(s)
	end)
	add("last_display_detaches_before_hide", function()
		local f, s = fixture()
		local observed = false
		local id = vim.api.nvim_create_autocmd("BufWinLeave", {
			buffer = s.editable_bufnr,
			callback = function()
				observed = true
				assert(not vim.wo[s.editable_win].diff, "old E still diffed before hiding")
			end,
		})
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		vim.api.nvim_del_autocmd(id)
		assert(observed, "did not exercise last display leave")
		transferred(s, f.file2)
	end)
	add("tab_navigation_preserves_session", function()
		local _, s = fixture()
		local tab = vim.api.nvim_get_current_tabpage()
		focus_roundtrip(s, function()
			vim.cmd.tabnew()
			bound(s)
			vim.api.nvim_set_current_tabpage(tab)
		end)
	end)
	local function delayed(fn)
		local backend = require("lazyvcs.backends")
		local previous = backend.load_async
		local requests = {}
		---@diagnostic disable-next-line: duplicate-set-field
		backend.load_async = function(path, done)
			local r = { path = path, done = done, killed = false }
			requests[#requests + 1] = r
			return {
				kill = function()
					r.killed = true
				end,
			}
		end
		local ok, err = xpcall(function()
			fn(requests)
		end, debug.traceback)
		backend.load_async = previous
		if not ok then
			error(err, 0)
		end
	end
	local function result(f, path)
		return {
			name = "git",
			impl = require("lazyvcs.backends.git"),
			root = f.root,
			relpath = vim.fn.fnamemodify(path, ":t"),
			tracked = true,
			base_label = "HEAD",
			base_lines = path == f.file1 and f.base1 or f.base2,
		}
	end
	local function request(rs, n)
		wait(function()
			return #rs >= n
		end, "request missing")
		return rs[n]
	end
	add("cursor_sync_false_survives_restore_and_transfer", function()
		local f, s = fixture({ base_window = { cursor_sync = false } })
		vim.api.nvim_set_current_win(s.base_win)
		vim.api.nvim_set_current_win(s.editable_win)
		bound(s)
		delayed(function(rs)
			vim.api.nvim_win_set_buf(s.editable_win, target(f.file2))
			request(rs, 1)
			vim.api.nvim_win_set_buf(s.editable_win, s.editable_bufnr)
			wait(function()
				return not state.peek_pending_transfer(s.editable_win)
			end)
			bound(s)
		end)
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		bound(transferred(s, f.file2))
	end)
	add("aborted_replacement_restores_contract", function()
		local _, s = fixture({ base_window = { cursor_sync = false } })
		-- Fire the real pre-hide event without replacing E, as an aborted :edit does.
		vim.api.nvim_exec_autocmds("BufWinLeave", { buffer = s.editable_bufnr })
		assert(not vim.wo[s.editable_win].diff)
		wait(function()
			return state.peek_pending_transfer(s.editable_win) == nil
		end)
		bound(s)
	end)
	add("latest_target_wins", function()
		local f, s = fixture()
		local b = target(f.file2)
		local third = f.root .. "/third.txt"
		h.write_file(third, "third\n")
		local c = target(third)
		delayed(function(rs)
			vim.api.nvim_win_set_buf(s.editable_win, b)
			local first = request(rs, 1)
			vim.api.nvim_win_set_buf(s.editable_win, c)
			local last = request(rs, 2)
			assert(first.killed, "superseded load was not cancelled")
			first.done(result(f, f.file2))
			assert(state.get(s.editable_bufnr) == s, "stale callback retired owner")
			last.done(result(f, third))
			transferred(s, third)
		end)
	end)
	add("return_to_original_cancels_transfer", function()
		local f, s = fixture({ base_window = { cursor_sync = false } })
		local b = target(f.file2)
		delayed(function(rs)
			vim.api.nvim_win_set_buf(s.editable_win, b)
			local r = request(rs, 1)
			vim.api.nvim_win_set_buf(s.editable_win, s.editable_bufnr)
			wait(function()
				return not state.peek_pending_transfer(s.editable_win)
			end)
			assert(r.killed)
			bound(s)
			r.done(result(f, f.file2))
			bound(s)
		end)
	end)
	add("close_during_transfer_cancels", function()
		for _, close in ipairs({ "explicit", "base", "editable" }) do
			local f, s = fixture()
			local b = target(f.file2)
			delayed(function(rs)
				vim.api.nvim_win_set_buf(s.editable_win, b)
				local r = request(rs, 1)
				if close == "explicit" then
					actions.close(s.editable_bufnr)
				else
					vim.api.nvim_win_close(close == "base" and s.base_win or s.editable_win, true)
				end
				wait(function()
					return state.get(s.editable_bufnr) == nil
				end)
				assert(r.killed and not state.peek_pending_transfer(s.editable_win))
				r.done(result(f, f.file2))
				assert(not state.get(b), "late callback resurrected session")
				assert(s.phase == "closed", "closed lifecycle retained ownership")
			end)
		end
	end)
	add("unsupported_target_cleans_session", function()
		local _, s = fixture()
		local b = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(s.editable_win, b)
		wait(function()
			return not state.get(s.editable_bufnr)
		end)
		assert(not vim.api.nvim_win_is_valid(s.base_win), "stale base survived")
		assert(not vim.wo[s.editable_win].diff and not state.peek_pending_transfer(s.editable_win))
		assert(s.phase == "closed")
	end)
	add("transfer_error_is_contained", function()
		for _, name in ipairs({ "load", "rebind", "bind", "integration" }) do
			local f, s = fixture()
			local b = target(f.file2)
			local object, key
			if name == "load" then
				object, key = require("lazyvcs.backends"), "load_async"
			elseif name == "integration" then
				object, key = require("lazyvcs.integrations.aerial"), "suspend_win"
			else
				object, key = layout, name == "bind" and "bind_pair" or "rebind"
			end
			local original, notify = object[key], require("lazyvcs.util").notify
			local messages = {}
			---@diagnostic disable-next-line: duplicate-set-field
			require("lazyvcs.util").notify = function(msg)
				messages[#messages + 1] = msg
			end
			object[key] = function()
				error("injected\nfailure")
			end
			local ok, err = xpcall(function()
				vim.api.nvim_win_set_buf(s.editable_win, b)
				wait(function()
					return #messages > 0
				end, "error was not reported: " .. name)
			end, debug.traceback)
			object[key], require("lazyvcs.util").notify = original, notify
			if not ok then
				error(err, 0)
			end
			assert(#messages == 1 and not messages[1]:find("\n"), "error must be one single-line notification")
			assert(not state.get(s.editable_bufnr) and not state.get(b), "failed transfer retained session")
		end
	end)
	add("sync_scroll_rejects_unbound_pair", function()
		local _, s = fixture()
		for _, w in ipairs({ s.base_win, s.editable_win }) do
			vim.api.nvim_set_option_value("scrollbind", false, { win = w, scope = "local" })
			assert(layout.sync_scroll(s, s.editable_win) == false, "sync accepted an unbound pair")
			vim.api.nvim_set_option_value("scrollbind", true, { win = w, scope = "local" })
		end
		vim.api.nvim_win_set_buf(s.editable_win, vim.api.nvim_create_buf(false, true))
		assert(not layout.sync_scroll(s, s.base_win), "sync accepted wrong buffer")
	end)
	local function width(s, w)
		layout.rebalance(s)
		local t = vim.api.nvim_win_get_width(s.base_win) + vim.api.nvim_win_get_width(s.editable_win)
		local minimum = math.min(30, math.floor(t / 2))
		local expected = math.max(minimum, math.min(t - minimum, math.floor(w <= 1 and t * w or w)))
		assert(math.abs(vim.api.nvim_win_get_width(s.base_win) - expected) <= 1, "configured width was discarded")
	end
	add("configured_width_survives_rebalance", function()
		local columns = vim.o.columns
		for _, w in ipairs({ 0.45, 0.3, 0.7, 52 }) do
			vim.o.columns = 220
			local _, s = fixture({ base_window = { width = w } })
			width(s, w)
			vim.o.columns = 48
			width(s, w)
			vim.o.columns = 220
			width(s, w)
			actions.close(s.editable_bufnr)
			vim.cmd("tabclose!")
		end
		vim.o.columns = columns
	end)
	add("configured_width_excludes_sidebar", function()
		local columns = vim.o.columns
		vim.o.columns = 220
		local _, s = fixture({ base_window = { width = 0.45 } })
		vim.cmd("topleft vnew")
		vim.api.nvim_win_set_width(0, 40)
		width(s, 0.45)
		vim.o.columns = columns
	end)
	add("resize_work_converges", function()
		local columns = vim.o.columns
		vim.o.columns = 220
		local _, s = fixture({ base_window = { width = 0.3 } })
		width(s, 0.3)
		for _ = 1, 5 do
			assert(not layout.rebalance(s), "rebalance did not converge")
		end
		vim.cmd("wincmd J")
		local before = vim.api.nvim_win_get_width(s.base_win)
		assert(not layout.rebalance(s), "stacked pair resized")
		assert(vim.api.nvim_win_get_width(s.base_win) == before)
		vim.o.columns = columns
	end)
	add("sessions_and_requests_are_isolated", function()
		local first, owner = fixture()
		local second, peer = fixture()
		local a, b = target(first.file2), target(second.file2)
		delayed(function(rs)
			vim.api.nvim_win_set_buf(owner.editable_win, a)
			local one = request(rs, 1)
			vim.api.nvim_win_set_buf(peer.editable_win, b)
			local two = request(rs, 2)
			actions.close(owner.editable_bufnr)
			assert(one.killed and not two.killed, "cancellation crossed session ownership")
			two.done(result(second, second.file2))
			local live = transferred(peer, second.file2)
			one.done(result(first, first.file2))
			bound(live)
		end)
		local f, s = fixture()
		local b = target(f.file2)
		vim.cmd.tabnew()
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		local other = open()
		vim.api.nvim_win_set_buf(s.editable_win, b)
		wait(function()
			return not state.get(s.editable_bufnr)
		end)
		bound(other)
		assert(state.for_window(s.editable_win).paused, "collision should pause without stealing ownership")
		assert(vim.api.nvim_win_is_valid(s.base_win) and not vim.wo[s.base_win].diff)
		assert(s.phase == "closed")
	end)
	add("svn_transfer_from_other_window", function()
		local f, s = fixture(nil, true)
		local b = target(f.file2)
		vim.api.nvim_set_current_win(s.base_win)
		vim.api.nvim_win_set_buf(s.editable_win, b)
		local r = transferred(s, f.file2)
		assert(r.backend == "svn" and vim.deep_equal(vim.api.nvim_buf_get_lines(r.base_bufnr, 0, -1, false), f.base2))
		assert(vim.api.nvim_get_current_win() == s.base_win)
	end)
	add("svn_transfer_added_and_unsupported", function()
		local f, s = fixture(nil, true)
		vim.api.nvim_win_set_buf(s.editable_win, target(f.added))
		s = transferred(s, f.added)
		assert(#s.base_lines == 0, "SVN added file must have empty base")
		vim.api.nvim_win_set_buf(s.editable_win, target(f.untracked))
		wait(function()
			return not state.get(s.editable_bufnr)
		end)
		assert(state.for_window(s.editable_win).paused and not state.peek_pending_transfer(s.editable_win))
	end)
	add("markdown_transfer_restores_first_guard_snapshot", function()
		require("lazyvcs").setup({ signs = { enabled = false }, blame = { persist = false } })
		local f = h.make_git_markdown_transfer_fixture()
		vim.cmd.tabnew()
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		local s = open()
		local first = vim.api.nvim_create_autocmd("BufReadPre", {
			pattern = f.file2,
			once = true,
			callback = function(a)
				assert(vim.b[a.buf].snacks_scope == false, "Markdown was not guarded before reading")
			end,
		})
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		local b = vim.api.nvim_get_current_buf()
		wait(function()
			local r = state.get(b)
			return r and r ~= s
		end, nil, ctx.async_timeout_ms)
		actions.close(b)
		assert(vim.b[b].snacks_scope == nil and vim.b[b].snacks_indent == nil, "Markdown retained transfer guards")
		for _, mode in ipairs({ "cancel", "fail" }) do
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			s = open()
			local md = vim.fn.bufnr(f.file2)
			vim.b[md].snacks_scope = { enabled = true }
			vim.b[md].snacks_indent = true
			delayed(function(rs)
				-- Re-read so BufReadPre owns the first snapshot before FileType can run.
				vim.cmd("bunload " .. md)
				vim.cmd.edit(vim.fn.fnameescape(f.file2))
				local pending = request(rs, 1)
				assert(vim.b[md].snacks_scope == false)
				if mode == "cancel" then
					vim.api.nvim_win_set_buf(s.editable_win, s.editable_bufnr)
					wait(function()
						return not state.peek_pending_transfer(s.editable_win)
					end)
				else
					pending.done(nil, "not tracked")
				end
				assert(
					vim.deep_equal(vim.b[md].snacks_scope, { enabled = true }) and vim.b[md].snacks_indent == true,
					"abandoned guard lost original values"
				)
				if mode == "cancel" then
					actions.close(s.editable_bufnr)
				end
			end)
		end

		pcall(vim.api.nvim_del_autocmd, first)
	end)
	add("closed_sessions_are_collectable_without_edit", function()
		local _, s = fixture()
		local b = s.editable_bufnr
		local weak = setmetatable({ s }, { __mode = "v" })
		actions.close(b)
		s = nil
		vim.wait(120)
		collectgarbage("collect")
		collectgarbage("collect")
		assert(weak[1] == nil, "buffer attachment retained closed session")
		-- Reuse the same attachment through another open; idle edits remain harmless.
		open()
		actions.close(b)
		vim.api.nvim_buf_set_lines(b, 0, 1, false, { "idle edit" })
		assert(not state.get(b))
	end)
	for _, scenario in ipairs({ "closed", "transfer", "user" }) do
		add("revisit_cleans_saved_options_" .. scenario, function()
			local f, s = fixture(nil, nil, function()
				vim.wo.foldmethod, vim.wo.foldcolumn, vim.wo.winbar = "indent", "2", "original A"
			end)
			local ew = s.editable_win
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			local r = transferred(s, f.file2)
			if scenario ~= "transfer" then
				actions.close(r.editable_bufnr)
			end
			if scenario == "user" then
				vim.cmd.edit(vim.fn.fnameescape(f.file1))
				vim.wo.winbar, vim.wo.foldcolumn = "user A", "4"
				vim.cmd.edit(vim.fn.fnameescape(f.file2))
			end
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			if scenario == "transfer" then
				r = transferred(r, f.file1)
				assert(r.editable_prev_winbar == "original A", "captured stale label")
				actions.close(r.editable_bufnr)
			end
			assert(
				not vim.wo[ew].diff and not vim.wo[ew].scrollbind and not vim.wo[ew].cursorbind,
				"saved diff resurrected"
			)
			assert(vim.wo[ew].foldmethod == "indent", "saved foldmethod resurrected")
			assert(vim.wo[ew].winbar == (scenario == "user" and "user A" or "original A"), "stale winbar")
			assert(vim.wo[ew].foldcolumn == (scenario == "user" and "4" or "2"), "lost foldcolumn")
		end)
	end
	for _, mode in ipairs({ "unsupported", "failed", "cancelled" }) do
		add("departed_close_preserves_incoming_options_" .. mode, function()
			local _, s = fixture(nil, nil, function()
				vim.wo.wrap, vim.wo.linebreak, vim.wo.number = false, false, false
			end)
			local path = h.tempdir() .. "/outside.md"
			h.write_file(path, "# Outside\n")
			local group = vim.api.nvim_create_augroup("lazyvcs_test_outside_options", { clear = true })
			vim.api.nvim_create_autocmd("FileType", {
				group = group,
				pattern = "markdown",
				callback = function()
					vim.wo.wrap, vim.wo.linebreak, vim.wo.number, vim.wo.winbar = true, true, true, "outside"
				end,
			})
			local detecting = vim.fn.exists("#filetypedetect") == 1
			vim.cmd("filetype on")
			local ok, err = xpcall(function()
				delayed(function(rs)
					vim.cmd.edit(vim.fn.fnameescape(path))
					local req = request(rs, 1)
					if mode == "cancelled" then
						actions.close(s.editable_bufnr)
					else
						req.done(nil, mode == "unsupported" and "not tracked" or "read failed")
					end
					assert(not state.get(s.editable_bufnr))
					assert(
						vim.wo[s.editable_win].wrap and vim.wo[s.editable_win].linebreak,
						"lost incoming Markdown options"
					)
					assert(
						vim.wo[s.editable_win].number and vim.wo[s.editable_win].winbar == "outside",
						"restored outgoing options"
					)
				end)
			end, debug.traceback)
			vim.api.nvim_del_augroup_by_id(group)
			if not detecting then
				vim.cmd("filetype off")
			end
			if not ok then
				error(err, 0)
			end
		end)
	end
	local function scratch_count()
		local count = 0
		for _, b in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_get_name(b):find("lazyvcs://", 1, true) then
				count = count + 1
			end
		end
		return count
	end
	add("repeated_transfers_do_not_leak_scratch_buffers", function()
		local before = scratch_count()
		local f, s = fixture()
		for i = 1, 6 do
			local path = i % 2 == 1 and f.file2 or f.file1
			vim.cmd.edit(vim.fn.fnameescape(path))
			s = transferred(s, path)
			assert(scratch_count() == before + 1, "rename leaked alternate scratch buffer")
		end
		actions.close(s.editable_bufnr)
		assert(scratch_count() == before, "close leaked scratch buffer")
	end)
	for _, command in ipairs({ "toggle", "close", "explicit_target", "open_target" }) do
		add("loading_session_lookup_" .. command, function()
			local f, s = fixture()
			delayed(function(rs)
				vim.cmd.edit(vim.fn.fnameescape(f.file2))
				local b = vim.api.nvim_get_current_buf()
				local req = request(rs, 1)
				if command == "toggle" then
					assert(state.current() == s, "loading editor lost current session")
					vim.cmd("LazyVCS diff toggle")
				elseif command == "close" then
					require("lazyvcs").close()
				elseif command == "explicit_target" then
					vim.api.nvim_set_current_win(s.base_win)
					actions.close(b)
				else
					actions.open_target({
						backend = "git",
						root = f.root,
						path = f.file2,
						relpath = "beta.txt",
						kind = "git_worktree",
						left = { label = "HEAD", lines = f.base2 },
						right = { label = "Worktree", modifiable = true },
						editable_side = "right",
					})
				end
				assert(state.get(s.editable_bufnr) ~= s, "loading session survived command")
				assert(req.killed, "loading backend was not cancelled")
				assert(#state.list() == (command == "open_target" and 1 or 0), "duplicate session")
				req.done(result(f, f.file2))
				assert(state.get(s.editable_bufnr) ~= s, "late callback revived session")
			end)
		end)
	end
	add("guard_only_read_does_not_rebind_or_refetch", function()
		local f, s = fixture()
		local aerial = require("lazyvcs.integrations.aerial")
		local bind, refetch = layout.bind_pair, aerial.refetch_buffer
		local binds, fetches = 0, 0
		---@diagnostic disable-next-line: duplicate-set-field
		layout.bind_pair = function(...)
			binds = binds + 1
			return bind(...)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		aerial.refetch_buffer = function(...)
			fetches = fetches + 1
			return refetch(...)
		end
		local ok, err = xpcall(function()
			local b = vim.fn.bufadd(f.file2)
			vim.api.nvim_exec_autocmds("BufReadPre", { buffer = b })
			assert(state.peek_pending_transfer(s.editable_win), "guard did not record read")
			wait(function()
				return not state.peek_pending_transfer(s.editable_win)
			end)
			assert(binds == 0 and fetches == 0, "guard-only read rebound/refetched")
			bound(s)
		end, debug.traceback)
		layout.bind_pair, aerial.refetch_buffer = bind, refetch
		if not ok then
			error(err, 0)
		end
	end)
	add("base_transfers_do_not_retain_undo_documents", function()
		local f, s = fixture()
		local a = s.editable_bufnr
		vim.api.nvim_buf_set_lines(a, 0, 1, false, { "unsaved user text" })
		for i = 1, 6 do
			local path = i % 2 == 1 and f.file2 or f.file1
			vim.cmd.edit(vim.fn.fnameescape(path))
			s = transferred(s, path)
		end
		local tree = vim.api.nvim_buf_call(s.base_bufnr, vim.fn.undotree)
		assert(#tree.entries == 0, "base retained old documents in undo")
		assert(vim.bo[a].undolevels ~= -1, "editable undo disabled")
		assert(#vim.api.nvim_buf_call(a, vim.fn.undotree).entries > 0, "editable undo history lost")
	end)
	for _, outcome in ipairs({ "commit", "abort" }) do
		add("loading_resize_replayed_on_" .. outcome, function()
			local f, s = fixture({ base_window = { width = 0.5 } })
			delayed(function(rs)
				vim.cmd.edit(vim.fn.fnameescape(f.file2))
				local req = request(rs, 1)
				vim.cmd("topleft vnew")
				vim.api.nvim_win_set_width(0, 30)
				vim.api.nvim_exec_autocmds("WinResized", {})
				vim.wait(80)
				if outcome == "commit" then
					req.done(result(f, f.file2))
					s = transferred(s, f.file2)
				else
					vim.api.nvim_win_set_buf(s.editable_win, s.editable_bufnr)
					wait(function()
						return not state.peek_pending_transfer(s.editable_win)
					end)
				end
				assert(
					math.abs(vim.api.nvim_win_get_width(s.base_win) - vim.api.nvim_win_get_width(s.editable_win)) <= 1,
					"loading resize was dropped"
				)
				bound(s)
			end)
		end)
	end
	add("revert_rejects_loading_session_and_preserves_hidden_edits", function()
		local f, s = fixture()
		local a = s.editable_bufnr
		vim.api.nvim_buf_set_lines(a, 0, 1, false, { "precious unsaved edit" })
		local before = vim.api.nvim_buf_get_lines(a, 0, -1, false)
		actions.refresh_current()
		wait(function()
			return s.hunks and s.hunks[1] and s.hunks[1].current_start == 1
		end)
		delayed(function(rs)
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			request(rs, 1)
			vim.api.nvim_win_set_cursor(s.editable_win, { 1, 0 })
			vim.api.nvim_set_current_win(s.base_win)
			local confirmation = actions.revert_hunk()
			local cb = vim.fn.maparg("1", "n", false, true).callback
			if cb then
				cb()
			end
			assert(
				vim.deep_equal(before, vim.api.nvim_buf_get_lines(a, 0, -1, false)),
				"reverted hidden outgoing buffer"
			)
			assert(confirmation == false, "loading session opened confirmation")
		end)
	end)
	add("outgoing_aerial_backend_is_reattached_in_buffer_context", function()
		local names = { "aerial", "aerial.backends", "aerial.util" }
		local saved = {}
		for _, name in ipairs(names) do
			saved[name] = package.loaded[name]
		end
		local attached, watches, contexts = {}, {}, {}
		package.loaded["aerial.util"] = {
			is_ignored_win = function()
				return false
			end,
		}
		package.loaded["aerial.backends"] = {
			get_attached_backend = function(b)
				return attached[b]
			end,
			get_backend_by_name = function()
				return {
					detach = function(b)
						attached[b], watches[b] = nil, false
					end,
				}
			end,
		}
		package.loaded["aerial"] = {
			refetch_symbols = function(b)
				attached[b], watches[b], contexts[b] = "markdown", true, vim.api.nvim_get_current_buf()
			end,
		}
		local ok, err = xpcall(function()
			local f, s = fixture()
			local a = s.editable_bufnr
			wait(function()
				return watches[a]
			end)
			vim.cmd.split()
			local other = vim.api.nvim_get_current_win()
			vim.api.nvim_set_current_win(s.editable_win)
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			transferred(s, f.file2)
			vim.wait(80)
			assert(vim.api.nvim_win_get_buf(other) == a)
			assert(watches[a] and attached[a] == "markdown", "outgoing backend lost watchers")
			assert(contexts[a] == a, "refetched outgoing backend in incoming context")
		end, debug.traceback)
		for _, name in ipairs(names) do
			package.loaded[name] = saved[name]
		end
		if not ok then
			error(err, 0)
		end
	end)
	add("revert_confirmation_rechecks_loading_phase", function()
		local f, s = fixture()
		local a = s.editable_bufnr
		vim.api.nvim_buf_set_lines(a, 1, 2, false, { "precious edit" })
		vim.api.nvim_win_set_cursor(s.editable_win, { 2, 0 })
		local before = vim.api.nvim_buf_get_lines(a, 0, -1, false)
		local dialog = actions.revert_hunk()
		assert(type(dialog) == "table" and dialog.winid)
		local choose = vim.fn.maparg("1", "n", false, true).callback
		delayed(function(rs)
			vim.api.nvim_win_set_buf(s.editable_win, target(f.file2))
			request(rs, 1)
			-- Keep the captured buffer context valid while the session is loading.
			-- This isolates the phase check from the existing context checks.
			vim.api.nvim_win_set_buf(s.editable_win, a)
			vim.api.nvim_win_set_cursor(s.editable_win, { 2, 0 })
			choose()
			assert(
				vim.deep_equal(before, vim.api.nvim_buf_get_lines(a, 0, -1, false)),
				"confirmation mutated during loading"
			)
			assert(not vim.api.nvim_win_is_valid(dialog.winid))
		end)
	end)
	return cases
end
