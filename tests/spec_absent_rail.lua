return function(ctx)
	local api, h = vim.api, ctx.helpers
	local compare = require("lazyvcs.compare")
	local actions = require("lazyvcs.actions")
	local layout = require("lazyvcs.layout")
	local util = require("lazyvcs.util")
	local cases = {}
	local function keys(value)
		api.nvim_feedkeys(api.nvim_replace_termcodes(value, true, false, true), "xt", false)
	end
	local function settle()
		vim.wait(80, function()
			return false
		end, 10)
	end
	local function add(name, fn)
		cases[#cases + 1] = {
			"test_" .. name,
			function()
				local saved = {
					columns = vim.o.columns,
					lines = vim.o.lines,
					winminwidth = vim.o.winminwidth,
					winminheight = vim.o.winminheight,
					winwidth = vim.o.winwidth,
					winheight = vim.o.winheight,
				}
				vim.o.columns, vim.o.lines = 180, 42
				vim.o.winminwidth, vim.o.winminheight = 1, 1
				vim.wo.signcolumn = "yes:1"
				vim.wo.number = true
				vim.wo.relativenumber = true
				vim.wo.foldcolumn = "2"
				vim.wo.statuscolumn = "%l"
				vim.wo.winfixwidth = false
				vim.wo.winfixheight = false
				require("lazyvcs").setup({ signs = { enabled = false }, blame = { persist = false }, debounce_ms = 10 })
				require("lazyvcs.commands").setup()
				local ok, err = xpcall(fn, debug.traceback)
				local current = compare.current()
				if current then
					compare.close(current)
				end
				for _, s in ipairs(require("lazyvcs.state").list()) do
					actions.close(s)
				end
				vim.o.winminwidth, vim.o.winminheight = 1, 1
				for name, value in pairs(saved) do
					vim.o[name] = value
				end
				assert(ok, err)
			end,
		}
	end
	local function fixture(vcs)
		local f = vcs == "svn" and h.make_svn_fixture() or h.make_git_fixture()
		h.write_file(f.root .. "/deleted.txt", "deleted before\nremoved line\n")
		h.exec(vcs == "svn" and { "svn", "add", "deleted.txt" } or { "git", "add", "deleted.txt" }, f.root)
		h.exec({ vcs, "commit", "-m", "deletion base" }, f.root)
		if vcs == "svn" then
			h.exec({ "svn", "update" }, f.root)
		end
		for _, path in ipairs({ "added.txt", "other.txt", "untracked.txt" }) do
			h.write_file(f.root .. "/" .. path, "new\ncontent\n")
		end
		h.exec({ vcs, "add", "added.txt", "other.txt" }, f.root)
		h.exec(vcs == "svn" and { "svn", "delete", "deleted.txt" } or { "git", "rm", "deleted.txt" }, f.root)
		f.base = vcs == "svn" and h.file_url(f.repo) .. "@2" or "HEAD"
		return f
	end
	local function ready(s, path)
		ctx.wait_for(function()
			return s.mode == "text" and s.preview_result and (not path or s.shown_item.relpath == path)
		end, "rail preview", 15000)
		settle()
	end
	local function select(s, path)
		api.nvim_set_current_win(s.sidewin)
		api.nvim_win_set_cursor(s.sidewin, { assert(s.row_by_path[path]), 0 })
		keys("<CR>")
		ready(s, path)
	end
	local function open(f, path)
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local s = assert(compare.open({ path = f.root, base = f.base, editable = false }))
		ready(s)
		select(s, path or "added.txt")
		return s
	end
	local option_names =
		{ "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "winfixwidth", "winfixheight" }
	local function options(win)
		return util.capture_win_options(win, option_names)
	end
	local function equal(s)
		assert(not s.rail, "unexpected rail")
		local get = s.stacked and function(win)
			return vim.fn.getwininfo(win)[1].height
		end or api.nvim_win_get_width
		assert(math.abs(get(s.leftwin) - get(s.rightwin)) <= 1, vim.inspect({ get(s.leftwin), get(s.rightwin) }))
	end
	local function collapsed(s, side)
		local win = side == "left" and s.leftwin or s.rightwin
		local present = side == "left" and s.rightwin or s.leftwin
		assert(s.rail and s.rail.win == win, "rail missing: " .. vim.inspect({
			path = s.shown_item.relpath,
			expanded = s.rail_expanded,
			presence = s.presence,
			left = s.leftwin,
			right = s.rightwin,
			focus = api.nvim_get_current_win(),
			widths = { api.nvim_win_get_width(s.leftwin), api.nvim_win_get_width(s.rightwin) },
			stacked = s.stacked,
			config = require("lazyvcs.config").get().compare,
		}))
		local get = s.stacked and function(win)
			return vim.fn.getwininfo(win)[1].height
		end or api.nvim_win_get_width
		local size = math.max(s.stacked and 1 or 3, s.stacked and vim.o.winminheight or vim.o.winminwidth)
		assert(get(win) == size, vim.inspect({ size = get(win), expected = size }))
		assert(get(present) > get(win))
		assert(vim.wo[win][s.stacked and "winfixheight" or "winfixwidth"])
		assert(not vim.wo[win].number and not vim.wo[win].relativenumber)
		assert(vim.wo[win].signcolumn == "no" and vim.wo[win].foldcolumn == "0" and vim.wo[win].statuscolumn == "")
		assert(
			vim.wo[win].diff and vim.wo[present].diff,
			vim.inspect({
				diff = vim.wo[win].diff,
				present = vim.wo[present].diff,
				mode = s.mode,
				buffer = api.nvim_win_get_buf(win),
			})
		)
	end
	for _, kind in ipairs({ "added", "deleted", "modified" }) do
		add("core_absent_rail_git_" .. kind, function()
			local f = fixture("git")
			local s = open(f, kind == "modified" and "sample.txt" or kind .. ".txt")
			if kind == "modified" then
				equal(s)
				select(s, "added.txt")
				collapsed(s, "left")
			else
				collapsed(s, kind == "added" and "left" or "right")
				if kind == "added" then
					assert(
						api.nvim_win_get_width(s.rightwin)
							== vim.o.columns
								- api.nvim_win_get_width(s.sidewin)
								- 2
								- math.max(3, vim.o.winminwidth)
					)
				end
			end
			if kind == "deleted" then
				assert(api.nvim_get_current_win() == s.leftwin)
			end
		end)
	end
	add("core_absent_rail_cycle_and_restore_columns", function()
		local s = open(fixture("git"))
		collapsed(s, "left")
		local before_left = vim.deepcopy(s.rail.before)
		local ids = { s.leftwin, s.rightwin }
		keys("]b")
		ready(s, "deleted.txt")
		collapsed(s, "right")
		for name, value in pairs(before_left) do
			assert(util.get_win_option(s.leftwin, name) == value, name)
		end
		keys("]b")
		ready(s, "other.txt")
		collapsed(s, "left")
		keys("]b")
		ready(s, "sample.txt")
		equal(s)
		assert(not vim.wo[s.leftwin].winfixwidth and not vim.wo[s.rightwin].winfixwidth)
		assert(vim.wo[s.leftwin].signcolumn ~= "no" and vim.wo[s.rightwin].signcolumn ~= "no")
		keys("[b[b[b")
		ready(s, "added.txt")
		collapsed(s, "left")
		assert(ids[1] == s.leftwin and ids[2] == s.rightwin)
	end)
	add("core_absent_rail_focus_refresh_and_new_file", function()
		local s = open(fixture("git"))
		collapsed(s, "left")
		keys("<C-w>h")
		settle()
		equal(s)
		assert(s.rail_expanded)
		api.nvim_set_current_win(s.rightwin)
		compare.refresh(s)
		ready(s, "added.txt")
		equal(s)
		api.nvim_exec_autocmds("VimResized", {})
		settle()
		equal(s)
		select(s, "other.txt")
		collapsed(s, "left")
	end)
	add("core_absent_rail_internal_calls_and_picker_preview", function()
		local f = fixture("git")
		local s = open(f)
		collapsed(s, "left")
		api.nvim_win_call(s.leftwin, function()
			assert(api.nvim_get_current_win() == s.leftwin)
		end)
		settle()
		collapsed(s, "left")
		assert(not s.rail_expanded)
		-- A picker borrows the absent pane without moving the user's focus there.
		local borrowed = api.nvim_create_buf(false, true)
		vim.bo[s.left].bufhidden = "hide"
		api.nvim_win_call(s.leftwin, function()
			util.show_win_buffer(s.leftwin, borrowed)
		end)
		settle()
		assert(not s.rail_expanded)
		api.nvim_win_call(s.leftwin, function()
			util.show_win_buffer(s.leftwin, s.left)
		end)
		settle()
		collapsed(s, "left")
		assert(not s.rail_expanded)
		require("lazyvcs.absent_rail").internal(function()
			api.nvim_set_current_win(s.leftwin)
		end)
		settle()
		assert(not s.rail_expanded)
		api.nvim_set_current_win(s.rightwin)
		settle()
		collapsed(s, "left")
	end)
	add("core_absent_rail_resize_and_sidebar_width_controls", function()
		local s = open(fixture("git"))
		collapsed(s, "left")
		local initial = api.nvim_win_get_width(s.sidewin)
		vim.o.columns = 200
		api.nvim_exec_autocmds("VimResized", {})
		settle()
		collapsed(s, "left")
		api.nvim_set_current_win(s.sidewin)
		keys("e")
		settle()
		assert(s.auto_width)
		collapsed(s, "left")
		vim.cmd("LazyVCS compare width")
		settle()
		assert(not s.auto_width and api.nvim_win_get_width(s.sidewin) == initial)
		collapsed(s, "left")
	end)
	add("core_absent_rail_stacked_height_and_focus", function()
		vim.o.columns = 80
		local s = open(fixture("git"))
		assert(s.stacked)
		collapsed(s, "left")
		api.nvim_exec_autocmds("VimResized", {})
		settle()
		collapsed(s, "left")
		api.nvim_set_current_win(s.leftwin)
		settle()
		equal(s)
		assert(not vim.wo[s.leftwin].winfixheight)
	end)
	add("core_absent_rail_no_gain_constraints", function()
		local s = open(fixture("git"))
		collapsed(s, "left")
		-- Layout cannot stack when minimum text heights already fill the screen.
		vim.o.winheight = 18
		vim.o.winminheight = 18
		vim.o.winwidth = 59
		vim.o.winminwidth = 59
		api.nvim_exec_autocmds("VimResized", {})
		settle()
		equal(s)
	end)
	add("core_absent_rail_disabled", function()
		local f = fixture("git")
		local enabled = open(f)
		collapsed(enabled, "left")
		compare.close(enabled)
		require("lazyvcs.config").setup({ compare = { collapse_absent = false } })
		local s = open(f)
		equal(s)
		assert(vim.wo[s.leftwin].fillchars:find("diff:", 1, true))
	end)
	add("core_absent_rail_nontext_and_unknown_are_ineligible", function()
		local s = open(fixture("git"))
		collapsed(s, "left")
		api.nvim_set_current_win(s.sidewin)
		compare.action("metadata")
		settle()
		assert(s.mode == "metadata")
		equal(s)
		compare.action("metadata")
		ready(s)
		collapsed(s, "left")
		s.presence.left = "unknown"
		api.nvim_exec_autocmds("VimResized", {})
		settle()
		equal(s)
	end)
	add("core_absent_rail_close_restores_owned_options", function()
		local s = open(fixture("git"))
		collapsed(s, "left")
		local win, before = s.leftwin, vim.deepcopy(s.rail.before)
		local checked = false
		api.nvim_create_autocmd("WinClosed", {
			once = true,
			pattern = tostring(win),
			callback = function()
				for name, value in pairs(before) do
					assert(util.get_win_option(win, name) == value, name)
				end
				checked = true
			end,
		})
		compare.close(s)
		assert(checked)
	end)

	add("core_absent_rail_base_change_resets_expansion", function()
		local f = fixture("git")
		local s = open(f)
		collapsed(s, "left")
		api.nvim_set_current_win(s.leftwin)
		settle()
		equal(s)
		api.nvim_set_current_win(s.rightwin)
		assert(compare.open({ path = f.root, base = "HEAD~0" }) == s)
		ready(s, "added.txt")
		collapsed(s, "left")
	end)
	add("core_absent_rail_config_validation_and_known_options", function()
		local s = open(fixture("git"))
		collapsed(s, "left")
		local config = require("lazyvcs.config")
		for _, key in ipairs({ "compare", "base_window" }) do
			local ok, err = pcall(config.setup, { [key] = { collapse_absent = "yes" } })
			assert(not ok and tostring(err):find(key .. ".collapse_absent", 1, true))
		end
		local original = vim.notify_once
		local warnings = {}
		---@diagnostic disable-next-line: duplicate-set-field
		vim.notify_once = function(message)
			warnings[#warnings + 1] = message
		end
		local ok, err =
			pcall(config.setup, { compare = { collapse_absent = false }, base_window = { collapse_absent = false } })
		vim.notify_once = original
		assert(ok, err)
		assert(#warnings == 0, vim.inspect(warnings))
	end)

	local function live(f, path)
		path = path or "untracked.txt"
		vim.cmd.edit(vim.fn.fnameescape(f.root .. "/" .. path))
		local s
		if f.repo and path == "untracked.txt" then
			local comparison, done
			require("lazyvcs.backends").load_diff_target_async(
				{ vcs = "svn", root = f.root, relpath = path, section = "untracked" },
				function(result)
					comparison, done = result, true
				end
			)
			ctx.wait_for(function()
				return done
			end, "unversioned target", 15000)
			s = assert(actions.open_target(assert(comparison)))
		else
			s = ctx.open_diff()
		end
		settle()
		return s
	end

	local function live_rail(s)
		assert(s.rail and s.rail.win == s.base_win, "live rail missing")
		assert(api.nvim_win_get_width(s.base_win) == math.max(3, vim.o.winminwidth))
	end
	add("live_diff_absent_rail_sidebar_untracked_and_focus", function()
		local f = fixture("git")
		-- Use the sidebar's diff target entry point and the real destination window.
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local comparison, done
		require("lazyvcs.backends").load_diff_target_async({
			vcs = "git",
			root = f.root,
			relpath = "untracked.txt",
			path = f.root .. "/untracked.txt",
			section = "untracked",
			change_kind = "untracked",
		}, function(result)
			comparison, done = result, true
		end)
		ctx.wait_for(function()
			return done
		end, "sidebar target", 15000)
		local s = assert(actions.open_target(assert(comparison)))
		settle()
		live_rail(s)
		api.nvim_win_call(s.base_win, function() end)
		settle()
		live_rail(s)
		s.opts.base_window.width = 45
		api.nvim_set_current_win(s.base_win)
		settle()
		assert(not s.rail and s.rail_expanded)
		assert(api.nvim_win_get_width(s.base_win) == 45)
		api.nvim_set_current_win(s.editable_win)
		actions.refresh_current()
		settle()
		api.nvim_exec_autocmds("VimResized", {})
		settle()
		assert(not s.rail and api.nvim_win_get_width(s.base_win) == 45)
	end)
	add("live_diff_absent_rail_transfer_restores_width", function()
		local f = fixture("git")
		require("lazyvcs.config").get().base_window.width = 44
		local s = live(f)
		live_rail(s)
		local win = s.editable_win
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local next_s
		ctx.wait_for(function()
			next_s = require("lazyvcs.state").for_window(win)
			return next_s and next_s ~= s and next_s.phase == "active"
		end, "rail transfer", 15000)
		settle()
		assert(not next_s.rail and api.nvim_win_get_width(next_s.base_win) == 44)
		assert(vim.wo[next_s.base_win].signcolumn ~= "no")
	end)
	add("live_diff_absent_rail_pause_expands_and_restores_columns", function()
		local f = fixture("git")
		require("lazyvcs.config").get().base_window.width = 44
		local s = live(f)
		live_rail(s)
		local win = s.editable_win
		local outside = h.tempdir() .. "/outside.txt"
		h.write_file(outside, "outside\n")
		vim.cmd.edit(vim.fn.fnameescape(outside))
		local paused
		ctx.wait_for(function()
			paused = require("lazyvcs.state").for_window(win)
			return paused and paused.paused
		end, "paused rail", 15000)
		settle()
		assert(not paused.rail and api.nvim_win_get_width(paused.base_win) == 44)
		assert(vim.wo[paused.base_win].signcolumn == "yes:1")
	end)

	add("live_diff_absent_rail_unsupported_text_expands", function()
		local f = fixture("git")
		require("lazyvcs.config").get().base_window.width = 44
		local s = live(f)
		live_rail(s)
		api.nvim_buf_set_lines(s.editable_bufnr, 0, -1, false, { string.rep("x", 1024 * 1024 + 1) })
		ctx.wait_for(function()
			return s.capture_error
		end, "oversized live rail", 15000)
		assert(not s.rail and api.nvim_win_get_width(s.base_win) == 44)
	end)

	add("live_diff_absent_rail_readonly_text_and_nontext", function()
		local f = fixture("git")
		local comparison = {
			backend = "git",
			vcs = "git",
			root = f.root,
			relpath = "snapshot.txt",
			kind = "git_unstaged",
			presence = { left = "absent", right = "present" },
			left = { label = "INDEX", lines = {}, modifiable = false },
			right = { label = "WORKTREE", lines = { "text snapshot" }, modifiable = false },
		}
		local s = assert(actions.open_target(comparison))
		settle()
		live_rail(s)
		actions.close(s)
		comparison.presence = { left = "present", right = "absent" }
		comparison.left.lines = { "deleted text" }
		comparison.right.lines = {}
		s = assert(actions.open_target(comparison))
		settle()
		assert(s.rail and s.rail.win == s.editable_win)
		assert(api.nvim_win_get_width(s.editable_win) == math.max(3, vim.o.winminwidth))
		assert(api.nvim_get_current_win() == s.base_win)
		actions.close(s)
		comparison.presence = { left = "absent", right = "present" }
		comparison.left.lines = {}
		for _, lines in ipairs({ { "binary\0content" }, { string.rep("x", 1024 * 1024 + 1) } }) do
			comparison.right.lines = lines
			s = assert(actions.open_target(comparison))
			settle()
			assert(not s.rail and not s.rail_text)
			actions.close(s)
		end
		comparison.right.lines = { "Property patch" }
		comparison.property_only = true
		s = assert(actions.open_target(comparison))
		settle()
		assert(not s.rail)
	end)

	add("live_diff_absent_rail_disabled", function()
		local f = fixture("git")
		local enabled = live(f)
		live_rail(enabled)
		actions.close(enabled)
		require("lazyvcs.config").get().base_window.collapse_absent = false
		require("lazyvcs.config").get().base_window.width = 43
		local s = live(f)
		assert(not s.rail and api.nvim_win_get_width(s.base_win) == 43)
	end)
	add("live_diff_absent_rail_save_projects_and_close_restores", function()
		local f = fixture("git")
		vim.cmd.edit(vim.fn.fnameescape(f.root .. "/untracked.txt"))
		vim.wo.number = true
		vim.wo.relativenumber = true
		vim.wo.signcolumn = "yes:2"
		vim.wo.foldcolumn = "2"
		vim.wo.statuscolumn = "%l"
		vim.wo.winfixwidth = false
		local win = api.nvim_get_current_win()
		local original = options(win)
		local s = ctx.open_diff()
		settle()
		live_rail(s)
		local rail_options = options(s.base_win)
		local transaction = {}
		layout.prepare_sessions_save({ s }, transaction)
		for name, value in pairs(original) do
			assert(util.get_win_option(win, name) == value, name)
			assert(util.get_win_option(s.base_win, name) == s.base_window_options[name], "base " .. name)
		end
		layout.finish_sessions_save(transaction)
		assert(vim.deep_equal(options(s.base_win), rail_options))
		actions.close(s)
		assert(vim.deep_equal(options(win), original))
	end)
	for _, status in ipairs({ "added", "untracked", "deleted" }) do
		add("core_absent_rail_svn_" .. status, function()
			local s = open(fixture("svn"), status .. ".txt")
			collapsed(s, status == "deleted" and "right" or "left")
		end)
	end
	for _, status in ipairs({ "added", "untracked" }) do
		add("svn_live_absent_rail_" .. status, function()
			local s = live(fixture("svn"), status .. ".txt")
			live_rail(s)
			api.nvim_set_current_win(s.base_win)
			settle()
			assert(not s.rail and s.rail_expanded)
		end)
	end
	return cases
end
