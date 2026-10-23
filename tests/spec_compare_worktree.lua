return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare = require("lazyvcs.compare")
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result and not s.preview_job and not s.job
		end, "editable Compare did not load", 15000)
	end
	local function fixture(vcs, opts)
		require("lazyvcs").setup(vim.tbl_deep_extend("force", {
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
		}, opts or {}))
		local f = vcs == "svn" and h.make_svn_fixture() or h.make_git_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		local original = api.nvim_get_current_buf()
		local base = vcs == "svn" and h.file_url(f.repo) .. "@1" or "HEAD"
		local s = assert(compare.open({ path = f.root, base = base }))
		ready(s)
		return f, s, original
	end
	local cases = {}
	for _, vcs in ipairs({ "git", "svn" }) do
		cases[#cases + 1] = {
			"test_" .. vcs .. "_compare_worktree_reuses_real_buffer_and_updates_hunks",
			function()
				local _, s, original = fixture(vcs)
				assert(s.right == original, "Compare did not reuse the real buffer")
				assert(vim.bo[s.right].buftype == "" and vim.bo[s.right].modifiable)
				assert(not vim.bo[s.left].modifiable and vim.bo[s.left].readonly)
				api.nvim_set_current_win(s.rightwin)
				api.nvim_buf_set_lines(original, 0, -1, false, { "unsaved first", "unsaved second" })
				api.nvim_exec_autocmds("TextChanged", { buffer = original })
				ctx.wait_for(function()
					return s.preview_result.right[1] == "unsaved first" and #s.navigation.saved > 0
				end, "Compare navigation retained saved text", 15000)
				assert(#s.navigation.saved > 0)
				compare.close(s)
				assert(api.nvim_buf_is_valid(original) and vim.bo[original].modified)
				assert(api.nvim_buf_get_lines(original, 0, 1, false)[1] == "unsaved first")
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_worktree_shared_live_diff_and_editor_keep_focus_controls",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local f = h.make_git_fixture()
			vim.cmd.edit(f.file)
			local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
			actions.open()
			ctx.wait_for(function()
				return state.current() ~= nil
			end, "live source", 15000)
			local live = assert(state.current())
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			api.nvim_set_current_win(s.rightwin)
			assert(s.right == live.editable_bufnr and state.current() == nil)
			assert(vim.fn.maparg("q", "n") == "", "live close key leaked into Compare")
			assert(vim.fn.maparg("]b", "n") ~= "")
			assert(actions.close() == false and state.owns(live))
			api.nvim_set_current_win(live.editable_win)
			assert(state.current() == live and vim.fn.maparg("q", "n") ~= "")
			compare.close(s)
			assert(state.owns(live) and vim.wo[live.editable_win].diff)
			actions.close(live)
		end,
	}
	for _, mode in ipairs({ "clean", "dirty", "saved", "adopted" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_private_buffer_lifetime_" .. mode,
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/a.txt", "first\n")
				h.write_file(f.root .. "/b.txt", "second\n")
				vim.cmd.edit(f.file)
				local hidden = vim.o.hidden
				vim.o.hidden = false
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ready(s)
				assert(s.shown_item.relpath == "a.txt")
				local buf = s.right
				assert(vim.bo[buf].buftype == "" and not vim.bo[buf].buflisted)
				api.nvim_set_current_win(s.rightwin)
				if mode == "dirty" or mode == "saved" then
					api.nvim_buf_set_lines(buf, 0, -1, false, { "keep my edit" })
					api.nvim_exec_autocmds("BufModifiedSet", { buffer = buf })
					if mode == "saved" then
						vim.cmd.write()
					end
				elseif mode == "adopted" then
					vim.bo[buf].buflisted = true
					api.nvim_exec_autocmds("OptionSet", { pattern = "buflisted" })
					vim.bo[buf].buflisted = false
				end
				compare.navigate_file("next", 1)
				ctx.wait_for(function()
					return s.shown_item.relpath == "b.txt" and s.worktree ~= nil
				end, "next file", 15000)
				if mode == "clean" then
					assert(not api.nvim_buf_is_valid(buf), "private clean buffer was retained")
				else
					assert(api.nvim_buf_is_valid(buf), "user-owned buffer was deleted")
					assert(vim.bo[buf].modified == (mode == "dirty"))
				end
				compare.close(s)
				vim.o.hidden = hidden
			end,
		}
	end
	-- Batched commands finish before change autocmds run, so the buffer can
	-- already look clean when Compare releases it.
	for name, keys in pairs({ write = ":%s/first/subst/ | write<CR>", undo = "ccreplaced<Esc>u" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_batched_" .. name .. "_keeps_private_buffer",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/a.txt", "first\n")
				h.write_file(f.root .. "/b.txt", "second\n")
				vim.cmd.edit(f.file)
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ready(s)
				local buf = s.right
				assert(s.shown_item.relpath == "a.txt" and not vim.bo[buf].buflisted)
				api.nvim_set_current_win(s.rightwin)
				api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
				assert(not vim.bo[buf].modified)
				local undo = vim.fn.undotree(buf).seq_last
				assert(undo > 0)
				vim.wait(50)
				assert(vim.bo[buf].buflisted, "edited private buffer stayed unlisted")
				-- Listing follows the edit once; an explicit unlist stays.
				vim.bo[buf].buflisted = false
				vim.wait(50)
				assert(not vim.bo[buf].buflisted, "Compare listed the buffer again")
				compare.navigate_file("next", 1)
				ctx.wait_for(function()
					return s.shown_item.relpath == "b.txt" and s.worktree ~= nil
				end, "next file", 15000)
				assert(api.nvim_buf_is_valid(buf), "edited private buffer was deleted")
				assert(vim.fn.undotree(buf).seq_last == undo, "edited private buffer lost undo history")
				local disk = vim.fn.readfile(f.root .. "/a.txt")[1]
				assert(disk == (name == "write" and "subst" or "first"), disk)
				compare.close(s)
				assert(api.nvim_buf_is_valid(buf), "closing Compare deleted the edited buffer")
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_worktree_reread_keeps_private_buffer_private",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local f = h.make_git_fixture()
			h.write_file(f.root .. "/a.txt", "first\n")
			h.write_file(f.root .. "/b.txt", "second\n")
			vim.cmd.edit(f.file)
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			local buf = s.right
			assert(s.shown_item.relpath == "a.txt" and not vim.bo[buf].buflisted)
			local autoread = vim.o.autoread
			vim.o.autoread = true
			-- Another program rewrites the untouched file; :checktime rereads it in place.
			h.write_file(f.root .. "/a.txt", "first\nexternal change\n")
			vim.cmd.checktime(buf)
			vim.o.autoread = autoread
			assert(api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "external change", "checktime did not reread")
			-- The main loop reports the reread as a text change.
			api.nvim_exec_autocmds("TextChanged", { buffer = buf })
			vim.wait(50)
			api.nvim_exec_autocmds("TextChanged", { buffer = buf })
			assert(not vim.bo[buf].buflisted, "rereading listed the private buffer")
			compare.navigate_file("next", 1)
			ctx.wait_for(function()
				return s.shown_item.relpath == "b.txt" and s.worktree ~= nil
			end, "next file", 15000)
			assert(not api.nvim_buf_is_valid(buf), "rereading retained the private buffer")
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_reread_then_edit_keeps_undo",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local f = h.make_git_fixture()
			h.write_file(f.root .. "/a.txt", "first\n")
			h.write_file(f.root .. "/b.txt", "second\n")
			vim.cmd.edit(f.file)
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			local buf = s.right
			assert(s.shown_item.relpath == "a.txt" and not vim.bo[buf].buflisted)
			local autoread = vim.o.autoread
			vim.o.autoread = true
			h.write_file(f.root .. "/a.txt", "first\nexternal change\n")
			api.nvim_set_current_win(s.rightwin)
			-- One macro rereads the file, then edits and undoes before Compare settles.
			api.nvim_feedkeys(
				api.nvim_replace_termcodes(":checktime<CR>ccreplaced<Esc>u", true, false, true),
				"xt",
				false
			)
			vim.o.autoread = autoread
			assert(api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "external change", "checktime did not reread")
			assert(not vim.bo[buf].modified)
			local undo = vim.fn.undotree(buf).seq_last
			compare.navigate_file("next", 1)
			ctx.wait_for(function()
				return s.shown_item.relpath == "b.txt" and s.worktree ~= nil
			end, "next file", 15000)
			assert(api.nvim_buf_is_valid(buf), "the edit after rereading was discarded with its undo history")
			assert(vim.fn.undotree(buf).seq_last == undo, "the buffer lost undo history")
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_edit_then_reread_keeps_undo",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local f = h.make_git_fixture()
			h.write_file(f.root .. "/a.txt", "first\n")
			h.write_file(f.root .. "/b.txt", "second\n")
			vim.cmd.edit(f.file)
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			local buf = s.right
			assert(s.shown_item.relpath == "a.txt" and not vim.bo[buf].buflisted)
			local autoread = vim.o.autoread
			vim.o.autoread = true
			h.write_file(f.root .. "/a.txt", "first\nexternal change\n")
			api.nvim_set_current_win(s.rightwin)
			-- One mapping edits and undoes, then rereads before Compare observes the edit.
			api.nvim_feedkeys(api.nvim_replace_termcodes("ccx<Esc>u:checktime<CR>", true, false, true), "xt", false)
			vim.o.autoread = autoread
			assert(api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "external change", "checktime did not reread")
			assert(not vim.bo[buf].modified)
			local undo = vim.fn.undotree(buf).seq_last
			compare.navigate_file("next", 1)
			ctx.wait_for(function()
				return s.shown_item.relpath == "b.txt" and s.worktree ~= nil
			end, "next file", 15000)
			assert(api.nvim_buf_is_valid(buf), "the edit before rereading was discarded with its undo history")
			assert(vim.fn.undotree(buf).seq_last == undo, "the buffer lost undo history")
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_snapshot_opt_out",
		function()
			local _, s, original = fixture("git", { compare = { editable = false } })
			assert(s.right ~= original and not vim.bo[s.right].modifiable)
			require("lazyvcs").compare_action("help")
			assert(
				table
					.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
					:find("both panes are read-only snapshots", 1, true)
			)
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_deletion_stays_snapshot_until_reselected",
		function()
			local _, s, original = fixture("git")
			assert(s.right == original)
			api.nvim_buf_delete(original, { force = true })
			ctx.wait_for(function()
				return not s.closed and s.right ~= original and not vim.bo[s.right].modifiable
			end, "deleted worktree buffer did not fall back", 15000)
			api.nvim_set_current_win(s.rightwin)
			api.nvim_set_current_win(s.sidewin)
			vim.wait(100)
			assert(not vim.bo[s.right].modifiable and not s.closed)
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_deleted_closed_pane_recovers_its_snapshot",
		function()
			local _, s, original = fixture("git")
			local rightwin = s.rightwin
			local notices, util = {}, require("lazyvcs.util")
			local notify = util.notify
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function(message)
				notices[#notices + 1] = message
			end
			local ok, err = xpcall(function()
				-- Native deletion can close the owned pane before BufUnload. Keep
				-- this ordering deterministic without depending on alternate buffers.
				api.nvim_win_close(rightwin, true)
				api.nvim_buf_delete(original, { force = true })
				ctx.wait_for(function()
					return not s.closed
						and s.rightwin ~= rightwin
						and api.nvim_win_is_valid(s.rightwin)
						and not s.worktree
						and not vim.bo[s.right].modifiable
				end, "closed pane did not recover deleted working buffer", 15000)
				ready(s)
				assert(#notices == 0, vim.inspect(notices))
				assert(s.preview_result.right[2] == "changed")
			end, debug.traceback)
			util.notify = notify
			assert(ok, err)
			compare.close(s)
		end,
	}
	for _, side in ipairs({ "base", "working" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_symlink_" .. side .. "_retains_snapshot",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/target.txt", "target must remain intact\n")
				assert(vim.uv.fs_unlink(f.file))
				assert(vim.uv.fs_symlink("target.txt", f.file))
				if side == "base" then
					h.exec({ "git", "add", "sample.txt" }, f.root)
					h.exec({ "git", "commit", "-m", "link base" }, f.root)
					assert(vim.uv.fs_unlink(f.file))
					h.write_file(f.file, "regular working replacement\n")
				end
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ready(s)
				assert(s.shown_item.relpath == "sample.txt")
				assert(not s.worktree and not vim.bo[s.right].modifiable)
				assert(vim.fn.readfile(f.root .. "/target.txt")[1] == "target must remain intact")
				compare.close(s)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_worktree_rename_preserves_user_buffer_and_pinned_snapshot",
		function()
			local f, s, original = fixture("git")
			api.nvim_set_current_win(s.rightwin)
			vim.cmd.file(vim.fn.fnameescape(f.root .. "/renamed.txt"))
			ctx.wait_for(function()
				return s.worktree == nil and s.right ~= original
			end, "rename did not fall back", 15000)
			assert(api.nvim_buf_is_valid(original) and not vim.bo[s.right].modifiable)
			assert(api.nvim_buf_get_name(original):match("renamed.txt$"))
			compare.close(s)
		end,
	}
	cases[#cases + 1] = {
		"test_core_compare_worktree_released_buffer_stops_edit_work_and_can_reopen",
		function()
			local f, s, original = fixture("git")
			compare.close(s)
			vim.wait(100)
			local schedule, calls = vim.schedule, 0
			---@diagnostic disable-next-line: duplicate-set-field
			vim.schedule = function(callback)
				calls = calls + 1
				return schedule(callback)
			end
			local ok, err = pcall(api.nvim_buf_set_lines, original, 0, 1, false, { "edit after close" })
			vim.schedule = schedule
			assert(ok, err)
			assert(calls == 0, "closed Compare still scheduled edit work")
			s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			assert(s.right == original)
			api.nvim_buf_set_lines(original, 0, 1, false, { "edit after reopen" })
			ctx.wait_for(function()
				return s.preview_result.right[1] == "edit after reopen" and #s.navigation.saved > 0
			end, "reopened buffer did not reattach", 15000)
			compare.close(s)
		end,
	}
	for _, command in ipairs({ "edit!", "edit ++ff=dos", "edit ++enc=latin1", "unlist", "save_delete" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_lifecycle_" .. command:gsub("[^%w]", "_"),
			function()
				local _, s, original = fixture("git")
				api.nvim_set_current_win(s.rightwin)
				if command == "unlist" then
					vim.bo[original].buflisted = false
				elseif command == "save_delete" then
					api.nvim_buf_set_lines(original, 0, 1, false, { "latest saved content" })
					vim.cmd.write()
					api.nvim_buf_delete(original, { force = true })
				else
					vim.cmd(command)
				end
				vim.wait(100)
				if command == "save_delete" then
					ctx.wait_for(function()
						return s.preview_result
							and s.preview_result.right[1] == "latest saved content"
							and not s.worktree
					end, "fallback retained content from before the save", 15000)
					api.nvim_set_current_win(s.sidewin)
					s.actions.review()
					ctx.wait_for(function()
						return s.worktree ~= nil and s.preview_job == nil
					end, "refreshed row could not reactivate working file", 15000)
				else
					ctx.wait_for(function()
						return s.worktree and s.right == original
					end, "reload/unlist lost real buffer", 15000)
					assert(not s.worktree_deleted)
				end
				compare.close(s)
			end,
		}
	end

	for _, command in ipairs({ "close", "bdelete", "bwipeout" }) do
		cases[#cases + 1] = {
			"test_core_compare_worktree_private_nohidden_" .. command,
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/a.txt", "private\n")
				vim.cmd.edit(f.file)
				local hidden = vim.o.hidden
				vim.o.hidden = false
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ready(s)
				local original = s.right
				assert(not vim.bo[original].buflisted and vim.bo[original].bufhidden == "hide")
				api.nvim_set_current_win(s.rightwin)
				vim.cmd(command)
				if command == "close" then
					ctx.wait_for(function()
						return s.closed
					end, "ordinary close was resurrected", 15000)
				else
					ctx.wait_for(function()
						return not s.closed
							and api.nvim_win_is_valid(s.rightwin)
							and s.preview_result
							and not s.preview_job
							and not s.worktree
					end, "explicit deletion did not recover a snapshot", 15000)
					assert(not vim.bo[s.right].modifiable)
					compare.close(s)
				end
				vim.o.hidden = hidden
			end,
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_worktree_exact_ownership_and_shared_hide_lease",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local f = h.make_git_fixture()
			h.write_file(f.root .. "/a.txt", "new private\n")
			vim.fn.bufadd(f.root .. "/a.txt.orig")
			vim.cmd.edit(f.file)
			local s = assert(compare.open({ path = f.root, base = "HEAD" }))
			ready(s)
			local private = s.right
			assert(not s.worktree.retained, "partial filename match adopted new buffer")
			compare.close(s)
			assert(not api.nvim_buf_is_valid(private), "private buffer leaked")
			local manager = require("lazyvcs.compare_worktree")
			local original = vim.fn.bufadd(f.file)
			vim.fn.bufload(original)
			vim.bo[original].bufhidden = ""
			local one, two = { editable = true, root = f.root }, { editable = true, root = f.root }
			local item, result = { relpath = "sample.txt" }, { left_kind = "regular" }
			local a = assert(manager.acquire(one, item, result, function() end))
			local b = assert(manager.acquire(two, item, result, function() end))
			assert(a == b and vim.bo[original].bufhidden == "hide")
			manager.release(one, a)
			assert(vim.bo[original].bufhidden == "hide")
			manager.release(two, b)
			assert(vim.bo[original].bufhidden == "", "last owner did not restore option")
		end,
	}
	cases[#cases + 1] = {
		"test_live_diff_implicit_close_does_not_close_shared_source_in_other_window",
		function()
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			local f = h.make_git_fixture()
			vim.cmd.edit(f.file)
			local actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
			actions.open()
			ctx.wait_for(function()
				return state.current() ~= nil
			end, "live view", 15000)
			local live = state.current()
			vim.cmd("tab split")
			assert(state.current() == nil)
			actions.close()
			assert(state.owns(live), "ordinary window closed another view")
			assert(actions.rebalance(-1) == false)
			actions.close(live)
		end,
	}

	cases[#cases + 1] = {
		"test_core_compare_worktree_replaced_pane_then_deleted_buffer_recovers",
		function()
			local _, s, original = fixture("git")
			local alternate = api.nvim_create_buf(true, false)
			vim.bo[alternate].bufhidden = "wipe"
			api.nvim_set_current_win(s.rightwin)
			api.nvim_win_set_buf(s.rightwin, alternate)
			-- The alternate's own window options, which Compare never set.
			local util = require("lazyvcs.util")
			util.set_win_options(s.rightwin, { winbar = "MINE", scrollbind = true, cursorbind = true })
			api.nvim_buf_delete(original, { force = true })
			ctx.wait_for(function()
				return not s.closed
					and s.preview_result
					and not s.preview_job
					and not s.worktree
					and api.nvim_buf_is_valid(s.right)
					and not vim.bo[s.right].modifiable
			end, "replacement pane blocked deletion reconciliation", 15000)
			assert(
				api.nvim_buf_is_valid(alternate) and vim.bo[alternate].bufhidden == "wipe",
				"recovery deleted an external alternate"
			)
			compare.close(s)
			-- Neovim saved the alternate's options when the pane left it.
			vim.cmd("tabnew")
			vim.cmd.buffer(alternate)
			local values = util.capture_win_options(0, { "winbar", "scrollbind", "cursorbind" })
			assert(
				values.winbar == "MINE" and values.scrollbind and values.cursorbind,
				"recovery reset the alternate's options: " .. vim.inspect(values)
			)
			vim.cmd("tabclose")
		end,
	}
	return cases
end
