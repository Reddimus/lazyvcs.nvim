return function(ctx)
	local api, h = vim.api, ctx.helpers
	local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
	local align, text, diff = require("lazyvcs.align"), require("lazyvcs.compare_text"), require("lazyvcs.diff")
	local cases = {}
	local function add(name, fn)
		cases[#cases + 1] = {
			name,
			function()
				actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
				local diffopt, hidden, columns, lines = vim.o.diffopt, vim.o.hidden, vim.o.columns, vim.o.lines
				local capture, compute, refresh =
					text.capture, diff.compute_text_hunks, require("lazyvcs.layout").refresh
				local gs, cache = package.loaded.gitsigns, package.loaded["gitsigns.cache"]
				local global_ns = api.nvim_get_hl_ns({})
				local ok, err = xpcall(fn, debug.traceback)
				text.capture, diff.compute_text_hunks, require("lazyvcs.layout").refresh = capture, compute, refresh
				package.loaded.gitsigns, package.loaded["gitsigns.cache"] = gs, cache
				api.nvim_set_hl_ns(global_ns)
				vim.o.hidden = true
				h.cleanup()
				vim.cmd("silent! tabonly!")
				vim.cmd("silent! only!")
				api.nvim_win_set_hl_ns(0, -1)
				vim.o.diffopt, vim.o.hidden, vim.o.columns, vim.o.lines = diffopt, hidden, columns, lines
				assert(ok, err)
			end,
		}
	end
	local function fixture(opts, svn)
		require("lazyvcs").setup(vim.tbl_deep_extend("force", {
			use_gitsigns = false,
			signs = { enabled = false },
			debounce_ms = 10,
		}, opts or {}))
		vim.o.hidden = true
		local f = svn and h.make_svn_transfer_fixture() or h.make_git_fixture()
		f.file = f.file or f.file1
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		require("lazyvcs.util").editor_window(api.nvim_get_current_win())
		return f
	end
	local function opened()
		local buf = api.nvim_get_current_buf()
		vim.cmd("LazyVCS diff open")
		ctx.wait_for(function()
			return state.get(buf) ~= nil
		end, "live diff did not open", 15000)
		return assert(state.get(buf))
	end
	local function settle()
		vim.wait(100, function()
			return false
		end)
	end
	local function padding(s)
		local count = 0
		for _, buf in ipairs({ s.base_bufnr, s.editable_bufnr }) do
			for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, align.namespace(), 0, -1, { details = true })) do
				count = count + #(mark[4].virt_lines or {})
			end
		end
		return count
	end
	add("test_live_diff_automatic_close_restores_preexisting_diff", function()
		for _, had_diff in ipairs({ true, false }) do
			for _, mode in ipairs({ "replace", "move", "explicit" }) do
				vim.cmd.tabnew()
				fixture()
				local source = api.nvim_get_current_win()
				vim.cmd("leftabove vnew")
				local peer = api.nvim_get_current_win()
				vim.cmd.diffthis()
				api.nvim_set_current_win(source)
				if had_diff then
					vim.cmd.diffthis()
				else
					vim.cmd.diffoff()
				end
				local names = { "diff", "scrollbind", "cursorbind", "foldmethod", "wrap", "foldenable" }
				local before = require("lazyvcs.util").capture_win_options(source, names)
				local s = opened()
				if mode == "replace" then
					api.nvim_set_current_win(s.base_win)
					vim.cmd.split()
					api.nvim_set_current_win(s.base_win)
					vim.cmd.enew()
				elseif mode == "move" then
					api.nvim_set_current_win(s.base_win)
					vim.cmd("wincmd T")
				else
					actions.close(s)
				end
				ctx.wait_for(function()
					return state.get(s.editable_bufnr) == nil
				end, "teardown did not finish")
				for _, name in ipairs(names) do
					assert(
						require("lazyvcs.util").get_win_option(source, name) == before[name],
						mode .. " lost " .. name
					)
				end
				assert(vim.wo[peer].diff, "teardown changed the peer diff")
				h.cleanup()
				vim.cmd("silent! tabonly!")
				vim.cmd("silent! only!")
				vim.cmd.diffoff()
			end
		end
	end)
	local function alignment(base, current, svn)
		local f = fixture({ base_window = { align_wrapped = "auto" } }, svn)
		h.write_file(f.file, table.concat(base, "\n") .. "\n")
		if svn then
			h.exec({ "svn", "commit", "-m", "alignment base", f.file }, f.root)
		else
			h.exec({ "git", "add", "sample.txt" }, f.root)
		end
		vim.cmd.edit()
		api.nvim_buf_set_lines(0, 0, -1, false, current)
		vim.opt.diffopt:append("followwrap")
		vim.o.columns, vim.o.lines = 120, 40
		vim.wo.wrap, vim.wo.linebreak, vim.wo.breakindent = true, false, false
		vim.cmd("normal! ggzt")
		local s = opened()
		for _, win in ipairs({ s.base_win, s.editable_win }) do
			vim.wo[win].foldenable = false
		end
		settle()
		return s
	end
	local function aligned_tail(s)
		vim.cmd.redraw()
		local positions = {}
		for _, win in ipairs({ s.base_win, s.editable_win }) do
			local tail
			for lnum, value in ipairs(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)) do
				if value == "tail" then
					tail = lnum
				end
			end
			local pos = vim.fn.screenpos(win, assert(tail), 1)
			assert(pos.row > 0, "tail is not visible")
			positions[#positions + 1] = pos.row - api.nvim_win_get_position(win)[1]
		end
		assert(positions[1] == positions[2], "stationary tail is misaligned: " .. vim.inspect({
			positions = positions,
			plan = s.align_plan,
			base = api.nvim_win_call(s.base_win, vim.fn.winsaveview),
			current = api.nvim_win_call(s.editable_win, vim.fn.winsaveview),
			topfill = s.align_topfill,
		}))
		assert(not align.apply(s), "alignment stacked padding on its second pass")
	end
	for _, svn in ipairs({ false, true }) do
		local prefix = svn and "test_svn_live_alignment_" or "test_live_diff_alignment_"
		local function ui_case(name)
			if #api.nvim_list_uis() > 0 then
				return false
			end
			local ok, output = require("ui_helpers").run_case(svn and "svn" or "live_diff", prefix .. name)
			assert(ok, output)
			return true
		end
		add(prefix .. "unequal_replacements", function()
			if ui_case("unequal_replacements") then
				return
			end
			for _, wrapped in ipairs({ false, true }) do
				for _, reverse in ipairs({ false, true }) do
					local base = { "old", "tail", "last" }
					local current = { wrapped and string.rep("x", 150) or "new", "extra", "tail", "last" }
					local s = alignment(reverse and current or base, reverse and base or current, svn)
					aligned_tail(s)
					if not wrapped then
						assert(padding(s) == 0, "native filler was counted twice")
					end
					h.cleanup()
				end
			end
		end)
		add(prefix .. "wrapped_one_sided_hunks", function()
			if ui_case("wrapped_one_sided_hunks") then
				return
			end
			for _, at_start in ipairs({ false, true }) do
				for _, deletion in ipairs({ false, true }) do
					local base = at_start and { "tail", "last" } or { "head", "tail", "last" }
					local current = vim.deepcopy(base)
					table.insert(current, at_start and 1 or 2, string.rep("x", 150))
					local s = alignment(deletion and current or base, deletion and base or current, svn)
					aligned_tail(s)
					assert(padding(s) > 0, "wrapped one-sided hunk has no padding")
					h.cleanup()
				end
			end
		end)
	end
	add("test_live_diff_alignment_shared_float_reconciles_after_idle", function()
		local s = alignment({ string.rep("x", 150), "tail" }, { "short", "tail" })
		assert(padding(s) > 0, "fixture has no padding")
		local win = api.nvim_open_win(s.editable_bufnr, false, {
			relative = "editor",
			row = 1,
			col = 1,
			width = 30,
			height = 10,
			style = "minimal",
		})
		ctx.wait_for(function()
			return padding(s) == 0
		end, "nonfocused float retained shared alignment padding")
		api.nvim_win_close(win, true)
		ctx.wait_for(function()
			return padding(s) > 0
		end, "closing the second display did not restore alignment")
	end)
	add("test_live_diff_failed_readonly_open_releases_scratch", function()
		local f = fixture()
		h.exec({ "git", "add", "sample.txt" }, f.root)
		local result, err
		require("lazyvcs.backends").load_diff_target_async({
			vcs = "git",
			root = f.root,
			relpath = "sample.txt",
			section = "staged",
			status = "M",
		}, function(value, message)
			result, err = value, message
		end)
		ctx.wait_for(function()
			return result ~= nil or err ~= nil
		end, "staged comparison did not load", 15000)
		assert(result, err)
		api.nvim_buf_set_lines(0, 0, 1, false, { "precious unsaved edit" })
		vim.o.hidden = false
		local buf, before = api.nvim_get_current_buf(), api.nvim_list_bufs()
		for _ = 1, 3 do
			assert(not actions.open_target(result), "modified nohidden destination was replaced")
		end
		assert(api.nvim_get_current_buf() == buf and vim.bo[buf].modified)
		assert(api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "precious unsaved edit")
		for _, candidate in ipairs(api.nvim_list_bufs()) do
			assert(vim.tbl_contains(before, candidate), "failed open leaked " .. api.nvim_buf_get_name(candidate))
		end
	end)
	add("test_live_diff_navigation_reuses_unchanged_hunks", function()
		fixture()
		local s = opened()
		local capture, compute, layout = text.capture, diff.compute_text_hunks, require("lazyvcs.layout")
		local refresh = layout.refresh
		local captures, computations, presentations = 0, 0, 0
		---@diagnostic disable-next-line: duplicate-set-field
		text.capture = function(...)
			captures = captures + 1
			return capture(...)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		diff.compute_text_hunks = function(...)
			computations = computations + 1
			return compute(...)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		layout.refresh = function(...)
			presentations = presentations + 1
			return refresh(...)
		end
		actions.next_hunk()
		actions.prev_hunk()
		assert(
			captures == 0 and computations == 0 and presentations == 0,
			"unchanged navigation repeated capture, hunk computation, or diffupdate"
		)
		local function invalidates(change)
			local before = computations
			change()
			actions.next_hunk()
			assert(computations == before + 1, "changed identity reused stale hunks")
			actions.prev_hunk()
			assert(computations == before + 1, "new hunks were not cached")
		end
		invalidates(function()
			api.nvim_buf_set_lines(s.editable_bufnr, 0, 1, false, { "new edit" })
		end)
		invalidates(function()
			vim.bo[s.editable_bufnr].fixendofline = false
			vim.bo[s.editable_bufnr].endofline = false
		end)
		invalidates(function()
			s.base_text = vim.deepcopy(s.base_text)
		end)
		invalidates(function()
			s.base_generation = (s.base_generation or 0) + 1
		end)
		-- Explicit refresh still performs presentation work and loads a fresh base.
		local generation = s.base_generation
		actions.refresh_current()
		ctx.wait_for(function()
			return not s.refresh_job and s.base_generation > generation
		end, "explicit refresh did not reload the base", 15000)
		assert(presentations > 0)
		local profile = s.base_text.profile_key
		vim.bo[s.editable_bufnr].fileformat = "dos"
		actions.next_hunk()
		assert(#s.hunks == 0 and not s.hunk_cache, "profile change reused cached hunks")
		ctx.wait_for(function()
			return not s.refresh_job and not s.base_invalid and s.base_text.profile_key ~= profile
		end, "profile change did not reload the base", 15000)
		api.nvim_buf_set_name(s.editable_bufnr, s.root .. "/renamed.txt")
		actions.next_hunk()
		assert(#s.hunks == 0 and not s.hunk_cache, "path change reused cached hunks")
	end)
	add("test_live_diff_readonly_navigation_reuses_unchanged_hunks", function()
		local f = fixture()
		local s = assert(actions.open_target({
			backend = "git",
			kind = "git_staged",
			path = f.file,
			root = f.root,
			relpath = "sample.txt",
			left = { label = "HEAD", lines = { "one", "two", "three" } },
			right = { label = "INDEX", lines = { "one", "changed", "three" } },
		}))
		local layout, calls = require("lazyvcs.layout"), 0
		local refresh = layout.refresh
		---@diagnostic disable-next-line: duplicate-set-field
		layout.refresh = function(...)
			calls = calls + 1
			return refresh(...)
		end
		actions.next_hunk()
		actions.prev_hunk()
		assert(calls == 0, "unchanged snapshot navigation forced diffupdate")
		assert(#s.hunks == 1 and api.nvim_win_get_cursor(s.editable_win)[1] == 2)
	end)
	add("test_live_diff_revert_from_base_preserves_other_edit_after_yield", function()
		local f = fixture({ use_gitsigns = true, source_control = { confirm_mutations = true } })
		local base, current = {}, {}
		for i = 1, 40 do
			base[i] = "original line " .. i
		end
		h.write_file(f.file, table.concat(base, "\n") .. "\n")
		h.exec({ "git", "add", "sample.txt" }, f.root)
		vim.cmd.edit()
		for i = 1, 10 do
			current[i] = "inserted " .. i
		end
		vim.list_extend(current, base)
		current[20], current[30] = "UNCONFIRMED edit", "TARGET edit"
		api.nvim_buf_set_lines(0, 0, -1, false, current)
		vim.opt.diffopt:append("linematch:40")
		local s = opened()
		local gs_hunks = {}
		for _, hunk in ipairs(s.hunks) do
			gs_hunks[#gs_hunks + 1] = {
				added = {
					start = hunk.current_start,
					count = hunk.current_count,
					lines = require("lazyvcs.util").slice(current, hunk.current_start, hunk.current_count),
				},
				removed = {
					start = hunk.base_start,
					count = hunk.base_count,
					lines = require("lazyvcs.util").slice(base, hunk.base_start, hunk.base_count),
				},
			}
		end
		vim.b[s.editable_bufnr].gitsigns_status_dict = {}
		package.loaded["gitsigns.cache"] = { cache = { [s.editable_bufnr] = { git_obj = {} } } }
		local delegated = 0
		package.loaded.gitsigns = {
			get_hunks = function()
				return gs_hunks
			end,
			reset_hunk = function()
				delegated = delegated + 1
				-- Model Gitsigns' linematch yield before cursor-based hunk selection.
				vim.schedule(function()
					local hunk = diff.find_current_hunk(s.hunks, api.nvim_win_get_cursor(0)[1])
					diff.reset_text_hunk(s.editable_bufnr, s.base_text, s.current_text, assert(hunk))
				end)
			end,
		}
		api.nvim_win_set_cursor(s.editable_win, { 30, 0 })
		api.nvim_set_current_win(s.base_win)
		api.nvim_win_set_cursor(s.base_win, { 20, 0 })
		local dialog = actions.revert_hunk()
		assert(dialog and dialog.winid, "confirmation did not open")
		vim.fn.maparg("1", "n", false, true).callback()
		ctx.wait_for(function()
			return delegated > 0 or api.nvim_buf_get_lines(s.editable_bufnr, 29, 30, false)[1] == base[20]
		end, "confirmed reset did not run", 15000)
		settle()
		local actual = api.nvim_buf_get_lines(s.editable_bufnr, 0, -1, false)
		assert(actual[20] == current[20], "revert discarded the unconfirmed edit")
		assert(actual[30] == base[20], "revert left the confirmed edit unchanged")
		assert(delegated == 0, "live reset delegated cursor selection across a yield")
	end)
	return cases
end
