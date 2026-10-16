return function(ctx)
	local api, h = vim.api, ctx.helpers
	local util, layout = require("lazyvcs.util"), require("lazyvcs.layout")
	local names = {
		"number",
		"relativenumber",
		"cursorline",
		"scrollbind",
		"cursorbind",
		"wrap",
		"linebreak",
		"breakindent",
		"smoothscroll",
		"foldenable",
		"foldmethod",
		"foldcolumn",
		"signcolumn",
		"spell",
		"list",
		"listchars",
		"winbar",
		"statusline",
		"statuscolumn",
		"winhighlight",
		"winblend",
	}
	local function get(win, name, scope)
		return api.nvim_get_option_value(name, { win = win, scope = scope or "local" })
	end
	local function set(win, name, value, scope)
		api.nvim_set_option_value(name, value, { win = win, scope = scope or "local" })
	end
	local function snapshot(win, scope)
		local values = {}
		for _, name in ipairs(names) do
			values[name] = get(win, name, scope)
		end
		return values
	end
	local function equal_options(win, values, scope)
		for name, value in pairs(values) do
			assert(get(win, name, scope) == value, name .. " changed " .. (scope or "local") .. " value")
		end
	end
	local function unbound(win)
		for _, name in ipairs({ "diff", "scrollbind", "cursorbind" }) do
			assert(get(win, name) == false, name .. " inherited by independent UI")
		end
	end
	local function child(win)
		api.nvim_win_call(win, function()
			local buf = api.nvim_create_buf(false, true)
			local float = api.nvim_open_win(buf, false, {
				relative = "editor",
				row = 1,
				col = 1,
				width = 20,
				height = 3,
			})
			local ok, err = pcall(unbound, float)
			api.nvim_win_close(float, true)
			api.nvim_buf_delete(buf, { force = true })
			assert(ok, err)
		end)
	end
	-- Restore modified defaults and close owned UI even when an assertion fails.
	local function guarded(fn)
		return function()
			layout = require("lazyvcs.layout")
			local win = api.nvim_get_current_win()
			local globals, locals = snapshot(win, "global"), snapshot(win)
			local diffopt, columns, lines, select = vim.o.diffopt, vim.o.columns, vim.o.lines, vim.ui.select
			local ok, err = xpcall(fn, debug.traceback)
			pcall(require("lazyvcs.source_control.native").close)
			pcall(require("lazyvcs.blame").blame_clear)
			pcall(h.cleanup)
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			win = api.nvim_get_current_win()
			for name, value in pairs(globals) do
				set(win, name, value, "global")
			end
			for name, value in pairs(locals) do
				set(win, name, value)
			end
			vim.o.diffopt, vim.o.columns, vim.o.lines, vim.ui.select = diffopt, columns, lines, select
			assert(ok, err)
		end
	end
	local function live()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
		local f = h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local win = api.nvim_get_current_win()
		set(win, "scrollbind", false, "global")
		set(win, "cursorbind", false, "global")
		return f, win
	end
	local function open_layout()
		local f, win = live()
		local s = {
			editable_bufnr = api.nvim_get_current_buf(),
			backend = "git",
			root = f.root,
			relpath = "sample.txt",
			base_label = "BASE",
			base_lines = { "one", "two", "three" },
			opts = vim.deepcopy(require("lazyvcs.config").get()),
		}
		local globals = snapshot(win, "global")
		layout.open(s)
		return s, globals
	end
	-- A full live-diff session, so its buffer and window autocmds run during the test.
	local function open_session()
		local _, win = live()
		local globals = snapshot(win, "global")
		local buf = api.nvim_get_current_buf()
		require("lazyvcs").open()
		local state = require("lazyvcs.state")
		ctx.wait_for(function()
			local s = state.get(buf)
			return s and s.base_win and api.nvim_win_is_valid(s.base_win)
		end, "live diff did not open", 15000)
		return assert(state.get(buf)), globals
	end
	local function session_intact(s)
		local live_session = require("lazyvcs.state").get(s.editable_bufnr)
		assert(live_session == s, "live diff session was replaced or closed")
		for _, pane in ipairs({ s.editable_win, s.base_win }) do
			assert(get(pane, "diff") and get(pane, "scrollbind"), "live diff pane lost its binding")
		end
	end
	local function blame(svn)
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { mode = "split" } })
		local f = svn and h.make_svn_fixture() or h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local source, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		set(source, "scrollbind", false, "global")
		set(source, "cursorbind", false, "global")
		local before, globals = snapshot(source), snapshot(source, "global")
		assert(require("lazyvcs.blame").blame_split())
		ctx.wait_for(function()
			local view = require("lazyvcs.blame")._test_blame_views()[buf]
			return view and view.winid and api.nvim_win_is_valid(view.winid)
		end, "blame split did not load", 15000)
		local view = require("lazyvcs.blame")._test_blame_views()[buf]
		for _, win in ipairs({ source, view.winid }) do
			equal_options(win, globals, "global")
			assert(get(win, "scrollbind") and get(win, "cursorbind"))
			child(win)
		end
		assert(not get(view.winid, "diff"))
		api.nvim_win_set_cursor(source, { 2, 0 })
		api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
		assert(api.nvim_win_get_cursor(view.winid)[1] == 2)
		require("lazyvcs.blame").blame_split()
		equal_options(source, before)
		equal_options(source, globals, "global")
	end
	local cases = {
		{
			"test_live_diff_repeated_readonly_comparisons_release_diff_buffers",
			function()
				local _, win = live()
				local globals = snapshot(win, "global")
				local actions = require("lazyvcs.actions")
				local diffopt = vim.o.diffopt
				vim.opt.diffopt:remove("hiddenoff")
				local external
				for file = 1, 10 do
					local s = assert(actions.open_target({
						backend = "git",
						kind = "git_diff",
						root = h.tempdir(),
						relpath = "readonly" .. file .. ".txt",
						left = { label = "BASE", lines = { "file " .. file, "before" } },
						right = { label = "SAVED", lines = { "file " .. file, "after" } },
					}))
					equal_options(s.editable_win, globals, "global")
					api.nvim_win_call(s.editable_win, function()
						vim.cmd("diffupdate")
						assert(vim.fn.diff_hlID(1, 1) == 0 and vim.fn.diff_hlID(2, 1) ~= 0)
					end)
					local base = s.base_bufnr
					if file == 1 then
						external = api.nvim_open_win(
							base,
							false,
							{ relative = "editor", row = 1, col = 1, width = 20, height = 3 }
						)
					end
					actions.close(s.editable_bufnr)
					assert(not api.nvim_buf_is_valid(base), "readonly base retained")
					assert(not api.nvim_buf_is_valid(s.editable_bufnr), "readonly right buffer retained")
				end
				if external and api.nvim_win_is_valid(external) then
					api.nvim_set_current_win(external)
					vim.cmd.tabclose()
				end
				local open = layout.open
				local windows_before = #api.nvim_list_wins()
				---@diagnostic disable-next-line: duplicate-set-field
				layout.open = function(session)
					open(session)
					error("forced open failure")
				end
				local ok, err = pcall(actions.open_target, {
					backend = "git",
					kind = "git_diff",
					root = h.tempdir(),
					relpath = "failure",
					left = { label = "BASE", lines = { "before" } },
					right = { label = "SAVED", lines = { "after" } },
				})
				layout.open = open
				vim.o.diffopt = diffopt
				assert(ok and err == nil, tostring(err))
				assert(#api.nvim_list_wins() == windows_before, "failed open left a pane behind")
			end,
		},
		{
			"test_core_window_option_helpers_preserve_globals",
			function()
				vim.cmd.enew()
				local origin = api.nvim_get_current_win()
				vim.cmd.vsplit()
				local win = api.nvim_get_current_win()
				api.nvim_set_current_win(origin)
				local values = { scrollbind = false, winblend = 7, winhighlight = "Normal:ErrorMsg" }
				for name, value in pairs(values) do
					set(win, name, value, "global")
				end
				util.set_win_option(win, "scrollbind", true)
				util.set_win_options(win, { winblend = 13, winhighlight = "Normal:Comment" })
				assert(util.get_win_option(win, "scrollbind") == true)
				assert(
					get(win, "scrollbind")
						and get(win, "winblend") == 13
						and get(win, "winhighlight") == "Normal:Comment"
				)
				equal_options(win, values, "global")
				assert(api.nvim_get_current_win() == origin)
			end,
		},
		{
			"test_core_window_option_snapshots_preserve_global_local_fallbacks",
			function()
				local win = api.nvim_get_current_win()
				local fallback = { winbar = "", statusline = "", listchars = "" }
				for name, value in pairs(fallback) do
					set(win, name, value)
				end
				local saved = util.capture_win_options(win, { "winbar", "statusline", "listchars" })
				assert(vim.deep_equal(saved, fallback))
				local explicit = { winbar = "local bar", statusline = "local status", listchars = "tab:>-" }
				util.set_win_options(win, explicit)
				local override = util.capture_win_options(win, { "winbar", "statusline", "listchars" })
				for name, value in pairs({ winbar = "new bar", statusline = "new status", listchars = "tab:| " }) do
					set(win, name, value, "global")
				end
				local globals = snapshot(win, "global")
				util.set_win_options(win, saved)
				equal_options(win, fallback)
				assert(vim.wo[win].winbar == "new bar" and vim.wo[win].statusline == "new status")
				util.set_win_options(win, override)
				equal_options(win, explicit)
				equal_options(win, globals, "global")
			end,
		},
		{
			"test_live_diff_window_options_do_not_bind_new_floats",
			function()
				local s, globals = open_layout()
				for _, win in ipairs({ s.editable_win, s.base_win }) do
					equal_options(win, globals, "global")
					child(win)
					assert(get(win, "scrollbind") and get(win, "cursorbind") and get(win, "diff"))
				end
				layout.refresh(s)
				layout.rebalance(s)
				equal_options(s.editable_win, globals, "global")
				layout.close(s)
				equal_options(s.editable_win, globals, "global")
			end,
		},
		{
			"test_live_diff_surviving_base_restores_all_window_options",
			function()
				local _, win = live()
				for name, value in pairs({
					number = true,
					relativenumber = true,
					cursorline = true,
					wrap = true,
					linebreak = true,
					breakindent = true,
					foldmethod = "manual",
					foldenable = false,
					winbar = "",
				}) do
					set(win, name, value)
				end
				local s = {
					editable_bufnr = api.nvim_get_current_buf(),
					backend = "git",
					root = h.tempdir(),
					relpath = "survivor",
					base_label = "BASE",
					base_lines = { "one" },
					opts = vim.deepcopy(require("lazyvcs.config").get()),
				}
				local expected = snapshot(win)
				layout.open(s)
				local base_options = vim.deepcopy(s.base_window_options)
				api.nvim_set_current_win(s.base_win)
				vim.cmd.only()
				layout.close(s)
				assert(not api.nvim_buf_is_valid(s.base_bufnr))
				for name, value in pairs(base_options) do
					assert(get(s.base_win, name) == value, name .. " not restored")
				end
				for _, name in ipairs({ "number", "relativenumber", "cursorline", "winbar" }) do
					assert(get(s.base_win, name) == expected[name], name .. " lost user setting")
				end
				assert(not get(s.base_win, "winfixwidth"))
			end,
		},
		{
			"test_live_diff_winbar_restores_global_fallback",
			function()
				for _, original in ipairs({ "", "my local bar" }) do
					local _, win = live()
					set(win, "winbar", "old global", "global")
					set(win, "winbar", original)
					local s = {
						editable_bufnr = api.nvim_get_current_buf(),
						backend = "git",
						root = h.tempdir(),
						relpath = "winbar",
						base_label = "BASE",
						base_lines = { "one" },
						opts = vim.deepcopy(require("lazyvcs.config").get()),
					}
					layout.open(s)
					set(win, "winbar", "new global", "global")
					layout.refresh(s)
					layout.close(s)
					assert(get(win, "winbar") == original, "raw winbar fallback lost")
					assert(vim.wo[win].winbar == (original == "" and "new global" or original))
					assert(get(win, "winbar", "global") == "new global")
				end
			end,
		},
		{
			"test_blame_split_window_options_do_not_bind_new_floats",
			function()
				blame(false)
			end,
		},
		{
			"test_svn_blame_split_window_options_are_local",
			function()
				blame(true)
			end,
		},
		{
			"test_source_control_sidebar_from_diff_is_unbound",
			function()
				local s, globals = open_session()
				for _, pane in ipairs({ s.editable_win, s.base_win }) do
					api.nvim_set_current_win(pane)
					local native = require("lazyvcs.source_control.native")
					local sidebar = native.open({ path = s.root })
					unbound(sidebar.winid)
					child(sidebar.winid)
					equal_options(sidebar.winid, globals, "global")
					native.close()
					vim.wait(50)
					session_intact(s)
				end
				require("lazyvcs").close()
			end,
		},
		{
			"test_source_control_editor_from_sidebar_uses_editor_options",
			function()
				local f, win = live()
				set(win, "number", true, "global")
				set(win, "wrap", false, "global")
				set(win, "foldmethod", "indent", "global")
				set(win, "foldcolumn", "1", "global")
				set(win, "winbar", "user bar", "global")
				local globals = snapshot(win, "global")
				local native = require("lazyvcs.source_control.native")
				local s = native.open({ path = f.root })
				vim.cmd.only()
				h.write_file(f.root .. "/editor.txt", "editor\n")
				s.lazyvcs_open_file(s, f.root .. "/editor.txt")
				win = api.nvim_get_current_win()
				unbound(win)
				assert(get(win, "number") and not get(win, "wrap"), "editor lost the user's wrap default")
				assert(
					get(win, "foldmethod") == "indent" and get(win, "foldcolumn") == "1",
					"editor lost fold defaults"
				)
				assert(
					get(win, "winbar") == "" and get(win, "statusline") == "" and not get(win, "winfixwidth"),
					vim.inspect({
						winbar = get(win, "winbar"),
						statusline = get(win, "statusline"),
						fixed = get(win, "winfixwidth"),
					})
				)
				equal_options(win, globals, "global")
				api.nvim_set_current_win(s.winid)
				vim.cmd.only()
				native.close()
				win = api.nvim_get_current_win()
				unbound(win)
				assert(get(win, "number") and not get(win, "wrap") and not get(win, "winfixwidth"))
				assert(get(win, "foldmethod") == "indent" and get(win, "foldcolumn") == "1")
			end,
		},
		{
			"test_source_control_popup_options_preserve_globals",
			function()
				local s, globals = open_layout()
				local confirm = require("lazyvcs.source_control.confirm")
				local input = require("lazyvcs.source_control.input")
				api.nvim_set_current_win(s.editable_win)
				local popup = confirm.open({}, function() end)
				unbound(popup.winid)
				child(popup.winid)
				equal_options(popup.winid, globals, "global")
				local selected = false
				---@diagnostic disable-next-line: duplicate-set-field
				vim.ui.select = function(_, _, callback)
					selected = true
					local buf = api.nvim_create_buf(false, true)
					local float =
						api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 20, height = 3 })
					unbound(float)
					child(float)
					equal_options(float, globals, "global")
					api.nvim_win_close(float, true)
					api.nvim_buf_delete(buf, { force = true })
					callback("Replace current message")
				end
				local nested = input.open_text({
					default_value = "draft",
					can_generate = true,
					on_generate = function(done)
						done("generated")
						return nil
					end,
				}, function() end)
				unbound(nested.winid)
				child(nested.winid)
				equal_options(nested.winid, globals, "global")
				nested.generate()
				assert(selected and api.nvim_buf_get_lines(nested.bufnr, 0, 1, false)[1] == "generated")
				nested.close()
				popup.close()
				layout.close(s)
			end,
		},
		{
			"test_blame_popup_options_preserve_globals",
			function()
				local _, win = live()
				local globals = snapshot(win, "global")
				set(win, "scrollbind", true)
				set(win, "cursorbind", true)
				local before = api.nvim_list_wins()
				assert(require("lazyvcs.blame_selection").open(1, 2))
				local popup = api.nvim_get_current_win()
				unbound(popup)
				child(popup)
				equal_options(popup, globals, "global")
				api.nvim_win_close(popup, true)
				api.nvim_set_current_win(win)
				assert(require("lazyvcs.blame").line_log())
				ctx.wait_for(function()
					return #api.nvim_list_wins() > #before
				end, "line log did not open", 15000)
				for _, candidate in ipairs(api.nvim_list_wins()) do
					if not vim.tbl_contains(before, candidate) then
						unbound(candidate)
						child(candidate)
						equal_options(candidate, globals, "global")
					end
				end
			end,
		},
		{
			"test_core_show_text_from_diff_is_unbound",
			function()
				local s, globals = open_layout()
				api.nvim_set_current_win(s.editable_win)
				local buf = util.show_text("Output", { "one", "two" })
				local win = api.nvim_get_current_win()
				assert(api.nvim_win_get_buf(win) == buf)
				unbound(win)
				child(win)
				equal_options(win, globals, "global")
				assert(get(s.editable_win, "diff") and get(s.base_win, "diff"))
				api.nvim_win_close(win, true)
				layout.close(s)
			end,
		},
		{
			"test_core_diff_off_keeps_options_after_diff_ended",
			function()
				vim.cmd.enew()
				local win = api.nvim_get_current_win()
				vim.cmd("vsplit")
				vim.cmd.enew()
				for _, w in ipairs({ win, api.nvim_get_current_win() }) do
					set(w, "wrap", true)
					set(w, "foldmethod", "manual")
					set(w, "foldcolumn", "0")
					api.nvim_win_call(w, function()
						vim.cmd("diffthis")
					end)
				end
				util.diff_off(win)
				assert(not get(win, "diff"))
				local prefs = { wrap = false, foldmethod = "indent", foldcolumn = "1" }
				for name, value in pairs(prefs) do
					set(win, name, value)
				end
				-- A second native :diffoff here would restore the pre-diff values saved above.
				util.diff_off(win)
				equal_options(win, prefs)
				vim.cmd("diffoff!")
			end,
		},
		{
			"test_blame_split_does_not_leave_listed_buffers",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { mode = "split", persist = false },
				})
				local f = h.make_git_fixture()
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local buf = api.nvim_get_current_buf()
				local before = vim.fn.getbufinfo({ buflisted = 1 })
				for _ = 1, 3 do
					assert(require("lazyvcs.blame").blame_split())
					ctx.wait_for(function()
						local view = require("lazyvcs.blame")._test_blame_views()[buf]
						return view and view.winid and api.nvim_win_is_valid(view.winid)
					end, "blame split did not load", 15000)
					require("lazyvcs.blame").blame_split()
					assert(not require("lazyvcs.blame")._test_blame_views()[buf], "blame split did not close")
					-- Let the closed split's scheduled cleanup run, as it does between key presses.
					vim.wait(20)
				end
				assert(#vim.fn.getbufinfo({ buflisted = 1 }) == #before, "blame split left listed buffers")
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
