-- A window that copies a Compare pane's options gets none of its Compare state,
-- however the pane's 'foldignore' mark was replaced, and a window whose options
-- are its own keeps them.
return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, util = require("lazyvcs.compare"), require("lazyvcs.util")
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job and not s.job
		end, "Compare did not load", 15000)
	end
	local function fixture()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
		local f = h.make_git_fixture()
		h.write_file(f.root .. "/a.txt", "first\n")
		h.write_file(f.root .. "/b.txt", "second\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local origin = api.nvim_get_current_win()
		local s = assert(compare.open({ path = f.root, base = "HEAD" }))
		ready(s)
		assert(s.shown_item.relpath == "a.txt" and s.worktree, "a.txt is not an editable working buffer")
		return f, s, origin
	end
	local function navigate(s, direction, relpath)
		compare.navigate_file(direction, 1)
		ctx.wait_for(function()
			return s.shown_item and s.shown_item.relpath == relpath and not s.preview_job and s.preview_result
		end, "Compare did not show " .. relpath, 15000)
	end
	local function plain(values, context)
		assert(
			not values.diff
				and not values.scrollbind
				and not values.cursorbind
				and values.foldmethod ~= "diff"
				and values.foldcolumn == "0"
				and not tostring(values.winbar):find("WORKTREE", 1, true),
			context .. " inherited Compare pane options: " .. vim.inspect(values)
		)
	end
	local function options(win)
		return util.capture_win_options(
			win,
			{ "diff", "scrollbind", "cursorbind", "foldmethod", "foldcolumn", "winbar" }
		)
	end
	local cases = {}

	-- Autocommands that LazyVCS cannot run after: they precede its handlers.
	local function user_fixture(scenario, step)
		local repo = vim.fs.normalize(
			vim.fn.fnamemodify(assert(vim.api.nvim_get_runtime_file("lua/lazyvcs/compat.lua", false)[1]), ":p:h:h:h")
		)
		local output = vim.fs.normalize(vim.fn.tempname())
		local result = vim.system({
			vim.v.progpath,
			"--headless",
			"-u",
			"NONE",
			"-i",
			"NONE",
			"-l",
			repo .. "/tests/fixtures/compare_user_autocmds.lua",
			repo,
			output,
			scenario,
			step,
		}, { text = true }):wait(60000)
		assert(result.code == 0, "nested editor failed: " .. tostring(result.stderr))
		local values = vim.json.decode(table.concat(vim.fn.readfile(output), "\n"))
		vim.fn.delete(output)
		assert(not values.error, values.error)
		assert(values.pane.diff and values.pane.scrollbind, "the Compare pane lost its diff")
		return values
	end
	for _, scenario in ipairs({ "loadview", "bufenter" }) do
		for _, step in ipairs({ "edit", "split", "tabnew", "float" }) do
			cases[#cases + 1] = {
				"test_core_compare_pane_copy_" .. step .. "_after_user_" .. scenario,
				function()
					local values = user_fixture(scenario, step)
					if step == "edit" then
						assert(values.origin, "edit did not use the editor")
					end
					plain(values.window, step .. " with a user " .. scenario .. " autocommand")
				end,
			}
		end
	end

	-- The GDScript ftplugin clears 'foldignore' in a FileType autocommand, where
	-- OptionSet does not run.
	cases[#cases + 1] = {
		"test_core_compare_pane_split_after_filetype_plugin",
		function()
			local _, s = fixture()
			vim.cmd("filetype plugin on")
			local ok, err = xpcall(function()
				api.nvim_set_current_win(s.rightwin)
				vim.cmd("setlocal filetype=gdscript")
				assert(vim.wo[s.rightwin].diff, "the pane left diff mode")
				vim.cmd("split")
				local copy = api.nvim_get_current_win()
				plain(options(copy), "split after the ftplugin")
				api.nvim_win_close(copy, true)
				-- Undoing the ftplugin resets 'foldignore' too.
				api.nvim_set_current_win(s.rightwin)
				vim.cmd("setlocal filetype=text")
				vim.cmd("vsplit")
				copy = api.nvim_get_current_win()
				plain(options(copy), "split after undoing the ftplugin")
				api.nvim_win_close(copy, true)
			end, debug.traceback)
			vim.cmd("filetype plugin off")
			compare.close(s)
			assert(ok, err)
		end,
	}

	-- An autocommand that sets 'foldignore' on entering a window runs after
	-- Compare's handlers, without OptionSet.
	for _, step in ipairs({ "split", "edit" }) do
		cases[#cases + 1] = {
			"test_core_compare_pane_" .. step .. "_after_bufenter_foldignore",
			function()
				local _, s, origin = fixture()
				navigate(s, "next", "b.txt")
				navigate(s, "prev", "a.txt")
				local group = api.nvim_create_augroup("lazyvcs_test_bufenter_foldignore", { clear = true })
				api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
					group = group,
					command = "setlocal foldignore=#",
				})
				local ok, err = xpcall(function()
					-- Entering the pane from the sidebar runs the autocommand there.
					api.nvim_set_current_win(s.sidewin)
					api.nvim_set_current_win(s.rightwin)
					assert(util.get_win_option(s.rightwin, "foldignore") ~= "\28\29\30\31", "no autocommand ran")
					local win
					if step == "split" then
						vim.cmd("split")
						win = api.nvim_get_current_win()
					else
						s.actions.edit()
						win = api.nvim_get_current_win()
						assert(win == origin, "edit did not use the editor")
					end
					plain(options(win), step .. " after the autocommand")
					if step == "split" then
						api.nvim_win_close(win, true)
					end
				end, debug.traceback)
				api.nvim_del_augroup_by_id(group)
				compare.close(s)
				assert(ok, err)
			end,
		}
	end

	-- Adding to and removing from 'foldignore' in a pane leaves one mark.
	cases[#cases + 1] = {
		"test_core_compare_pane_mark_stays_single_after_incremental_changes",
		function()
			local _, s = fixture()
			api.nvim_set_current_win(s.rightwin)
			vim.cmd("setlocal foldignore+=!")
			vim.cmd("setlocal foldignore-=!")
			local value = tostring(util.get_win_option(s.rightwin, "foldignore"))
			assert(
				select(2, value:gsub("\28\29\30\31", "")) == 1,
				"the pane has more than one mark: " .. vim.inspect(value)
			)
			vim.cmd("split")
			local copy = api.nvim_get_current_win()
			plain(options(copy), "split after incremental changes")
			value = tostring(util.get_win_option(copy, "foldignore"))
			assert(not value:find("[\28\29\30\31]"), "the copy kept a mark: " .. vim.inspect(value))
			-- The copy is the user's window now: their own diff stays on.
			vim.cmd("diffoff | diffthis")
			vim.cmd.edit()
			assert(vim.wo[copy].diff, "Compare turned off the user's diff")
			vim.cmd("diffoff")
			api.nvim_win_close(copy, true)
			compare.close(s)
		end,
	}
	-- Separator characters the user put in 'foldignore' are not a mark unless
	-- they end the value once, and a mark on a buffer no pane showed is not a copy.
	for name, value in pairs({ inside = "#\28\29\30\31x", twice = "\28\29\30\31#\28\29\30\31" }) do
		cases[#cases + 1] = {
			"test_core_compare_pane_mark_ignores_user_separators_" .. name,
			function()
				local f, s = fixture()
				compare.close(s)
				local other = h.tempdir() .. "/other.txt"
				h.write_file(other, "one\ntwo\n")
				vim.cmd.edit(vim.fn.fnameescape(other))
				local win = api.nvim_get_current_win()
				util.set_win_option(win, "foldignore", value)
				vim.cmd("diffthis")
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					blame = { persist = false },
				})
				vim.cmd.edit()
				vim.cmd("split")
				local split = api.nvim_get_current_win()
				assert(vim.wo[win].diff and vim.wo[split].diff, "Compare took the user's window for a copy")
				assert(util.get_win_option(win, "foldignore") == value, "Compare changed the user's foldignore")
				vim.cmd("diffoff!")
				api.nvim_win_close(split, true)
				assert(f.root)
			end,
		}
	end
	return cases
end
