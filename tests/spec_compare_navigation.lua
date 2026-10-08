return function(ctx)
	local compare = require("lazyvcs.compare")
	local actions = require("lazyvcs.actions")
	local function keys(text)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result ~= nil
		end, "preview did not load", 15000)
	end
	local function fixture(vcs)
		local f = vcs == "svn" and ctx.helpers.make_svn_fixture() or ctx.helpers.make_git_fixture()
		local lines = {}
		for i = 1, 40 do
			lines[i] = "line " .. i
		end
		ctx.helpers.write_file(f.file, table.concat(lines, "\n") .. "\n")
		if vcs == "svn" then
			ctx.helpers.exec({ "svn", "commit", "-m", "navigation base" }, f.root)
		else
			ctx.helpers.exec({ "git", "add", "sample.txt" }, f.root)
			ctx.helpers.exec({ "git", "commit", "-m", "navigation base" }, f.root)
		end
		for _, i in ipairs({ 5, 20, 35 }) do
			lines[i] = "changed " .. i
		end
		ctx.helpers.write_file(f.file, table.concat(lines, "\n") .. "\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local s = assert(
			compare.open({ path = f.root, base = vcs == "svn" and ctx.helpers.file_url(f.repo) .. "@2" or "HEAD" })
		)
		ready(s)
		vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["sample.txt"], 0 })
		if s.shown_item.relpath ~= "sample.txt" then
			keys("P")
			ready(s)
		end
		return f, s
	end
	local function line(win)
		return vim.api.nvim_win_get_cursor(win)[1]
	end
	local cases = {}
	for _, vcs in ipairs({ "git", "svn" }) do
		cases[#cases + 1] = {
			"test_" .. vcs .. "_comparison_hunk_activation_and_wrap",
			function()
				local f, s = fixture(vcs)
				assert(vim.api.nvim_get_current_win() == s.sidewin)
				keys("<CR>")
				assert(vim.api.nvim_get_current_win() == s.rightwin and line(s.rightwin) == 5)
				local cached = s.navigation
				local original, calls = require("lazyvcs.util").system_start, 0
				---@diagnostic disable-next-line: duplicate-set-field
				require("lazyvcs.util").system_start = function(...)
					calls = calls + 1
					return original(...)
				end
				for _, expected in ipairs({ 20, 35, 5 }) do
					keys("]v")
					assert(line(s.rightwin) == expected)
				end
				keys("[v")
				assert(line(s.rightwin) == 35 and line(s.leftwin) == 35)
				vim.api.nvim_set_current_win(s.leftwin)
				keys("]v")
				assert(line(s.leftwin) == 5 and vim.api.nvim_get_current_win() == s.leftwin)
				actions.next_hunk()
				assert(line(s.leftwin) == 20)
				assert(s.navigation == cached and calls == 0, "navigation reloaded the preview")
				require("lazyvcs.util").system_start = original
				assert(actions.revert_hunk() == false)
				assert(not vim.bo[s.left].modifiable and not vim.bo[s.right].modifiable)
				keys("<Esc><CR>")
				assert(vim.api.nvim_get_current_win() == s.rightwin and line(s.rightwin) == 20)
				keys("p<CR>")
				assert(s.mode == "text" and line(s.rightwin) == 20)
				keys("<Esc>P")
				assert(vim.api.nvim_get_current_win() == s.sidewin)
				keys("[v")
				assert(vim.api.nvim_get_current_win() == s.rightwin and line(s.rightwin) == 35)
				local before = ctx.helpers.exec(vcs == "git" and { "git", "diff" } or { "svn", "diff" }, f.root)
				compare.refresh(s)
				ready(s)
				assert(vim.api.nvim_get_current_win() == s.rightwin and line(s.rightwin) == 35)
				assert(before == ctx.helpers.exec(vcs == "git" and { "git", "diff" } or { "svn", "diff" }, f.root))
				compare.close(s)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_comparison_deleted_file_and_empty_added_file",
		function()
			local f, s = fixture("git")
			compare.close(s)
			vim.fn.delete(f.file)
			vim.fn.writefile({}, f.root .. "/empty.txt")
			s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["sample.txt"], 0 })
			keys("<CR>")
			ready(s)
			assert(
				vim.api.nvim_get_current_win() == s.leftwin and line(s.leftwin) == 1,
				vim.inspect({
					win = vim.api.nvim_get_current_win(),
					left = s.leftwin,
					navigation = s.navigation,
					intent = s.navigation_intent,
					item = s.shown_item,
				})
			)
			keys("]v[v<Esc>")
			vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["empty.txt"], 0 })
			keys("<CR>")
			ready(s)
			assert(
				vim.api.nvim_get_current_win() == s.sidewin,
				vim.inspect({
					win = vim.api.nvim_get_current_win(),
					side = s.sidewin,
					item = s.shown_item,
					navigation = s.navigation,
				})
			)
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_asymmetric_hunks_and_stacked_panes",
		function()
			local f, s = fixture("git")
			local lines = vim.deepcopy(s.preview_result.left)
			table.insert(lines, 8, "inserted one")
			table.insert(lines, 9, "inserted two")
			lines[22] = "changed twenty"
			table.remove(lines, 32)
			ctx.helpers.write_file(f.file, table.concat(lines, "\n") .. "\n")
			compare.refresh(s)
			ready(s)
			assert(#s.navigation.saved == 3)
			keys("<CR>")
			assert(line(s.rightwin) == 8 and line(s.leftwin) >= 7 and line(s.leftwin) <= 8)
			keys("]v")
			assert(line(s.rightwin) == 22 and line(s.leftwin) == 20)
			vim.api.nvim_set_current_win(s.leftwin)
			keys("]v")
			assert(line(s.leftwin) == 30 and line(s.rightwin) >= 31 and line(s.rightwin) <= 32)
			local columns = vim.o.columns
			vim.o.columns = 75
			vim.api.nvim_exec_autocmds("VimResized", {})
			assert(s.stacked and vim.api.nvim_get_current_win() == s.leftwin)
			keys("]v")
			assert(
				line(s.leftwin) == 7 and line(s.rightwin) >= 7 and line(s.rightwin) <= 10,
				vim.inspect({
					left = line(s.leftwin),
					right = line(s.rightwin),
					position = s.navigation.positions,
					index = s.navigation.index,
				})
			)
			vim.o.columns = columns
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_navigation_custom_and_disabled_mappings",
		function()
			for _, opts in ipairs({ { keymaps = { next_hunk = "]x", prev_hunk = false } }, { session_keymaps = false } }) do
				require("lazyvcs").setup(opts)
				local _, s = fixture("git")
				for _, buf in ipairs({ s.sidebar, s.left, s.right }) do
					vim.api.nvim_buf_call(buf, function()
						assert(vim.fn.maparg("]v", "n") == "" and vim.fn.maparg("[v", "n") == "")
						if opts.keymaps then
							assert(vim.fn.maparg("]x", "n") ~= "")
						end
					end)
				end
				if opts.keymaps then
					keys("]x")
				else
					actions.next_hunk()
				end
				assert(vim.api.nvim_get_current_win() == s.rightwin and line(s.rightwin) == 5)
				compare.close(s)
			end
			require("lazyvcs").setup({})
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_base_command_prompts_from_editor_and_recovers_cancel",
		function()
			local f, s = fixture("git")
			keys("<CR><Esc>")
			vim.api.nvim_set_current_tabpage(s.origin_tab)
			local input, calls = vim.ui.input, 0
			vim.ui.input = function(_, callback)
				calls = calls + 1
				callback(nil)
			end
			vim.cmd("LazyVCS compare base")
			ctx.wait_for(function()
				return calls == 1 and s.preview_result ~= nil and s.snapshot ~= nil
			end, "base cancel did not recover", 15000)
			vim.ui.input = input
			assert(compare.current() == s and s.root == f.root)
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_comparison_pending_activation_cancels_on_leave_selection_and_refresh",
		function()
			local f, s = fixture("git")
			ctx.helpers.write_file(f.root .. "/z.txt", "new file\n")
			compare.refresh(s)
			ready(s)
			local provider, pending = s.provider.preview, {}
			---@diagnostic disable-next-line: duplicate-set-field
			s.provider.preview = function(_, item, callback)
				pending[#pending + 1] = { callback = callback, item = item }
				return { kill = function() end }
			end
			for _, cancel in ipairs({ "leave", "selection", "refresh", "close" }) do
				vim.api.nvim_set_current_win(s.sidewin)
				s.provider.preview = provider
				vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["sample.txt"], 0 })
				keys("P")
				ready(s)
				---@diagnostic disable-next-line: duplicate-set-field
				s.provider.preview = function(_, item, callback)
					pending[#pending + 1] = { callback = callback, item = item }
					return { kill = function() end }
				end
				vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["z.txt"], 0 })
				keys("<CR>")
				assert(s.navigation_intent, "activation was cancelled by internal window calls")
				local request = pending[#pending]
				if cancel == "leave" then
					vim.api.nvim_set_current_win(s.leftwin)
					vim.api.nvim_set_current_win(s.sidewin)
				elseif cancel == "selection" then
					vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["sample.txt"], 0 })
					vim.api.nvim_exec_autocmds("CursorMoved", {})
					vim.api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["z.txt"], 0 })
				elseif cancel == "refresh" then
					compare.refresh(s)
				else
					compare.close(s)
				end
				assert(not s.navigation_intent)
				request.callback({ left = {}, right = { "new file" }, left_label = "BASE", right_label = "SAVED" })
				if cancel ~= "close" then
					assert(vim.api.nvim_get_current_win() == s.sidewin)
					s.provider.preview = provider
					compare.refresh(s)
					ready(s)
					---@diagnostic disable-next-line: duplicate-set-field
					s.provider.preview = function(_, item, callback)
						pending[#pending + 1] = { callback = callback, item = item }
						return { kill = function() end }
					end
				end
			end
			s.provider.preview = provider
		end,
	}
	return cases
end
