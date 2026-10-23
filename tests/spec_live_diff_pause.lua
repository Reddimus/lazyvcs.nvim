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
	local function open_live(path)
		vim.cmd.edit(vim.fn.fnameescape(path))
		local buf = api.nvim_get_current_buf()
		actions.open()
		ctx.wait_for(function()
			local s = state.get(buf)
			return s and s.phase == "active"
		end, "live diff did not open", 15000)
		return assert(state.get(buf))
	end
	local function setup()
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, blame = { persist = false } })
	end
	local function settle()
		vim.wait(300, function()
			return false
		end)
	end
	-- Return immediately, or while the replacement base is still loading.
	local function interrupt(win, timing)
		if timing == "loading" then
			assert(vim.wait(1000, function()
				local p = state.peek_pending_transfer(win)
				return p and p.phase == "loading"
			end, 1))
		end
	end
	for _, timing in ipairs({ "immediate", "loading" }) do
		cases[#cases + 1] = {
			"test_live_diff_paused_return_" .. timing .. "_restores_pause",
			function()
				setup()
				local f = h.make_git_transfer_fixture()
				local outside = h.tempdir() .. "/outside.txt"
				h.write_file(outside, "outside\n")
				local win = open_live(f.file1).editable_win
				vim.cmd.edit(vim.fn.fnameescape(outside))
				ctx.wait_for(function()
					local s = state.for_window(win)
					return s and s.paused
				end, "outside file did not pause", 15000)
				local paused = state.for_window(win)
				vim.cmd.edit(vim.fn.fnameescape(f.file2))
				interrupt(win, timing)
				vim.cmd.edit(vim.fn.fnameescape(outside))
				ctx.wait_for(function()
					return paused.phase == "paused" and not state.peek_pending_transfer(win)
				end, "paused view stayed in phase " .. tostring(paused.phase), 3000)
				settle()
				assert(state.for_window(win) == paused and paused.paused and paused.phase == "paused")
				local lines = api.nvim_buf_get_lines(paused.base_bufnr, 0, -1, false)
				assert(lines[1] == "Diff paused", vim.inspect(lines))
				assert(not state.peek_pending_transfer(win), "pending transfer was not cleared")
				actions.close(paused)
			end,
		}
	end
	for _, timing in ipairs({ "immediate", "loading" }) do
		cases[#cases + 1] = {
			"test_live_diff_same_file_return_" .. timing .. "_restores_hunk_maps",
			function()
				setup()
				local f = h.make_git_transfer_fixture()
				local s = open_live(f.file1)
				local buf, win = s.editable_bufnr, s.editable_win
				local function mapped(lhs)
					return vim.fn.maparg(lhs, "n", false, true).buffer == 1
				end
				assert(mapped("]v") and mapped("[v") and mapped("<leader>vr"), "active maps missing")
				vim.cmd.edit(vim.fn.fnameescape(f.file2))
				interrupt(win, timing)
				vim.cmd.edit(vim.fn.fnameescape(f.file1))
				ctx.wait_for(function()
					return s.phase == "active" and not state.peek_pending_transfer(win)
				end, "same-file return did not settle", 3000)
				settle()
				assert(state.for_window(win) == s and api.nvim_get_current_buf() == buf)
				assert(mapped("]v") and mapped("[v") and mapped("<leader>vr"), "returned view lost its hunk maps")
				actions.close(s)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_live_diff_paused_view_resume_keeps_other_view_diff",
		function()
			setup()
			local f = h.make_git_transfer_fixture()
			local win = open_live(f.file1).editable_win
			vim.cmd("botright vnew")
			local other = open_live(f.file2)
			assert(vim.wo[other.editable_win].diff and vim.wo[other.base_win].diff)
			-- Move the first view onto the buffer the second view owns.
			api.nvim_set_current_win(win)
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			ctx.wait_for(function()
				local s = state.for_window(win)
				return s and s.paused
			end, "shared buffer did not pause", 15000)
			assert(vim.wo[other.editable_win].diff, "pausing changed the other view")
			vim.cmd.edit(vim.fn.fnameescape(f.file1))
			ctx.wait_for(function()
				local s = state.for_window(win)
				return s and not s.paused and s.phase == "active"
			end, "paused view did not resume", 15000)
			settle()
			assert(state.get(other.editable_bufnr) == other and other.phase == "active")
			assert(vim.wo[other.editable_win].diff, "resuming turned off diff in the other view")
			assert(vim.wo[other.base_win].diff, "resuming turned off the other view's base diff")
			actions.close(state.for_window(win))
			actions.close(other)
		end,
	}
	local function lines(count, prefix)
		local out = {}
		for index = 1, count do
			out[index] = prefix .. " " .. index
		end
		return table.concat(out, "\n") .. "\n"
	end
	local function wait_paused(win)
		ctx.wait_for(function()
			local s = state.for_window(win)
			return s and s.paused
		end, "the view did not pause", 15000)
		return state.for_window(win)
	end
	-- A retry of the paused file survives window events while its base loads.
	for _, retry in ipairs({ "refresh", "write", "edit" }) do
		cases[#cases + 1] = {
			"test_live_diff_paused_retry_" .. retry .. "_survives_window_events",
			function()
				setup()
				local f = h.make_git_transfer_fixture()
				local root = h.tempdir()
				local outside = root .. "/outside.txt"
				h.write_file(outside, "outside\n")
				local win = open_live(f.file1).editable_win
				vim.cmd.edit(vim.fn.fnameescape(outside))
				wait_paused(win)
				-- The paused file becomes supported.
				h.exec({ "git", "init", "-q" }, root)
				h.exec({ "git", "config", "user.email", "test@example.com" }, root)
				h.exec({ "git", "config", "user.name", "Test" }, root)
				h.exec({ "git", "add", "outside.txt" }, root)
				h.exec({ "git", "commit", "-q", "-m", "outside" }, root)
				h.write_file(outside, "outside changed\n")
				api.nvim_set_current_win(win)
				local float
				if retry == "refresh" then
					vim.cmd("LazyVCS diff refresh")
				elseif retry == "write" then
					vim.cmd("silent write!")
				else
					vim.cmd("edit!")
				end
				if retry ~= "edit" then
					-- A notification float enters a buffer while the base loads.
					float = api.nvim_open_win(api.nvim_create_buf(false, true), false, {
						relative = "editor",
						row = 1,
						col = 1,
						width = 10,
						height = 1,
					})
				end
				ctx.wait_for(function()
					local s = state.for_window(win)
					return s and not s.paused and s.phase == "active"
				end, "the " .. retry .. " retry did not resume the view", 15000)
				assert(vim.wo[win].diff, "the resumed view is not in diff mode")
				if float and api.nvim_win_is_valid(float) then
					api.nvim_win_close(float, true)
				end
				actions.close(state.for_window(win))
			end,
		}
	end
	-- A paused view returning to its file keeps that file's cursor and view.
	cases[#cases + 1] = {
		"test_live_diff_paused_return_keeps_cursor_with_second_window",
		function()
			setup()
			local f = h.make_git_transfer_fixture()
			h.write_file(f.file2, lines(60, "beta"))
			local outside = h.tempdir() .. "/outside.txt"
			h.write_file(outside, lines(60, "outside"))
			local win = open_live(f.file1).editable_win
			-- The paused file is also open in another window, so leaving it keeps it visible.
			vim.cmd("botright split " .. vim.fn.fnameescape(outside))
			local other = api.nvim_get_current_win()
			api.nvim_set_current_win(win)
			vim.cmd.edit(vim.fn.fnameescape(outside))
			local paused = wait_paused(win)
			vim.fn.winrestview({ lnum = 10, col = 0, topline = 5 })
			vim.cmd("edit +40 " .. vim.fn.fnameescape(f.file2))
			interrupt(win, "loading")
			vim.cmd.edit(vim.fn.fnameescape(outside))
			local returned = vim.fn.winsaveview()
			assert(returned.lnum == 10, "Neovim did not restore the paused file's cursor")
			ctx.wait_for(function()
				return paused.phase == "paused" and not state.peek_pending_transfer(win)
			end, "the paused view did not settle", 3000)
			settle()
			local view = api.nvim_win_call(win, vim.fn.winsaveview)
			assert(
				view.lnum == 10 and view.topline == returned.topline,
				"returning moved the cursor: " .. vim.inspect(view)
			)
			api.nvim_win_close(other, true)
			actions.close(paused)
		end,
	}
	return cases
end
