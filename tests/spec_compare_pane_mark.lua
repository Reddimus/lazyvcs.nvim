-- The pane mark must stay invisible to folding in every window, belong only to
-- Compare, survive option changes in a live pane, and leave other windows alone.
return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, util = require("lazyvcs.compare"), require("lazyvcs.util")
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job and not s.job
		end, "Compare did not load", 15000)
	end
	local function setup()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
	end
	local function levels(win)
		return api.nvim_win_call(win, function()
			vim.cmd("normal! zx")
			local out = {}
			for line = 1, api.nvim_buf_line_count(0) do
				out[#out + 1] = vim.fn.foldlevel(line)
			end
			return table.concat(out, "")
		end)
	end
	local function plain(win, context)
		local values = util.capture_win_options(win, { "diff", "scrollbind", "cursorbind", "foldmethod", "winbar" })
		assert(
			not values.diff
				and not values.scrollbind
				and not values.cursorbind
				and values.foldmethod ~= "diff"
				and not tostring(values.winbar):find("WORKTREE", 1, true),
			context .. " inherited Compare pane options: " .. vim.inspect(values)
		)
	end
	local code = {
		"local function a()",
		"  if x then",
		"    if y then",
		"      return 1",
		"    end",
		"  end",
		"end",
		"local t = {",
		"  b = function()",
		"    return 2",
		"  end,",
		"}",
	}
	local cases = {}

	-- Marking a pane changes no fold in a window that shares its buffer.
	for name, method in pairs({
		treesitter = { "expr", "v:lua.vim.treesitter.foldexpr()" },
		indent = { "indent" },
		expr = { "expr", "indent(v:lnum)/shiftwidth()" },
	}) do
		cases[#cases + 1] = {
			"test_core_compare_pane_mark_keeps_shared_buffer_folds_" .. name,
			function()
				setup()
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/code.lua", table.concat(code, "\n") .. "\n")
				h.exec({ "git", "add", "code.lua" }, f.root)
				h.exec({ "git", "commit", "-m", "code" }, f.root)
				code[4] = "      return 10"
				h.write_file(f.root .. "/code.lua", table.concat(code, "\n") .. "\n")
				code[4] = "      return 1"
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/code.lua"))
				local editor, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
				vim.bo[buf].shiftwidth = 2
				vim.wo[editor].foldmethod = method[1]
				if method[2] then
					vim.wo[editor].foldexpr = method[2]
				end
				vim.wo[editor].foldnestmax = 1
				if name == "treesitter" then
					vim.treesitter.start(buf, "lua")
				end
				local before = levels(editor)
				assert(before:find("1", 1, true), "the editor has no folds to compare")
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ready(s)
				assert(s.right == buf, "Compare did not show the editor's buffer")
				vim.wait(50)
				assert(levels(editor) == before, name .. " folds changed in the editor: " .. levels(editor))
				compare.close(s)
				assert(levels(editor) == before, name .. " folds changed after Compare closed")
				if name == "treesitter" then
					vim.treesitter.stop(buf)
				end
			end,
		}
	end

	-- User values that look like a mark are the user's.
	cases[#cases + 1] = {
		"test_core_compare_pane_mark_ignores_user_values",
		function()
			setup()
			local f = h.make_git_fixture()
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local win = api.nvim_get_current_win()
			util.set_win_option(win, "foldnestmax", 100)
			util.set_win_option(win, "foldignore", "\28#")
			setup()
			assert(util.get_win_option(win, "foldnestmax") == 100, "setup changed the user's fold depth")
			assert(util.get_win_option(win, "foldignore") == "\28#", "setup changed the user's foldignore")
			-- Install Compare's window handlers, then use the window normally.
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			compare.close(s)
			api.nvim_set_current_win(win)
			vim.cmd("diffthis")
			vim.cmd.edit()
			assert(vim.wo[win].diff, "reloading turned off the user's diff")
			vim.cmd("split")
			local split = api.nvim_get_current_win()
			assert(vim.wo[win].diff and vim.wo[split].diff, "a split turned off the user's diff")
			assert(util.get_win_option(split, "foldnestmax") == 100, "the split lost the user's fold depth")
			vim.cmd("diffoff!")
			api.nvim_win_close(split, true)
		end,
	}

	-- Option changes in a live pane keep the pane marked.
	for _, change in ipairs({ "setlocal", "modeline" }) do
		cases[#cases + 1] = {
			"test_core_compare_pane_mark_survives_" .. change,
			function()
				setup()
				local f = h.make_git_fixture()
				local modeline = vim.o.modeline
				vim.o.modeline = true
				h.write_file(f.root .. "/a.txt", "first\n" .. (change == "modeline" and "vim: fdi=x fdn=3\n" or ""))
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ready(s)
				assert(s.shown_item.relpath == "a.txt" and s.worktree, "a.txt is not an editable working buffer")
				api.nvim_set_current_win(s.rightwin)
				if change == "setlocal" then
					vim.cmd("setlocal foldignore=x foldnestmax=3")
				else
					-- :doautocmd applies the buffer's modelines to the live pane again
					-- once an autocommand ran.
					local group = api.nvim_create_augroup("lazyvcs_test_modeline", { clear = true })
					api.nvim_create_autocmd("User", { group = group, pattern = "LazyVCSModelineTest", command = "" })
					util.set_win_option(s.rightwin, "foldignore", "#")
					vim.cmd("doautocmd User LazyVCSModelineTest")
					api.nvim_del_augroup_by_id(group)
				end
				vim.o.modeline = modeline
				assert(vim.wo[s.rightwin].diff, "the pane left diff mode")
				vim.cmd("split")
				local copy = api.nvim_get_current_win()
				plain(copy, "split after " .. change)
				assert(util.get_win_option(copy, "foldignore") == "x", "the copy lost the requested foldignore")
				assert(util.get_win_option(copy, "foldnestmax") == 3, "the copy lost the requested fold depth")
				api.nvim_win_close(copy, true)
				compare.close(s)
			end,
		}
	end

	return cases
end
