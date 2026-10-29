return function(ctx)
	local api, h = vim.api, ctx.helpers
	local guard = require("lazyvcs.highlighting")
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = { "test_" .. name, fn }
	end
	local function setup(opts)
		require("lazyvcs").setup(vim.tbl_deep_extend("force", {
			signs = { enabled = false },
			blame = { persist = false },
			debounce_ms = 10,
			compare = { collapse_absent = false },
			base_window = { collapse_absent = false },
		}, opts or {}))
	end
	local function raw(win)
		return api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
	end
	local function window()
		vim.cmd.tabnew()
		local win = api.nvim_get_current_win()
		api.nvim_win_set_hl_ns(win, -1)
		vim.wo.winhighlight = ""
		api.nvim_set_option_value("fillchars", "", { win = win, scope = "local" })
		return win
	end
	local function mapping(win, name, target)
		assert(vim.wo[win].winhighlight:find(name .. ":" .. target, 1, true), vim.wo[win].winhighlight)
	end
	local function await(fn)
		local done, result, failure
		fn(function(value, err)
			done, result, failure = true, value, err
		end)
		ctx.wait_for(function()
			return done
		end, "diff style backend", 15000)
		return assert(result, failure)
	end
	local function attributes(ns, name)
		local value = api.nvim_get_hl(ns, { name = name, link = false })
		value.default = nil
		return value
	end
	local function empty_file(path)
		local f = assert(io.open(path, "wb"))
		f:close()
	end
	local function open_live(file)
		vim.cmd.edit(vim.fn.fnameescape(file))
		return ctx.open_diff()
	end
	local function close_live(s)
		require("lazyvcs.actions").close(s)
	end
	local function hatch(win)
		vim.cmd.redraw()
		local pos = vim.fn.win_screenpos(win)
		for row = pos[1], pos[1] + api.nvim_win_get_height(win) - 1 do
			for col = pos[2], pos[2] + api.nvim_win_get_width(win) - 1 do
				if vim.fn.screenchar(row, col) == vim.fn.char2nr("╱") then
					return api.nvim__inspect_cell(1, row - 1, col - 1)[2]
				end
			end
		end
		error("no rendered hatch in diff pane")
	end
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result or s.message == "Comparison unavailable"
		end, "diff style compare", 15000)
		assert(s.preview_result, s.message)
	end
	local function compare_path(f, path)
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local compare = require("lazyvcs.compare")
		local s = assert(compare.open({ path = f.root, base = f.base or "HEAD", editable = false }))
		ready(s)
		if s.shown_item.relpath ~= path then
			api.nvim_set_current_win(s.sidewin)
			api.nvim_win_set_cursor(s.sidewin, { assert(s.row_by_path[path]), 0 })
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
			ctx.wait_for(function()
				return s.shown_item and s.shown_item.relpath == path and s.mode == "text"
			end, "selected diff style path", 15000)
		end
		return s
	end
	add("core_diff_style_fillchars_inheritance_and_user_edits", function()
		setup()
		local win = window()
		local global = api.nvim_get_option_value("fillchars", { scope = "global" })
		api.nvim_set_option_value("fillchars", "eob:~", { scope = "global" })
		guard.apply(win, "editor", "old")
		assert(raw(win) == "eob:~,diff:╱", raw(win))
		assert(api.nvim_get_option_value("fillchars", { scope = "global" }) == "eob:~")
		mapping(win, "DiffDelete", "LazyVcsDiffFiller")
		mapping(win, "DiffAdd", "LazyVcsDiffRemoved")
		guard.release(win)
		assert(raw(win) == "")
		vim.wo[win].fillchars = "eob:!,diff:x"
		guard.apply(win, "syntax", "old")
		assert(raw(win) == "eob:!,diff:x")
		guard.release(win)
		vim.wo[win].fillchars = "eob:!"
		guard.apply(win, "syntax", "new")
		assert(raw(win) == "eob:!,diff:╱")
		vim.wo[win].fillchars = "eob:?,diff:z"
		guard.release(win)
		assert(raw(win) == "eob:?,diff:z")
		vim.wo[win].fillchars = "eob:,,vert:|"
		guard.apply(win, "editor", "new")
		assert(raw(win) == "eob:,,vert:|,diff:╱", raw(win))
		guard.release(win)
		api.nvim_set_option_value("fillchars", global, { scope = "global" })
		vim.cmd.tabclose()
	end)
	add("core_diff_style_ambiwidth_fallback", function()
		setup()
		local win = window()
		local global, width = vim.go.fillchars, vim.o.ambiwidth
		vim.go.fillchars = "eob:~"
		vim.o.ambiwidth = "double"
		guard.apply(win, "editor", "new")
		assert(raw(win) == "eob:~,diff:/", raw(win))
		guard.release(win)
		assert(raw(win) == "")
		vim.o.ambiwidth, vim.go.fillchars = width, global
		vim.cmd.tabclose()
	end)
	add("core_diff_style_config_and_directional_colors", function()
		for _, filler in ipairs({ false, 12, "", "ab", "界", "\n" }) do
			local ok, err = pcall(require("lazyvcs.config").setup, { diff_style = { filler = filler } })
			assert(not ok and tostring(err):find("diff_style.filler", 1, true))
		end
		setup({ diff_style = { filler = "/", removed = false } })
		local win = window()
		vim.wo[win].fillchars = "eob:!,diff:x"
		guard.apply(win, "editor", "old")
		assert(raw(win) == "eob:!,diff:/", raw(win))
		mapping(win, "DiffDelete", "LazyVcsDiffFiller")
		assert(not vim.wo[win].winhighlight:find("DiffAdd:", 1, true))
		guard.release(win)
		assert(raw(win) == "eob:!,diff:x")
		vim.wo[win].fillchars = ""
		setup({ diff_style = { enabled = false } })
		guard.apply(win, "syntax", "old")
		assert(raw(win) == "")
		assert(not vim.wo[win].winhighlight:find("DiffDelete:", 1, true))
		guard.release(win)
		vim.cmd.tabclose()
	end)
	add("core_diff_style_overrides_and_colorscheme", function()
		setup()
		local win = window()
		vim.cmd.colorscheme("default")
		api.nvim_set_hl(0, "LazyVcsDiffFiller", { fg = "#123456" })
		vim.wo[win].winhighlight = "DiffDelete:ErrorMsg,DiffAdd:WarningMsg"
		guard.apply(win, "syntax", "old")
		mapping(win, "DiffDelete", "ErrorMsg")
		mapping(win, "DiffAdd", "WarningMsg")
		assert(attributes(0, "LazyVcsDiffFiller").fg == 0x123456)
		local delete = api.nvim_get_hl(0, { name = "DiffDelete" })
		api.nvim_set_hl(
			0,
			"DiffDelete",
			{ fg = "#987654", bg = "#112233", ctermfg = 4, ctermbg = 5, cterm = { bold = true } }
		)
		api.nvim_exec_autocmds("ColorScheme", {})
		vim.wait(30)
		assert(
			vim.deep_equal(attributes(0, "LazyVcsDiffRemoved"), attributes(0, "DiffDelete")),
			vim.inspect({ removed = attributes(0, "LazyVcsDiffRemoved"), expected = attributes(0, "DiffDelete") })
		)
		assert(attributes(0, "LazyVcsDiffFiller").fg == 0x123456)
		guard.release(win)
		for _, target in ipairs({ "LazyVcsDiffRemoved", "LazyVcsDiffFiller" }) do
			vim.wo[win].winhighlight = "DiffDelete:" .. target
			guard.apply(win, "syntax", "old")
			mapping(win, "DiffDelete", target)
			guard.release(win)
			mapping(win, "DiffDelete", target)
		end
		---@diagnostic disable-next-line: param-type-mismatch
		api.nvim_set_hl(0, "DiffDelete", delete)
		api.nvim_set_hl(0, "LazyVcsDiffFiller", {})
		api.nvim_exec_autocmds("ColorScheme", {})
		vim.cmd.tabclose()
	end)
	add("core_diff_style_pooled_namespace_and_user_mapping", function()
		setup()
		local win = window()
		local ns = api.nvim_create_namespace("diff-style-test-theme")
		api.nvim_set_hl(ns, "DiffDelete", { fg = "#aabbcc", bg = "#112233", ctermfg = 6 })
		api.nvim_set_hl(ns, "DiffChange", { bg = "#334455" })
		api.nvim_win_set_hl_ns(win, ns)
		guard.apply(win, "editor", "old")
		local applied = api.nvim_get_hl_ns({ winid = win })
		assert(applied ~= ns)
		assert(
			vim.deep_equal(
				api.nvim_get_hl(applied, { name = "DiffAdd", link = false }),
				api.nvim_get_hl(ns, { name = "DiffDelete", link = false })
			)
		)
		assert(
			vim.deep_equal(
				api.nvim_get_hl(applied, { name = "DiffDelete", link = false }),
				attributes(0, "LazyVcsDiffFiller")
			)
		)
		assert(
			vim.deep_equal(
				api.nvim_get_hl(applied, { name = "DiffChange", link = false }),
				api.nvim_get_hl(ns, { name = "DiffChange", link = false })
			)
		)
		guard.release(win)
		assert(api.nvim_get_hl_ns({ winid = win }) == ns)
		api.nvim_set_hl(ns, "LazyVcsDiffRemoved", { fg = "#abcdef" })
		guard.apply(win, "editor", "old")
		applied = api.nvim_get_hl_ns({ winid = win })
		assert(api.nvim_get_hl(applied, { name = "DiffAdd", link = false }).fg == 0xabcdef)
		guard.release(win)
		vim.wo[win].winhighlight = "DiffDelete:ErrorMsg,DiffAdd:WarningMsg"
		guard.apply(win, "editor", "new")
		applied = api.nvim_get_hl_ns({ winid = win })
		assert(
			vim.deep_equal(
				api.nvim_get_hl(applied, { name = "DiffDelete", link = false }),
				api.nvim_get_hl(0, { name = "ErrorMsg", link = false })
			)
		)
		assert(
			vim.deep_equal(api.nvim_get_hl(applied, { name = "DiffAdd", link = false }), attributes(0, "WarningMsg"))
		)
		guard.release(win)
		vim.cmd.tabclose()
	end)
	for _, status in ipairs({ "A", "?", "D", "M" }) do
		add(
			"core_diff_style_compare_git_"
				.. ({ A = "added", ["?"] = "untracked", D = "deleted", M = "modified" })[status],
			function()
				setup()
				local f = h.make_git_fixture()
				local path = (status == "M" or status == "D") and "sample.txt" or "added.txt"
				if status == "M" then
					path = "sample.txt"
				end
				if status == "A" or status == "?" then
					h.write_file(f.root .. "/" .. path, "alpha\nbeta\ngamma\n")
					if status == "A" then
						h.exec({ "git", "add", path }, f.root)
					end
				elseif status == "D" then
					h.exec({ "git", "rm", "-f", path }, f.root)
				end
				local s = compare_path(f, path)
				mapping(s.leftwin, "DiffDelete", "LazyVcsDiffFiller")
				mapping(s.leftwin, "DiffAdd", "LazyVcsDiffRemoved")
				mapping(s.rightwin, "DiffDelete", "LazyVcsDiffFiller")
				assert(not vim.wo[s.rightwin].winhighlight:find("DiffAdd:", 1, true))
				assert(not vim.wo[s.leftwin].winhighlight:find("DiffChange:", 1, true))
				assert(raw(s.leftwin):find("diff:╱", 1, true))
				if status == "A" or status == "?" then
					assert(s.presence.left == "absent" and s.presence.right == "present")
					assert(s.left_label:find("No file at HEAD @", 1, true))
					assert(s.right_label:find("Added (no file at HEAD @", 1, true))
					assert(#s.navigation.base == 1)
					local cell = hatch(s.leftwin)
					assert(cell.foreground == attributes(0, "LazyVcsDiffFiller").fg, vim.inspect(cell))
				elseif status == "D" then
					assert(s.right_label == "No file in worktree", s.right_label)
					assert(s.left_label:find("Deleted from worktree", 1, true))
				end
				api.nvim_set_current_win(s.sidewin)
				require("lazyvcs.compare").action("metadata")
				ctx.wait_for(function()
					return s.mode == "metadata"
				end, "metadata toggle")
				assert(raw(s.leftwin) == "" and raw(s.rightwin) == "")
				assert(s.presence == nil)
				require("lazyvcs.compare").close(s)
			end
		)
	end
	add("core_diff_style_compare_empty_and_rename_presence", function()
		setup()
		local f = h.make_git_fixture()
		empty_file(f.root .. "/empty.txt")
		local s = compare_path(f, "empty.txt")
		assert(s.presence.left == "absent" and s.presence.right == "present")
		assert(s.right_label:find(" | Empty", 1, true), s.right_label)
		assert(#s.navigation.base == 0 and #s.navigation.saved == 0)
		require("lazyvcs.compare").close(s)
		h.write_file(f.file, "one\ntwo\nthree\n")
		h.exec({ "git", "mv", "sample.txt", "renamed.txt" }, f.root)
		local provider = require("lazyvcs.backends.compare_git")
		local snapshot = await(function(cb)
			provider.resolve({ root = f.root }, "HEAD", cb)
		end)
		local renamed = await(function(cb)
			provider.preview(snapshot, { status = "R", relpath = "renamed.txt", old_path = "sample.txt" }, cb)
		end)
		assert(renamed.presence.left == "present" and renamed.presence.right == "present")
		local labels = require("lazyvcs.diff_labels")
		assert(
			vim.deep_equal(
				labels.snapshot({ status = "R", old_path = "before.txt" }),
				{ left = "present", right = "present" }
			)
		)
		local left, right = labels.labels(
			"old",
			"new",
			"BASE",
			{ left = "unknown", right = "unknown" },
			{ empty = true },
			{ empty = true }
		)
		assert(left == "old" and right == "new")
	end)
	add("live_diff_style_git_presence_and_release", function()
		setup()
		local f = h.make_git_fixture()
		local path = f.root .. "/new.txt"
		h.write_file(path, "new\ncontent\n")
		local s = open_live(path)
		assert(s.presence.left == "absent" and s.presence.right == "present")
		assert(vim.wo[s.base_win].winbar:find("no file at index", 1, true))
		assert(vim.wo[s.editable_win].winbar:find("added (no file at index)", 1, true))
		mapping(s.base_win, "DiffDelete", "LazyVcsDiffFiller")
		api.nvim_set_current_win(s.editable_win)
		vim.cmd.split()
		local split = api.nvim_get_current_win()
		close_live(s)
		assert(raw(split) == "", raw(split))
		assert(raw(s.editable_win) == "")
		vim.cmd.only()
		h.exec({ "git", "add", "new.txt" }, f.root)
		s = open_live(path)
		assert(s.presence.left == "present")
		assert(not vim.wo[s.base_win].winbar:find("no file", 1, true))
		close_live(s)
		empty_file(path)
		h.exec({ "git", "add", "new.txt" }, f.root)
		s = open_live(path)
		assert(s.presence.left == "present" and s.base_text.empty)
		assert(vim.wo[s.base_win].winbar:find(" | empty", 1, true))
		close_live(s)
		local ita = f.root .. "/intent.txt"
		h.write_file(ita, "intent\n")
		h.exec({ "git", "add", "-N", "intent.txt" }, f.root)
		s = open_live(ita)
		assert(s.presence.left == "absent" and s.presence.intent_to_add)
		assert(vim.wo[s.editable_win].winbar:find("intent to add (no staged content)", 1, true))
		close_live(s)
	end)
	add("live_diff_style_transfer_pause_and_save_projection", function()
		setup()
		local f = h.make_git_fixture()
		local s = open_live(f.file)
		local win = s.editable_win
		local layout = require("lazyvcs.layout")
		local transaction = {}
		layout.prepare_sessions_save({ s }, transaction)
		assert(raw(win) == "", raw(win))
		layout.finish_sessions_save(transaction)
		assert(raw(win):find("diff:╱", 1, true))
		local path = f.root .. "/untracked.txt"
		h.write_file(path, "new\n")
		api.nvim_set_current_win(win)
		vim.cmd.edit(vim.fn.fnameescape(path))
		local next_session
		ctx.wait_for(function()
			next_session = require("lazyvcs.state").get(api.nvim_win_get_buf(win))
			return next_session and next_session ~= s
		end, "style transfer", 15000)
		assert(s.presence == nil)
		assert(next_session.presence.left == "absent")
		local outside = h.tempdir() .. "/outside.txt"
		h.write_file(outside, "outside\n")
		vim.cmd.edit(vim.fn.fnameescape(outside))
		ctx.wait_for(function()
			return require("lazyvcs.state").for_window(win).paused
		end, "style pause", 15000)
		assert(raw(win) == "" and raw(next_session.base_win) == "")
		assert(next_session.presence == nil)
	end)
	for _, status in ipairs({ "A", "?", "D" }) do
		add("svn_diff_style_compare_" .. ({ A = "added", ["?"] = "unversioned", D = "deleted" })[status], function()
			setup()
			local f = h.make_svn_fixture()
			local path = status == "D" and "sample.txt" or "added.txt"
			if status == "D" then
				h.exec({ "svn", "delete", "--force", path }, f.root)
			else
				h.write_file(f.root .. "/" .. path, "new\ncontent\n")
				if status == "A" then
					h.exec({ "svn", "add", path }, f.root)
				end
			end
			local compare_fixture = vim.tbl_extend("force", f, { base = h.file_url(f.repo) .. "@1" })
			local s = compare_path(compare_fixture, path)
			mapping(s.leftwin, "DiffDelete", "LazyVcsDiffFiller")
			assert(s.presence.left == (status == "D" and "present" or "absent"))
			assert(
				(status == "D" and s.right_label == "No file in worktree") or s.left_label:find("No file at", 1, true)
			)
			if status ~= "D" then
				hatch(s.leftwin)
			end
			require("lazyvcs.compare").close(s)
			local provider = require("lazyvcs.backends.compare_svn")
			local snapshot = await(function(cb)
				provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@1", cb)
			end)
			local result = await(function(cb)
				provider.preview(snapshot, { status = status, untracked = status == "?", relpath = path }, cb)
			end)
			assert(result.presence.left == (status == "D" and "present" or "absent"))
			assert(result.presence.right == (status == "D" and "absent" or "present"))
			local left, right = require("lazyvcs.diff_labels").labels(
				result.left_label,
				result.right_label,
				result.left_label,
				result.presence,
				result.left_document,
				result.right_document
			)
			assert((status == "D" and right == "No file in worktree") or left:find("No file at", 1, true))
		end)
	end
	add("live_diff_style_svn_scheduled_add", function()
		setup()
		local f = h.make_svn_fixture()
		local path = f.root .. "/added.txt"
		h.write_file(path, "new\ncontent\n")
		h.exec({ "svn", "add", "added.txt" }, f.root)
		local s = open_live(path)
		assert(s.presence.left == "absent" and s.presence.right == "present")
		assert(vim.wo[s.base_win].winbar:find("no file at base", 1, true))
		mapping(s.base_win, "DiffDelete", "LazyVcsDiffFiller")
		assert(raw(s.base_win):find("diff:╱", 1, true))
		close_live(s)
		assert(raw(s.editable_win) == "")
	end)

	add("live_diff_style_empty_labels_without_document_capture", function()
		setup()
		local f = h.make_git_fixture()
		empty_file(f.root .. "/empty.txt")
		local s = open_live(f.root .. "/empty.txt")
		local text = require("lazyvcs.compare_text")
		local original = text.capture
		---@diagnostic disable-next-line: duplicate-set-field
		text.capture = function()
			error("labels captured the document")
		end
		local ok, err = pcall(require("lazyvcs.layout").refresh, s)
		text.capture = original
		assert(ok, err)
		assert(vim.wo[s.base_win].winbar == " lazyvcs git no file at index [left]")
		assert(vim.wo[s.editable_win].winbar:find("added (no file at index) | empty", 1, true))
		for _, eol in ipairs({ false, true }) do
			for _, fixeol in ipairs({ false, true }) do
				vim.bo[s.editable_bufnr].endofline = eol
				vim.bo[s.editable_bufnr].fixendofline = fixeol
				assert(text.is_empty(s.editable_bufnr) == assert(text.capture(s.editable_bufnr, 1024)).empty)
			end
		end
		close_live(s)
	end)
	add("core_diff_style_release_forgets_buffer_records", function()
		setup()
		local win = window()
		guard.apply(win, "editor", "old")
		local applied = raw(win)
		vim.cmd.split()
		local inherited = api.nvim_get_current_win()
		guard.release(win)
		assert(raw(inherited) == "", raw(inherited))
		-- After the last owner releases the buffer these are deliberate user values.
		vim.wo[win].fillchars = applied
		vim.wo[win].winhighlight = "DiffDelete:LazyVcsDiffFiller,DiffAdd:LazyVcsDiffRemoved"
		api.nvim_set_current_win(win)
		api.nvim_exec_autocmds("BufWinEnter", { buffer = api.nvim_win_get_buf(win) })
		assert(raw(win) == applied, raw(win))
		assert(vim.wo[win].winhighlight == "DiffDelete:LazyVcsDiffFiller,DiffAdd:LazyVcsDiffRemoved")
		vim.cmd.tabclose()
	end)
	return cases
end
