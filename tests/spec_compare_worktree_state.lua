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
	-- The pane marker, in either carrier Compare has used.
	local function marked(win)
		return tostring(util.get_win_option(win, "winhighlight")):find("LazyVcsComparePane", 1, true) ~= nil
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
	return cases
end
