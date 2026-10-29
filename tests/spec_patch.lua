return function(ctx)
	local h = ctx.helpers
	local patch = require("lazyvcs.patch")
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		fd:close()
	end
	local function read(path)
		local fd = assert(io.open(path, "rb"))
		local bytes = fd:read("*a")
		fd:close()
		return bytes
	end
	local function wait(fn)
		ctx.wait_for(fn, "patch did not finish", 15000)
	end
	local function get(path, opts)
		local done, text, err
		require("lazyvcs").patch(vim.tbl_extend("force", opts or {}, {
			path = path,
			on_done = function(t, e)
				done, text, err = true, t, e
			end,
		}))
		wait(function()
			return done
		end)
		assert(not err, err)
		return text
	end
	local function ui(path, opts)
		local task = patch.open(vim.tbl_extend("force", { path = path }, opts or {}))
		local buf = vim.api.nvim_get_current_buf()
		wait(function()
			return task.done
		end)
		return buf, vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	end
	local function keys(text)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end
	local function contains(text, part)
		assert(text:find(part, 1, true), "missing " .. vim.inspect(part) .. " in " .. text)
	end
	local function lacks(text, part)
		assert(not text:find(part, 1, true), "unexpected " .. part .. " in " .. text)
	end
	local function fixture()
		return h.make_git_fixture()
	end
	local cases = {}
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_" .. name,
			function()
				local cwd = vim.fn.getcwd()
				local config = require("lazyvcs.config")
				local original = vim.deepcopy(config.get())
				local process = require("lazyvcs.backends.process")
				local start, facade = process.start, require("lazyvcs.backends").patch_repository_async
				local group = vim.api.nvim_create_augroup("lazyvcs_patch_tests", { clear = true })
				local ok, err = xpcall(fn, debug.traceback)
				vim.api.nvim_del_augroup_by_id(group)
				process.start, require("lazyvcs.backends").patch_repository_async = start, facade
				patch._test_output_limit = nil
				for _, buf in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_get_name(buf):match("^lazyvcs://patch/") then
						pcall(vim.api.nvim_buf_delete, buf, { force = true })
					end
				end
				if package.loaded["lazyvcs.compare"] then
					pcall(require("lazyvcs.compare").close)
				end
				if package.loaded["lazyvcs.source_control.native"] then
					pcall(require("lazyvcs.source_control.native").close)
				end
				vim.cmd.cd(cwd)
				config.setup(original)
				assert(ok, err)
			end,
		}
	end
	case("git_staged_and_unstaged_against_head", function()
		local f = fixture()
		write(f.root .. "/staged.txt", "staged\n")
		h.exec({ "git", "add", "staged.txt" }, f.root)
		write(f.root .. "/staged.txt", "staged and unstaged\n")
		local text = get(f.root)
		contains(text, "+changed")
		contains(text, "+staged and unstaged")
		lacks(text, "+staged\n")
	end)
	case("git_subdirectory_cwd_is_literal_and_root_relative", function()
		local f = fixture()
		local name = vim.fn.has("win32") == 1 and "space é" or "space é*?"
		local dir = f.root .. "/" .. name
		vim.fn.mkdir(dir)
		write(dir .. "/-file.txt", "subtree\n")
		vim.cmd.lcd(dir)
		local done, text
		require("lazyvcs").patch({
			on_done = function(t, e)
				assert(not e, e)
				text, done = t, true
			end,
		})
		wait(function()
			return done
		end)
		contains(text, "b/" .. name .. "/-file.txt")
		lacks(text, "sample.txt")
		local committed = get(dir, { include_untracked = false })
		assert(committed == "")
	end)
	case("git_two_repositories_in_path_order", function()
		local f = h.make_git_source_control_fixture()
		write(f.git_clean .. "/new.txt", "second\n")
		local text = get(f.root)
		local a = assert(text:find("# Repository: " .. f.git_dirty, 1, true))
		local b = assert(text:find("# Repository: " .. f.git_clean, 1, true))
		assert(a < b)
		contains(text, "+changed")
		contains(text, "+second")
	end)
	case("git_unborn_head_staged_files", function()
		local root = h.tempdir()
		h.exec({ "git", "init" }, root)
		write(root .. "/new.txt", "first\n")
		h.exec({ "git", "add", "new.txt" }, root)
		contains(get(root), "+first")
	end)
	case("git_unborn_sha256", function()
		local root = h.tempdir()
		local result = vim.system({ "git", "init", "--object-format=sha256" }, { cwd = root }):wait()
		if result.code ~= 0 then
			error({ lazyvcs_skip = "Git does not support SHA-256 repositories" })
		end
		write(root .. "/new.txt", "sha256\n")
		h.exec({ "git", "add", "new.txt" }, root)
		contains(get(root), "+sha256")
	end)
	case("git_untracked_on_off_and_ignored", function()
		local f = fixture()
		write(f.root .. "/new.txt", "untracked\n")
		write(f.root .. "/.gitignore", "ignored.txt\n")
		write(f.root .. "/ignored.txt", "ignored\n")
		contains(get(f.root), "+untracked")
		lacks(get(f.root), "b/ignored.txt")
		lacks(get(f.root, { include_untracked = false }), "new.txt")
	end)
	case("git_binary_diagnostic", function()
		local f = fixture()
		write(f.root .. "/binary", "a\0b")
		contains(get(f.root), "Binary files /dev/null and b/binary differ")
	end)
	case("output_cap_stops_commands", function()
		local f = fixture()
		write(f.root .. "/new.txt", "must not read this section\n")
		patch._test_output_limit = 32
		local start = require("lazyvcs.backends.process").start
		local calls = {}
		---@diagnostic disable-next-line: duplicate-set-field
		require("lazyvcs.backends.process").start = function(args, opts, done)
			calls[#calls + 1] = table.concat(args, " ")
			assert(opts.output_limit_bytes or args[2] == "rev-parse" or args[1] == "svn")
			return start(args, opts, done)
		end
		local text = get(f.root)
		contains(text, "\n# lazyvcs: output truncated at 16 MiB\n")
		assert(#text <= 32 + 1 + #"# lazyvcs: output truncated at 16 MiB\n")
		lacks(table.concat(calls, "\n"), "ls-files")
	end)
	case("cancel_api_suppresses_callback", function()
		local f = fixture()
		local called = false
		local task = require("lazyvcs").patch({
			path = f.root,
			on_done = function()
				called = true
			end,
		})
		task:cancel()
		vim.wait(100, function()
			return false
		end)
		assert(not called)
	end)
	case("cancel_buffer_close_suppresses_late_result", function()
		local f = fixture()
		local late, child
		---@diagnostic disable-next-line: duplicate-set-field
		require("lazyvcs.backends").patch_repository_async = function(_, _, _, done)
			late = done
			child = require("lazyvcs.backends.task").new()
			return child
		end
		local task = patch.open({ path = f.root })
		local buf = vim.api.nvim_get_current_buf()
		wait(function()
			return late ~= nil
		end)
		vim.api.nvim_buf_delete(buf, { force = true })
		late(true)
		assert(task.cancelled and child.cancelled)
	end)
	case("rerun_supersedes_previous_and_reuses_buffer", function()
		local f = fixture()
		local callbacks, appends, children = {}, {}, {}
		---@diagnostic disable-next-line: duplicate-set-field
		require("lazyvcs.backends").patch_repository_async = function(_, _, opts, done)
			callbacks[#callbacks + 1], appends[#appends + 1] = done, opts.append
			local child = require("lazyvcs.backends.task").new()
			children[#children + 1] = child
			return child
		end
		local first = patch.open({ path = f.root })
		local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
		wait(function()
			return #callbacks == 1
		end)
		contains(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "Loading patch")
		contains(vim.wo.winbar, "LOADING")
		local second = patch.open({ path = f.root })
		assert(vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_current_win() == win)
		wait(function()
			return #callbacks == 2
		end)
		assert(first.cancelled and children[1].cancelled)
		appends[2]("new run\n")
		callbacks[2](true)
		appends[1]("stale run\n")
		callbacks[1](true)
		assert(second.done)
		assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "new run")
	end)
	case("enter_opens_new_side_line", function()
		local f = fixture()
		local editor = vim.api.nvim_get_current_win()
		local _, rows = ui(f.root)
		local row
		for i, text in ipairs(rows) do
			if text == "+changed" then
				row = i
			end
		end
		assert(row)
		vim.api.nvim_win_set_cursor(0, { row, 0 })
		keys("<CR>")
		assert(vim.api.nvim_get_current_win() == editor)
		assert(vim.api.nvim_buf_get_name(0) == f.file)
		assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
		if vim.fn.has("win32") == 0 then
			write(f.file, "one\ntwo\nthree\n")
			assert(vim.uv.fs_chmod(f.file, 493))
			ui(f.root)
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			keys("gf")
			assert(vim.api.nvim_buf_get_name(0) == f.file)
		end
	end)
	case("hunk_navigation_counts", function()
		local f = fixture()
		local base = {}
		for i = 1, 40 do
			base[i] = tostring(i)
		end
		write(f.file, table.concat(base, "\n") .. "\n")
		h.exec({ "git", "add", "sample.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "lines" }, f.root)
		base[2], base[20], base[39] = "a", "b", "c"
		write(f.file, table.concat(base, "\n") .. "\n")
		local _, rows = ui(f.root)
		local hunks = {}
		for i, text in ipairs(rows) do
			if text:match("^@@") then
				hunks[#hunks + 1] = i
			end
		end
		assert(#hunks == 3)
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		keys("2]v")
		assert(vim.api.nvim_win_get_cursor(0)[1] == hunks[2])
		keys("]v")
		assert(vim.api.nvim_win_get_cursor(0)[1] == hunks[3])
		keys("2[v")
		assert(vim.api.nvim_win_get_cursor(0)[1] == hunks[1])
	end)
	case("yank_and_write_exact_raw_bytes", function()
		local f = fixture()
		write(f.file, "one\r\nchanged\255\r\nthree\r\n")
		local text = get(f.root)
		local buf = ui(f.root)
		keys("Y")
		assert(vim.fn.getreg('"') == text)
		keys('"aY')
		assert(vim.fn.getreg("a") == text)
		local out = h.tempdir() .. "/patch.diff"
		vim.cmd("write! " .. vim.fn.fnameescape(out))
		assert(read(out) == text)
		assert(not vim.bo[buf].modifiable and vim.bo[buf].filetype == "diff")
	end)
	case("regression_yank_operator_and_whole_patch_Y", function()
		local f = fixture()
		local text = get(f.root)
		local _, rows = ui(f.root)
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.cmd("normal! yy")
		assert(vim.fn.getreg('"') == rows[1] .. "\n", "normal! yy must yank one patch line")
		keys("yy")
		assert(vim.fn.getreg('"') == rows[1] .. "\n", "mapped yy must retain the yank operator")
		keys("Y")
		assert(vim.fn.getreg('"') == text, "Y must copy the whole patch")
		keys('"aY')
		assert(vim.fn.getreg("a") == text, "Y must respect v:register")
	end)
	case("regression_sidebar_splits_preferred_editor", function()
		local f = fixture()
		vim.cmd("vnew")
		local editor = vim.api.nvim_get_current_win()
		local sidebar = require("lazyvcs.source_control.native")
		local state = sidebar.open({ path = f.root })
		wait(function()
			return state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[f.root] and not state.lazyvcs_discovering
		end)
		assert(state.editor_winid == editor)
		local side = state.winid
		local buf, width, height =
			vim.api.nvim_win_get_buf(side), vim.api.nvim_win_get_width(side), vim.api.nvim_win_get_height(side)
		local pos = vim.fn.win_screenpos(side)
		vim.api.nvim_set_current_win(side)
		local picker = require("lazyvcs.picker")
		local select, public = picker.select, require("lazyvcs")
		local open, options = public.patch
		picker.select = function(items, _, done)
			for _, item in ipairs(items) do
				if item.label == "Show patch" then
					return done(item)
				end
			end
		end
		public.patch = function(opts)
			options = opts
			return open(opts)
		end
		local ok, err = pcall(
			require("lazyvcs.source_control.ops").repo_action_picker,
			state,
			{ type = "repo", extra = { repo_root = f.root } }
		)
		picker.select, public.patch = select, open
		assert(ok, err)
		local win = vim.api.nvim_get_current_win()
		assert(vim.api.nvim_win_get_width(win) ~= width, "patch split the sidebar column")
		assert(vim.api.nvim_win_get_width(side) == width and vim.api.nvim_win_get_height(side) == height)
		assert(vim.api.nvim_win_get_buf(side) == buf and vim.deep_equal(vim.fn.win_screenpos(side), pos))
		assert(vim.fn.win_screenpos(win)[2] == vim.fn.win_screenpos(editor)[2])
		assert(vim.fn.win_screenpos(win)[1] < vim.fn.win_screenpos(editor)[1])
		assert(options.editor_winid == editor, "Show patch must pass the sidebar's editor")
	end)
	case("regression_compare_opens_new_tab", function()
		local f = fixture()
		local compare = require("lazyvcs.compare")
		local s = assert(compare.open({ path = f.root, base = "HEAD", editable = false }))
		wait(function()
			return s.preview_result and not s.preview_job and not s.job
		end)
		vim.api.nvim_set_current_win(s.rightwin)
		local tab, wins = vim.api.nvim_get_current_tabpage(), vim.api.nvim_tabpage_list_wins(0)
		local tabs = #vim.api.nvim_list_tabpages()
		ui(f.root)
		assert(vim.api.nvim_get_current_tabpage() ~= tab, "patch must leave the Compare tab")
		assert(#vim.api.nvim_list_tabpages() == tabs + 1)
		assert(vim.deep_equal(vim.api.nvim_tabpage_list_wins(tab), wins), "patch changed Compare windows")
		compare.close(s)
	end)
	case("regression_vertical_splits_current_plugin_window", function()
		local f = fixture()
		local sidebar = require("lazyvcs.source_control.native")
		local state = sidebar.open({ path = f.root })
		vim.api.nvim_set_current_win(state.winid)
		local tab, pos = vim.api.nvim_get_current_tabpage(), vim.fn.win_screenpos(state.winid)
		local height = vim.api.nvim_win_get_height(state.winid)
		require("lazyvcs.commands").setup()
		vim.cmd("vertical LazyVCS patch " .. vim.fn.fnameescape(f.root))
		local win = vim.api.nvim_get_current_win()
		assert(vim.api.nvim_get_current_tabpage() == tab)
		assert(vim.fn.win_screenpos(win)[1] == pos[1] and vim.api.nvim_win_get_height(win) == height)
		assert(vim.api.nvim_win_get_height(state.winid) == height)
		assert(vim.fn.win_screenpos(win)[2] ~= vim.fn.win_screenpos(state.winid)[2])
	end)
	case("regression_clears_inherited_window_options", function()
		local f = fixture()
		local origin = vim.api.nvim_get_current_win()
		local util = require("lazyvcs.util")
		local names = { "winbar", "statusline", "winfixwidth", "scrollbind", "cursorbind", "diff" }
		local original = util.capture_win_options(origin, names)
		local defaults = {}
		for _, name in ipairs(names) do
			defaults[name] = vim.api.nvim_get_option_value(name, { win = origin, scope = "global" })
		end
		-- :set and vim.wo set the defaults copied by :new as well as local values.
		for name, value in pairs({
			winbar = "COMPARE | WORKTREE",
			statusline = "LIVE DIFF",
			winfixwidth = true,
			scrollbind = true,
			cursorbind = true,
			diff = true,
		}) do
			vim.wo[origin][name] = value
		end
		local inherited
		vim.api.nvim_create_autocmd("FileType", {
			group = "lazyvcs_patch_tests",
			pattern = "diff",
			callback = function()
				if vim.api.nvim_buf_get_name(0):match("^lazyvcs://patch/") then
					inherited = util.capture_win_options(vim.api.nvim_get_current_win(), names)
				end
			end,
		})
		local ok, err = pcall(ui, f.root, { smods = { vertical = true } })
		util.diff_off(origin)
		for name, value in pairs(defaults) do
			vim.api.nvim_set_option_value(name, value, { win = origin, scope = "global" })
		end
		util.set_win_options(origin, original)
		assert(ok, err)
		assert(
			inherited and inherited.winbar == "" and inherited.statusline == "",
			"patch inherited a window label: " .. vim.inspect(inherited)
		)
		assert(
			not inherited.winfixwidth and not inherited.scrollbind and not inherited.cursorbind and not inherited.diff
		)
	end)
	case("regression_winbar_cleared_after_enew", function()
		local f = fixture()
		local buf = ui(f.root)
		local win = vim.api.nvim_get_current_win()
		contains(vim.wo[win].winbar, "PATCH |")
		-- Reproduce a winbar provider carrying its last render across BufWinEnter.
		local title = vim.wo[win].winbar
		vim.api.nvim_create_autocmd("BufWinEnter", {
			group = "lazyvcs_patch_tests",
			once = true,
			callback = function()
				require("lazyvcs.util").set_win_option(win, "winbar", title)
			end,
		})
		vim.cmd("enew")
		local cleared = vim.wait(1000, function()
			return vim.wo[win].winbar == ""
		end, 10)
		assert(cleared, "PATCH winbar survived :enew")
		assert(not vim.api.nvim_buf_is_valid(buf), "hidden patch buffer must be wiped")
	end)
	case("regression_git_repository_root_path", function()
		local f = fixture()
		assert(require("lazyvcs.util").relative_literal_path(f.root, f.root) == ".")
		contains(get(f.root), "+changed")
	end)
	case("regression_svn_repository_root_path", function()
		local f = h.make_svn_fixture()
		assert(require("lazyvcs.util").relative_literal_path(f.root, f.root) == ".")
		contains(get(f.root), "+changed")
	end)
	case("git_apply_check_at_head", function()
		local f = fixture()
		for _, name in ipairs({ "space é.txt", "-leading.txt", "empty.txt" }) do
			write(f.root .. "/" .. name, name == "empty.txt" and "" or "new\nlast")
		end
		local text = get(f.root)
		local parent = h.tempdir()
		h.exec({ "git", "clone", f.root, parent .. "/clone" }, parent)
		local out = parent .. "/patch.diff"
		write(out, text)
		h.exec({ "git", "apply", "--check", out }, parent .. "/clone")
	end)
	case("no_changes_and_no_callback_window", function()
		local f = fixture()
		write(f.file, "one\ntwo\nthree\n")
		local wins = #vim.api.nvim_list_wins()
		assert(get(f.root) == "")
		assert(#vim.api.nvim_list_wins() == wins)
		local _, rows = ui(f.root)
		assert(rows[1] == "No changes under " .. f.root)
	end)
	case("not_a_repository", function()
		local root = h.tempdir()
		local done, err
		require("lazyvcs").patch({
			path = root,
			on_done = function(text, failure)
				assert(text == nil)
				err, done = failure, true
			end,
		})
		wait(function()
			return done
		end)
		assert(err == "No Git or SVN working copy under " .. root)
		local notify, errors = vim.notify, {}
		vim.notify = function(message, level)
			errors[#errors + 1] = { message, level }
		end
		local ok, failure = pcall(function()
			local _, rows = ui(root)
			assert(rows[1] == err)
			assert(errors[#errors][2] == vim.log.levels.ERROR)
		end)
		vim.notify = notify
		assert(ok, failure)
	end)
	case("command_modifiers_completion_and_default_split", function()
		local f = fixture()
		vim.cmd.lcd(f.root)
		require("lazyvcs.commands").setup()
		local editor = vim.api.nvim_get_current_win()
		vim.cmd("LazyVCS patch")
		local win = vim.api.nvim_get_current_win()
		assert(vim.fn.win_screenpos(win)[1] < vim.fn.win_screenpos(editor)[1])
		vim.api.nvim_buf_delete(0, { force = true })
		local tabs = #vim.api.nvim_list_tabpages()
		vim.cmd("tab LazyVCS patch")
		assert(#vim.api.nvim_list_tabpages() == tabs + 1)
		vim.api.nvim_buf_delete(0, { force = true })
		vim.cmd("vertical LazyVCS patch")
		win = vim.api.nvim_get_current_win()
		assert(vim.api.nvim_win_get_width(win) < vim.o.columns)
		vim.api.nvim_buf_delete(0, { force = true })
		vim.fn.mkdir(f.root .. "/directory")
		write(f.root .. "/not-directory", "file\n")
		local completions = require("lazyvcs.commands")._complete("", "LazyVCS patch ")
		assert(vim.tbl_contains(completions, "directory/"))
		assert(not vim.tbl_contains(completions, "not-directory"))
	end)
	case("config_include_untracked_validation", function()
		local config = require("lazyvcs.config")
		config.setup({ patch = { include_untracked = false } })
		assert(config.get().patch.include_untracked == false)
		local f = fixture()
		write(f.root .. "/new.txt", "untracked\n")
		lacks(get(f.root), "new.txt")
		contains(get(f.root, { include_untracked = true }), "new.txt")
		assert(not pcall(config.setup, { patch = { include_untracked = "yes" } }))
		assert(not pcall(config.setup, { patch = false }))
	end)
	case("svn_modified_added_unversioned_and_dry_run", function()
		local f = h.make_svn_transfer_fixture()
		write(f.root .. "/binary", "a\0b")
		write(f.root .. "/no-eol.txt", "no newline")
		local text = get(f.root)
		contains(text, "Index: alpha.txt")
		contains(text, "Index: added.txt")
		contains(text, "Index: scratch.txt")
		contains(text, "Index: binary")
		contains(text, "Cannot display: file marked as a binary type.")
		contains(text, "\\ No newline at end of file")
		lacks(get(f.root, { include_untracked = false }), "Index: scratch.txt")
		local parent = h.tempdir()
		h.exec({
			"svn",
			"checkout",
			vim.trim(h.exec({ "svn", "info", "--show-item", "url" }, f.root)),
			parent .. "/pristine",
		}, parent)
		local out = parent .. "/patch.diff"
		write(out, text)
		local output = h.exec({ "svn", "patch", "--dry-run", out }, parent .. "/pristine")
		lacks(output, "C         ")
		contains(output, "scratch.txt")
	end)
	case("svn_subdirectory_cwd_and_unversioned_tree_ignores", function()
		local f = h.make_svn_transfer_fixture()
		vim.fn.mkdir(f.root .. "/sub")
		write(f.root .. "/sub/tracked", "old\n")
		h.exec({ "svn", "add", "sub" }, f.root)
		h.exec({ "svn", "commit", "-m", "add subtree fixture" }, f.root)
		write(f.root .. "/sub/tracked", "new\n")
		vim.fn.mkdir(f.root .. "/sub/unversioned")
		write(f.root .. "/sub/unversioned/child", "child\n")
		write(f.root .. "/sub/unversioned/ignored.o", "ignore\n")
		vim.cmd.lcd(f.root .. "/sub")
		local done, text, err
		require("lazyvcs").patch({
			on_done = function(t, e)
				text, err, done = t, e, true
			end,
		})
		wait(function()
			return done
		end)
		assert(not err, err)
		contains(text, "Index: sub/tracked")
		contains(text, "Index: sub/unversioned/child")
		lacks(text, "ignored.o")
		lacks(text, "Index: alpha.txt")
	end)
	case("relative_lua_path_and_command_literal_completion", function()
		local f = fixture()
		vim.fn.mkdir(f.root .. "/literal $PATCH_UNSET é")
		write(f.root .. "/literal $PATCH_UNSET é/-new", "literal\n")
		vim.cmd.lcd(f.root)
		contains(get("literal $PATCH_UNSET é"), "+literal")
		local lead = "literal"
		local choices = require("lazyvcs.commands")._complete(lead, "vertical LazyVCS patch " .. lead)
		assert(#choices == 1)
		require("lazyvcs.commands").setup()
		vim.cmd("LazyVCS patch " .. choices[1])
		wait(function()
			return not vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("Loading patch", 1, true)
		end)
		contains(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"), "+literal")
	end)
	case("git_quoted_filename_navigation_and_apply", function()
		if vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "Control and backslash filenames are POSIX only" })
		end
		local f = fixture()
		local name = 'tab\tquote"slash\\123.txt'
		write(f.root .. "/" .. name, "quoted\n")
		local text = get(f.root)
		local parent = h.tempdir()
		h.exec({ "git", "clone", f.root, parent .. "/clone" }, parent)
		write(parent .. "/patch.diff", text)
		h.exec({ "git", "apply", "--check", parent .. "/patch.diff" }, parent .. "/clone")
		local _, rows = ui(f.root)
		for i, line in ipairs(rows) do
			if line == "+quoted" then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				break
			end
		end
		keys("gf")
		assert(vim.api.nvim_buf_get_name(0) == f.root .. "/" .. name)
	end)
	case("reload_preserves_file_and_hunk_position", function()
		local f = fixture()
		local buf, rows = ui(f.root)
		for i, line in ipairs(rows) do
			if line == "+changed" then
				vim.api.nvim_win_set_cursor(0, { i, 0 })
				break
			end
		end
		write(f.file, "one\nchanged again\nthree\n")
		keys("R")
		wait(function()
			return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("+changed again", 1, true)
				~= nil
		end)
		local row = vim.api.nvim_win_get_cursor(0)[1]
		assert(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] == "+changed again")
	end)
	case("process_overflow_uses_only_patch_marker", function()
		local f = fixture()
		write(f.file, string.rep("large line\n", 3000))
		patch._test_output_limit = 128
		local text = get(f.root)
		contains(text, "# lazyvcs: output truncated at 16 MiB\n")
		lacks(text, "truncated at least")
		lacks(text, "... [truncated")
	end)
	case("svn_empty_unversioned_and_output_cap", function()
		local f = h.make_svn_fixture()
		write(f.root .. "/empty", "")
		write(f.root .. "/large", string.rep("large\n", 4000))
		contains(get(f.root), "Index: empty")
		patch._test_output_limit = 700
		local text = get(f.root)
		contains(text, "# lazyvcs: output truncated at 16 MiB\n")
		assert(#text <= 700 + 1 + #"# lazyvcs: output truncated at 16 MiB\n")
	end)
	case("sidebar_repository_action_opens_patch", function()
		local f = fixture()
		local picker = require("lazyvcs.picker")
		local select = picker.select
		local opened, options
		local public = require("lazyvcs")
		local open = public.patch
		---@diagnostic disable-next-line: duplicate-set-field
		picker.select = function(items, _, done)
			for _, item in ipairs(items) do
				if item.label == "Show patch" then
					opened = true
					done(item)
					return
				end
			end
		end
		public.patch = function(opts)
			options = opts
		end
		local ok, err = pcall(function()
			local sidebar = require("lazyvcs.source_control.native")
			-- Use the same real sidebar state and picker route as the '.' action.
			local state = sidebar.open({ path = f.root })
			wait(function()
				return state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[f.root] and not state.lazyvcs_discovering
			end)
			require("lazyvcs.source_control.ops").repo_action_picker(
				state,
				{ type = "repo", extra = { repo_root = f.root } }
			)
		end)
		picker.select, public.patch = select, open
		local sidebar = require("lazyvcs.source_control.native")
		pcall(sidebar.close)
		assert(ok, err)
		assert(opened and options.path == f.root)
	end)

	return cases
end
