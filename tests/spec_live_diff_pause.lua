return function(ctx)
	local h, api = ctx.helpers, vim.api
	local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
	local cases = {}
	for _, vcs in ipairs({ "git", "svn" }) do
		cases[#cases + 1] = {
			"test_live_diff_" .. vcs .. "_unsupported_file_pauses_and_resumes_without_notices",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = true },
					blame = { persist = false },
				})
				local f = vcs == "svn" and h.make_svn_transfer_fixture() or h.make_git_transfer_fixture()
				local link = f.root .. "/GNUmakefile"
				h.write_file(f.root .. "/make-target.txt", "preserve this target\n")
				assert(vim.uv.fs_symlink("make-target.txt", link))
				h.exec(vcs == "svn" and { "svn", "add", link .. "@" } or { "git", "add", "--", link }, f.root)
				vim.cmd.edit(vim.fn.fnameescape(f.file1))
				actions.open()
				ctx.wait_for(function()
					return state.current() ~= nil
				end, "initial diff", 15000)
				local original = assert(state.current())
				local base, editor = original.base_win, original.editable_win
				local util, notices = require("lazyvcs.util"), {}
				local notify = util.notify
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(message)
					notices[#notices + 1] = message
				end
				local ok, err = xpcall(function()
					vim.cmd.edit(vim.fn.fnameescape(link))
					ctx.wait_for(function()
						local s = state.for_window(editor)
						return s and s.paused
					end, "symlink did not pause", 15000)
					local paused = state.for_window(editor)
					assert(paused.base_win == base and paused.editable_win == editor)
					assert(not paused.base_identity and not paused.base_text and not paused.hunks)
					assert(state.get(api.nvim_get_current_buf()) == nil, "paused view claimed unsupported source")
					assert(not vim.wo[editor].diff and not vim.wo[base].diff)
					assert(api.nvim_buf_get_lines(paused.base_bufnr, 0, 1, false)[1] == "Diff paused")
					vim.wait(200)
					assert(#notices == 0, vim.inspect(notices))
					vim.cmd.edit(vim.fn.fnameescape(f.file2))
					ctx.wait_for(function()
						local s = state.for_window(editor)
						return s and not s.paused and s.phase == "active"
					end, "supported file did not resume", 15000)
					assert(state.current().base_win == base and vim.wo[editor].diff and vim.wo[base].diff)
					assert(#notices == 0, vim.inspect(notices))
					actions.close()
				end, debug.traceback)
				util.notify = notify
				assert(ok, err)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_live_diff_paused_refresh_redetects_a_new_repository_immediately",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, session_keymaps = false })
			local f = h.make_git_fixture()
			vim.cmd.edit(f.file)
			actions.open()
			ctx.wait_for(function()
				return state.current() ~= nil
			end, "initial diff", 15000)
			local win = state.current().editable_win
			local root = h.tempdir()
			local path = root .. "/new.txt"
			h.write_file(path, "new repository\n")
			vim.cmd.edit(path)
			ctx.wait_for(function()
				return state.for_window(win) and state.for_window(win).paused
			end, "outside file did not pause", 15000)
			assert(table.concat(state.for_window(win).base_lines, "\n"):find(":LazyVCS diff close", 1, true))
			-- Seed a durable negative cache entry, then initialize the repository
			-- before its five-second TTL can expire. Refresh must invalidate it.
			assert(not require("lazyvcs.backends").resolve_cached(path))
			h.exec({ "git", "init" }, root)
			h.exec({ "git", "config", "user.email", "test@example.com" }, root)
			h.exec({ "git", "config", "user.name", "Test" }, root)
			h.exec({ "git", "add", "new.txt" }, root)
			h.exec({ "git", "commit", "-m", "initial" }, root)
			actions.refresh_current()
			ctx.wait_for(function()
				local view = state.for_window(win)
				return view and view.phase == "active" and not view.paused and view.source_path == path
			end, "paused refresh reused negative repository discovery", 15000)
			actions.close()
		end,
	}
	return cases
end
