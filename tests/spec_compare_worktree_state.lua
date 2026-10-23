-- Compare panes borrow real buffers and windows. They must leave highlight
-- namespaces, folds, labels, buffer lists, and saved sessions as they found them.
return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, util = require("lazyvcs.compare"), require("lazyvcs.util")
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job and not s.job
		end, "Compare did not load", 15000)
	end
	local function setup(opts)
		require("lazyvcs").setup(vim.tbl_deep_extend("force", {
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
		}, opts or {}))
	end
	-- An untracked a.txt is the first file and gets a private Compare buffer.
	local function private_fixture(opts)
		setup(opts)
		local f = h.make_git_fixture()
		h.write_file(f.root .. "/a.txt", "first\n")
		h.write_file(f.root .. "/b.txt", "second\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local origin = api.nvim_get_current_win()
		local s = assert(compare.open({ path = f.root, base = "HEAD" }))
		ready(s)
		assert(s.shown_item.relpath == "a.txt" and s.worktree, "a.txt is not an editable working buffer")
		assert(not vim.bo[s.right].buflisted, "a.txt is not private")
		return f, s, origin
	end
	local function navigate(s, direction, relpath)
		compare.navigate_file(direction, 1)
		ctx.wait_for(function()
			return s.shown_item and s.shown_item.relpath == relpath and not s.preview_job and s.preview_result
		end, "Compare did not show " .. relpath, 15000)
	end
	-- The pane marker, in any carrier Compare has used.
	local function marked(win)
		return tostring(util.get_win_option(win, "foldignore")):sub(-4) == "\28\29\30\31"
			or tostring(util.get_win_option(win, "winhighlight")):find("LazyVcsComparePane", 1, true) ~= nil
			or tonumber(util.get_win_option(win, "foldnestmax")) >= 100
	end
	local cases = {}

	-- A global nvim_set_hl_ns() theme keeps working in panes and copies.
	for _, mode in ipairs({ "syntax", "editor" }) do
		cases[#cases + 1] = {
			"test_core_compare_panes_keep_global_highlight_namespace_" .. mode,
			function()
				local theme = api.nvim_create_namespace("lazyvcs-test-global-theme")
				api.nvim_set_hl(theme, "Normal", { fg = 0xd0d0d0, bg = 0x102030 })
				api.nvim_set_hl(theme, "DiffText", { fg = 0xffffff, bg = 0xaf0000 })
				api.nvim_set_hl(theme, "DiffChange", { bg = 0x5f0000 })
				api.nvim_set_hl_ns(theme)
				local ok, err = xpcall(function()
					-- A fresh window, without a namespace from earlier tests.
					vim.cmd("tabnew")
					vim.cmd("silent! tabonly!")
					local _, s, origin = private_fixture({ diff_highlighting = mode })
					local before = api.nvim_get_hl_ns({ winid = origin })
					assert(before == -1, "the editor window was already namespaced")
					local function effective(win, name)
						local ns = api.nvim_get_hl_ns({ winid = win })
						if ns == -1 then
							ns = api.nvim_get_hl_ns({})
						end
						return api.nvim_get_hl(ns, { name = name, link = false }).bg
					end
					for _, win in ipairs({ s.leftwin, s.rightwin }) do
						assert(effective(win, "DiffText") == 0xaf0000, mode .. " pane lost the theme's DiffText")
						assert(effective(win, "Normal") == 0x102030, mode .. " pane lost the theme's Normal")
					end
					-- A window copied from a pane ends with the namespace an editor window has.
					api.nvim_set_current_win(s.rightwin)
					vim.cmd("split")
					local copy = api.nvim_get_current_win()
					assert(not marked(copy), "the copy kept the pane marker")
					assert(api.nvim_get_hl_ns({ winid = copy }) == before, "the copy changed highlight namespace")
					assert(effective(copy, "Normal") == 0x102030, "the copy lost the theme")
					api.nvim_win_close(copy, true)
					compare.close(s)
					assert(api.nvim_get_hl_ns({ winid = origin }) == before, "Compare changed the editor's namespace")
				end, debug.traceback)
				api.nvim_set_hl_ns(0)
				assert(ok, err)
			end,
		}
	end

	-- Removing an untouched private buffer does not bring it back.
	for _, command in ipairs({ "bdelete", "bunload" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_" .. command .. "_keeps_private_buffer_unlisted",
			function()
				local _, s = private_fixture()
				local buf = s.right
				api.nvim_set_current_win(s.rightwin)
				vim.cmd(command)
				ctx.wait_for(function()
					return not s.worktree and not s.preview_job and s.preview_result
				end, "Compare did not recover", 15000)
				assert(
					not api.nvim_buf_is_valid(buf) or not vim.bo[buf].buflisted,
					command .. " listed the removed private buffer again"
				)
				compare.close(s)
				assert(not api.nvim_buf_is_valid(buf) or not vim.bo[buf].buflisted, "the buffer was listed on close")
				local again = assert(compare.open({ path = s.root, base = "HEAD" }))
				ready(again)
				assert(again.right ~= buf, "Compare reused the removed buffer as a user buffer")
				compare.close(again)
			end,
		}
	end

	-- Compare's diff folds are not left as hidden manual folds.
	local function fold_count(win)
		return api.nvim_win_call(win, function()
			local enabled = vim.wo.foldenable
			vim.wo.foldenable = true
			local count = 0
			for line = 1, api.nvim_buf_line_count(0) do
				if vim.fn.foldlevel(line) > 0 then
					count = count + 1
				end
			end
			vim.wo.foldenable = enabled
			return count
		end)
	end
	local function long_fixture()
		setup()
		local f = h.make_git_fixture()
		local lines = {}
		for index = 1, 40 do
			lines[index] = "line " .. index
		end
		h.write_file(f.root .. "/long.txt", table.concat(lines, "\n") .. "\n")
		h.exec({ "git", "add", "long.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "long" }, f.root)
		lines[20] = "changed line"
		h.write_file(f.root .. "/long.txt", table.concat(lines, "\n") .. "\n")
		vim.cmd.edit(vim.fn.fnameescape(f.root .. "/long.txt"))
		local buf = api.nvim_get_current_buf()
		local s = assert(compare.open({ path = f.root, base = "HEAD" }))
		ready(s)
		assert(s.shown_item.relpath == "long.txt" and s.right == buf, "Compare did not show long.txt")
		assert(fold_count(s.rightwin) > 0, "the pane has no diff folds to leak")
		return f, s, buf
	end
	local fold_paths = {
		navigate = function(s, buf)
			navigate(s, "next", "sample.txt")
			vim.cmd("tabnew")
			vim.cmd.buffer(buf)
			return api.nvim_get_current_win()
		end,
		close = function(s, buf)
			compare.close(s)
			vim.cmd("tabnew")
			vim.cmd.buffer(buf)
			return api.nvim_get_current_win()
		end,
		split = function(s)
			api.nvim_set_current_win(s.rightwin)
			vim.cmd("split")
			return api.nvim_get_current_win()
		end,
		tab_split = function(s)
			api.nvim_set_current_win(s.rightwin)
			vim.cmd("tab split")
			return api.nvim_get_current_win()
		end,
		float = function(s)
			api.nvim_set_current_win(s.rightwin)
			return api.nvim_open_win(0, true, { relative = "editor", row = 1, col = 1, width = 30, height = 5 })
		end,
	}
	for name, path in pairs(fold_paths) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_diff_folds_stay_in_panes_" .. name,
			function()
				local _, s, buf = long_fixture()
				local win = path(s, buf)
				assert(api.nvim_win_get_buf(win) == buf)
				assert(not vim.wo[win].diff, name .. " window is in diff mode")
				assert(fold_count(win) == 0, name .. " window kept Compare's diff folds")
				if api.nvim_win_is_valid(win) and #api.nvim_list_wins() > 1 then
					api.nvim_win_close(win, true)
				end
				if not s.closed then
					if api.nvim_win_get_buf(s.rightwin) == buf then
						assert(fold_count(s.rightwin) > 0, "the pane lost its diff folds")
					end
					compare.close(s)
				end
			end,
		}
	end

	-- A reread from another tab uses an autocmd window, not a user window.
	cases[#cases + 1] = {
		"test_core_compare_worktree_background_reread_keeps_private_buffer_private",
		function()
			local f, s = private_fixture()
			local buf = s.right
			local autoread = vim.o.autoread
			vim.o.autoread = true
			vim.cmd("tabprevious")
			assert(api.nvim_get_current_tabpage() ~= s.tab)
			h.write_file(f.root .. "/a.txt", "first\nexternal change\n")
			vim.cmd("checktime")
			vim.o.autoread = autoread
			assert(api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "external change", "checktime did not reread")
			vim.wait(50)
			api.nvim_set_current_tabpage(s.tab)
			navigate(s, "next", "b.txt")
			assert(not api.nvim_buf_is_valid(buf), "a background reread kept the private buffer")
			compare.close(s)
		end,
	}

	-- Writing a copy elsewhere does not adopt the buffer; an edit still does.
	for _, variant in ipairs({ "copy", "edited_copy" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_write_" .. variant .. "_retention",
			function()
				local _, s = private_fixture()
				local buf = s.right
				api.nvim_set_current_win(s.rightwin)
				local copy = vim.fs.normalize(vim.fn.tempname()) .. "-a-copy.txt"
				if variant == "copy" then
					vim.cmd("write " .. vim.fn.fnameescape(copy))
				else
					vim.cmd("%s/first/copied/ | write " .. vim.fn.fnameescape(copy))
				end
				assert(vim.fn.filereadable(copy) == 1, "the copy was not written")
				vim.wait(50)
				local edited = variant == "edited_copy"
				assert(vim.bo[buf].buflisted == edited, "write to another file changed listing")
				navigate(s, "next", "b.txt")
				assert(api.nvim_buf_is_valid(buf) == edited, "write to another file changed retention")
				compare.close(s)
				vim.fn.delete(copy)
			end,
		}
	end

	-- A picker preview in the pane never receives the WORKTREE label.
	cases[#cases + 1] = {
		"test_core_compare_worktree_picker_preview_keeps_labels_off",
		function()
			local f, s, origin = private_fixture()
			h.write_file(f.root .. "/c.txt", "picked\n")
			local picked = vim.fn.bufadd(f.root .. "/c.txt")
			vim.fn.bufload(picked)
			vim.bo[picked].buflisted = true
			local buf = s.right
			-- The picker previews c.txt in the unfocused pane.
			api.nvim_set_current_win(s.sidewin)
			api.nvim_win_set_buf(s.rightwin, picked)
			-- Compare updates while the preview is open.
			api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "added" })
			vim.wait(400)
			assert(
				not tostring(util.get_win_option(s.rightwin, "winbar")):find("WORKTREE", 1, true),
				"the preview received Compare's label"
			)
			-- The picker confirms c.txt; Compare routes it to the editor.
			api.nvim_set_current_win(s.rightwin)
			ctx.wait_for(function()
				return api.nvim_win_get_buf(s.rightwin) == buf and api.nvim_win_get_buf(origin) == picked
			end, "picker selection was not routed", 15000)
			assert(tostring(util.get_win_option(s.rightwin, "winbar")):find("WORKTREE", 1, true), "pane lost its label")
			for _, win in ipairs({ origin }) do
				assert(
					not tostring(util.get_win_option(win, "winbar")):find("WORKTREE", 1, true),
					"the editor shows Compare's label"
				)
			end
			api.nvim_set_current_win(origin)
			vim.cmd("vsplit")
			vim.cmd.buffer(picked)
			local split = api.nvim_get_current_win()
			assert(
				not tostring(util.get_win_option(split, "winbar")):find("WORKTREE", 1, true),
				"a split of the editor shows Compare's label"
			)
			api.nvim_win_close(split, true)
			compare.close(s)
		end,
	}

	-- A session saved during Compare restores no live pane marker.
	cases[#cases + 1] = {
		"test_core_compare_worktree_restored_session_keeps_user_diff",
		function()
			local _, s = private_fixture()
			navigate(s, "next", "b.txt")
			navigate(s, "prev", "a.txt")
			local path = api.nvim_buf_get_name(s.right)
			api.nvim_set_current_win(s.rightwin)
			assert(marked(s.rightwin), "the pane has no marker")
			local sessionoptions = vim.o.sessionoptions
			local session = vim.fs.normalize(vim.fn.tempname()) .. ".vim"
			local ok, err = xpcall(function()
				-- Save only the Compare tab, with window-local options.
				vim.o.sessionoptions = "options,winsize"
				vim.cmd("mksession! " .. vim.fn.fnameescape(session))
				compare.close(s)
				-- A fresh window for the session to reuse.
				vim.cmd("tabnew")
				vim.cmd("silent! tabonly!")
				vim.cmd("source " .. vim.fn.fnameescape(session))
				local restored
				for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
					if
						util.canonical_path(api.nvim_buf_get_name(api.nvim_win_get_buf(win)))
						== util.canonical_path(path)
					then
						restored = win
					end
				end
				assert(restored, "the session did not restore the pane window")
				assert(not vim.w[restored].lazyvcs_compare)
				assert(not marked(restored), "the restored window kept a pane marker")
				-- The user replaces the restored state with a diff of their own, then reloads.
				api.nvim_set_current_win(restored)
				vim.cmd("diffoff")
				vim.cmd("diffthis")
				vim.cmd.edit()
				assert(vim.wo[restored].diff, "reloading turned off the user's diff")
				vim.cmd("diffoff!")
			end, debug.traceback)
			vim.o.sessionoptions = sessionoptions
			vim.fn.delete(session)
			assert(ok, err)
		end,
	}
	-- A picker previewing in the sidebar window gets none of the sidebar's labels.
	cases[#cases + 1] = {
		"test_core_compare_sidebar_preview_keeps_sidebar_labels_off",
		function()
			local f, s = private_fixture()
			h.write_file(f.root .. "/c.txt", "picked\n")
			local picked = vim.fn.bufadd(f.root .. "/c.txt")
			vim.fn.bufload(picked)
			vim.bo[picked].buflisted = true
			-- The picker's input keeps focus while it previews in the sidebar window.
			local input = api.nvim_open_win(
				api.nvim_create_buf(false, true),
				true,
				{ relative = "editor", row = 1, col = 1, width = 20, height = 1 }
			)
			api.nvim_win_set_buf(s.sidewin, picked)
			local function clean(win, context)
				local winbar = tostring(util.get_win_option(win, "winbar"))
				local statusline = tostring(util.get_win_option(win, "statusline"))
				assert(
					not winbar:find("LazyVcsComparePath", 1, true) and not statusline:find("? help", 1, true),
					context .. " shows the sidebar's labels: " .. vim.inspect({ winbar, statusline })
				)
			end
			-- A refresh finishes while the preview is open.
			compare.refresh(s)
			ctx.wait_for(function()
				return not s.job
			end, "the refresh did not finish", 15000)
			clean(s.sidewin, "the preview")
			-- The picker closes and puts the sidebar back itself.
			api.nvim_win_set_buf(s.sidewin, s.sidebar)
			api.nvim_win_close(input, true)
			vim.wait(100)
			assert(
				tostring(util.get_win_option(s.sidewin, "statusline")):find("? help", 1, true),
				"the sidebar lost its hints"
			)
			vim.cmd("tabnew")
			vim.cmd.buffer(picked)
			clean(api.nvim_get_current_win(), "a new window on the previewed file")
			vim.cmd("tabclose")
			compare.close(s)
		end,
	}

	-- A picker that cancels an unfocused preview gets the latest label back.
	cases[#cases + 1] = {
		"test_core_compare_unfocused_preview_cancel_restores_latest_label",
		function()
			local f, s = private_fixture()
			h.write_file(f.root .. "/c.txt", "picked\n")
			local picked = vim.fn.bufadd(f.root .. "/c.txt")
			vim.fn.bufload(picked)
			local buf = s.right
			api.nvim_set_current_win(s.sidewin)
			api.nvim_win_set_buf(s.rightwin, picked)
			-- The working buffer changes while the preview is open.
			api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "added" })
			ctx.wait_for(function()
				return tostring(s.right_label):find("unsaved", 1, true) ~= nil
			end, "Compare did not see the change", 3000)
			-- The picker cancels and restores the pane's buffer itself.
			api.nvim_win_set_buf(s.rightwin, buf)
			vim.wait(100)
			local winbar = tostring(util.get_win_option(s.rightwin, "winbar"))
			assert(winbar:find("WORKTREE (unsaved)", 1, true), "the pane shows a stale label: " .. winbar)
			vim.bo[buf].modified = false
			compare.close(s)
		end,
	}

	-- A session saved during Compare with the default 'sessionoptions' restores
	-- the pane's window as an ordinary one.
	cases[#cases + 1] = {
		"test_core_compare_restored_session_resets_pane_folds",
		function()
			local _, s = private_fixture()
			local path = api.nvim_buf_get_name(s.right)
			api.nvim_set_current_win(s.rightwin)
			local sessionoptions = vim.o.sessionoptions
			local session = vim.fs.normalize(vim.fn.tempname()) .. ".vim"
			local ok, err = xpcall(function()
				vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,terminal"
				vim.cmd("mksession! " .. vim.fn.fnameescape(session))
				compare.close(s)
				vim.cmd("tabnew")
				vim.cmd("silent! tabonly!")
				vim.cmd("source " .. vim.fn.fnameescape(session))
				local restored
				for _, win in ipairs(api.nvim_list_wins()) do
					if
						util.canonical_path(api.nvim_buf_get_name(api.nvim_win_get_buf(win)))
						== util.canonical_path(path)
					then
						restored = win
					end
				end
				assert(restored, "the session did not restore the pane window")
				assert(not marked(restored), "the restored window kept a pane marker")
				local values = util.capture_win_options(restored, { "foldmethod", "foldcolumn", "diff" })
				assert(
					values.foldmethod ~= "diff" and values.foldcolumn == "0",
					"kept pane folds: " .. vim.inspect(values)
				)
				api.nvim_set_current_win(restored)
				assert(pcall(vim.api.nvim_command, "1fold"), "the restored window cannot create folds")
			end, debug.traceback)
			vim.o.sessionoptions = sessionoptions
			vim.fn.delete(session)
			vim.cmd("silent! tabonly!")
			assert(ok, err)
		end,
	}

	return cases
end
