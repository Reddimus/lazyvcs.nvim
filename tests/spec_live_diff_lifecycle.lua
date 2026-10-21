return function(ctx)
	local api, h = vim.api, ctx.helpers
	local state, actions = require("lazyvcs.state"), require("lazyvcs.actions")
	local backends, layout = require("lazyvcs.backends"), require("lazyvcs.layout")
	local function guarded(fn)
		return function()
			state, actions = require("lazyvcs.state"), require("lazyvcs.actions")
			backends, layout = require("lazyvcs.backends"), require("lazyvcs.layout")
			local load, open = backends.load_async, layout.open
			local hidden, notify, close = vim.o.hidden, require("lazyvcs.util").notify, layout.close
			local ok, err = xpcall(fn, debug.traceback)
			backends.load_async, layout.open = load, open
			require("lazyvcs.util").notify, layout.close = notify, close
			vim.o.hidden = true
			h.cleanup()
			vim.cmd("silent! tabonly!")
			vim.cmd("silent! only!")
			vim.o.hidden = hidden
			assert(ok, err)
		end
	end
	local function setup(svn)
		require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
		vim.o.hidden = true
		local f = svn and h.make_svn_transfer_fixture() or h.make_git_transfer_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		require("lazyvcs.util").editor_window(api.nvim_get_current_win())
		return f
	end
	local function hold()
		local load, callbacks = backends.load_async, {}
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_async = function(path, callback)
			return load(path, function(...)
				local args = { ... }
				callbacks[#callbacks + 1] = function()
					callback(unpack(args))
				end
			end)
		end
		return function()
			ctx.wait_for(function()
				return #callbacks > 0
			end, "backend completion was not held", 15000)
			backends.load_async = load
			return table.remove(callbacks, 1)
		end
	end
	local function opened()
		local buf = api.nvim_get_current_buf()
		actions.open()
		ctx.wait_for(function()
			return state.get(buf) ~= nil
		end, "live diff did not open", 15000)
		return assert(state.get(buf))
	end
	local function detaches(svn)
		for _, command in ipairs({ "edit", "bdelete", "bwipeout", "bunload" }) do
			for _, tracked in ipairs({ true, false }) do
				local f = setup(svn)
				local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
				vim.keymap.set("n", "q", ":echo 'original'<CR>", { buffer = buf })
				local mapping = api.nvim_buf_call(buf, function()
					return vim.fn.maparg("q", "n", false, true)
				end)
				local s = opened()
				local messages, notify = {}, require("lazyvcs.util").notify
				---@diagnostic disable-next-line: duplicate-set-field
				require("lazyvcs.util").notify = function(message)
					messages[#messages + 1] = message
				end
				local target
				if tracked then
					target = vim.fn.bufadd(f.file2)
					vim.fn.bufload(target)
				else
					target = api.nvim_create_buf(true, false)
				end
				if command == "edit" then
					vim.o.hidden = false
					if tracked then
						vim.cmd.edit(vim.fn.fnameescape(f.file2))
					else
						vim.cmd.enew()
					end
				else
					-- Remove the departed source before its scheduled transfer runs.
					vim.cmd.buffer(target)
					vim.cmd(command .. " " .. buf)
				end
				vim.o.hidden = true
				assert(#messages == 0, "detach reported cleanup error: " .. table.concat(messages, " | "))
				local settled = vim.wait(15000, function()
					local live = state.for_window(win)
					return live ~= s and (not tracked or (live and live.phase == "active"))
				end, 10)
				assert(settled, "detach did not reconcile " .. command .. ": " .. vim.inspect({
					tracked = tracked,
					target = target,
					displayed = api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win),
					phase = s.phase,
					messages = messages,
				}))
				require("lazyvcs.util").notify = notify
				assert(#messages == 0, "detach reported cleanup error: " .. table.concat(messages, " | "))
				if tracked then
					local live = assert(state.for_window(win))
					assert(
						live.editable_bufnr == target
							and live.base_win == s.base_win
							and live.base_bufnr == s.base_bufnr,
						"detach failed to reuse the original diff panes"
					)
					assert(vim.wo[win].diff and vim.wo[s.base_win].diff)
					actions.close(target)
				else
					assert(not api.nvim_win_is_valid(s.base_win), "detach left an orphaned base pane")
					assert(not api.nvim_buf_is_valid(s.base_bufnr), "detach retained base buffer")
				end
				if command ~= "bwipeout" then
					api.nvim_win_set_buf(win, buf)
					local restored = api.nvim_buf_call(buf, function()
						return vim.fn.maparg("q", "n", false, true)
					end)
					if command == "bdelete" then
						assert(next(restored) == nil, "native :bdelete should clear buffer mappings")
					else
						assert(restored.rhs == mapping.rhs, "detach lost original buffer mapping")
					end
					assert(not vim.wo[win].diff, "departed buffer retained diff mode after " .. command)
				end
				h.cleanup()
				vim.cmd("silent! only!")
			end
		end
	end
	local function delete_displayed(svn)
		for _, command in ipairs({ "bdelete", "bwipeout" }) do
			setup(svn)
			local s = opened()
			vim.cmd(command .. " " .. s.editable_bufnr)
			ctx.wait_for(function()
				return state.get(s.editable_bufnr) == nil
			end, "displayed source deletion retained its session")
			assert(not api.nvim_buf_is_valid(s.base_bufnr), "displayed source deletion retained its base")
			h.cleanup()
			vim.cmd("silent! only!")
		end
	end
	local cases = {
		{
			"test_live_diff_open_completion_refuses_pending_window_owner",
			function()
				local f = setup()
				vim.cmd.edit(vim.fn.fnameescape(f.file2))
				local release = hold()
				actions.open()
				local complete = release()
				vim.cmd.edit(vim.fn.fnameescape(f.file1))
				local s = opened()
				local finish_transfer = hold()
				vim.cmd.edit(vim.fn.fnameescape(f.file2))
				local target = api.nvim_get_current_buf()
				assert(state.for_window(s.editable_win) == s and not state.get(target))
				local messages = {}
				local util = require("lazyvcs.util")
				local notify = util.notify
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(message)
					messages[#messages + 1] = message
				end
				local ok, err = xpcall(function()
					-- This earlier open finishes in EW before the new transfer can commit.
					complete()
					assert(not state.get(target) and state.for_window(s.editable_win) == s)
					assert(#state.list() == 1 and #api.nvim_tabpage_list_wins(0) == 2)
					assert(#messages == 1 and messages[1]:find("owned by another buffer"))
					finish_transfer()()
					ctx.wait_for(function()
						local live = state.get(target)
						return live and live.phase == "active"
					end, "refused open stranded the window transfer")
					assert(state.get(target).base_win == s.base_win)
				end, debug.traceback)
				util.notify = notify
				pcall(actions.close, target)
				assert(ok, err)
			end,
		},
		{
			"test_live_diff_immediate_open_keeps_pending_transfer_owner",
			function()
				local f = setup()
				local other = f.root .. "/other.txt"
				h.write_file(other, "other base\n")
				h.exec({ "git", "add", "other.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "other" }, f.root)
				local s = opened()
				local release = hold()
				local load, builds = backends.load_async, 0
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_async = function(...)
					builds = builds + 1
					return load(...)
				end
				local target
				local ok, err = xpcall(function()
					vim.cmd.edit(vim.fn.fnameescape(other))
					target = api.nvim_get_current_buf()
					assert(state.for_window(s.editable_win) == s and not state.get(target))
					local before = builds
					assert(actions.open() == s, "open did not return the pending window owner")
					vim.cmd("LazyVCS diff open")
					assert(builds == before, "immediate open started a competing backend build")
					local complete = release()
					assert(builds == 1, "transfer did not own the only build")
					assert(actions.open() == s, "loading transfer lost its window owner")
					complete()
					ctx.wait_for(function()
						local live = state.get(target)
						return live and live.phase == "active"
					end, "pending transfer did not finish")
					local live = assert(state.get(target))
					assert(live.base_win == s.base_win and live.base_bufnr == s.base_bufnr)
					assert(#state.list() == 1 and #api.nvim_tabpage_list_wins(0) == 2)
				end, debug.traceback)
				backends.load_async = load
				if target then
					pcall(actions.close, target)
				end
				assert(ok, err)
			end,
		},
		{
			"test_live_diff_open_from_base_pane_focuses_editable_pane",
			function()
				setup()
				local s = opened()
				api.nvim_set_current_win(s.base_win)
				assert(actions.open() == s, "open from the base pane did not return its session")
				assert(
					api.nvim_get_current_win() == s.editable_win,
					"open from the base pane did not focus the editable pane"
				)
			end,
		},
		{
			"test_live_diff_registration_refuses_colliding_keys_atomically",
			function()
				setup()
				local s = opened()
				for _, key in ipairs({ "editable_bufnr", "base_bufnr", "editable_win", "base_win" }) do
					for _, owned in ipairs({ "editable", "base" }) do
						local candidate = { editable_bufnr = -1, base_bufnr = -2, editable_win = -3, base_win = -4 }
						local suffix = key:find("bufnr") and "_bufnr" or "_win"
						candidate[key] = s[owned .. suffix]
						local registered, err = state.register(candidate)
						assert(not registered and err, "registration accepted a colliding " .. key)
						assert(state.get(s.editable_bufnr) == s and state.get(s.base_bufnr) == s)
						assert(state.for_window(s.editable_win) == s and state.for_window(s.base_win) == s)
						assert(not state.get(-1) and not state.get(-2))
						assert(not state.for_window(-3) and not state.for_window(-4))
					end
				end
			end,
		},
		{
			"test_live_diff_unregister_preserves_new_window_owner",
			function()
				setup()
				local s = opened()
				local replacement = { editable_bufnr = -1 }
				local ok, err = xpcall(function()
					state.window_index[s.editable_win], state.window_index[s.base_win] = replacement, replacement
					state.unregister(s)
					assert(not state.get(s.editable_bufnr) and not state.get(s.base_bufnr))
					assert(state.for_window(s.editable_win) == replacement)
					assert(state.for_window(s.base_win) == replacement)
				end, debug.traceback)
				state.window_index[s.editable_win], state.window_index[s.base_win] = nil, nil
				assert(state.register(s))
				actions.close(s.editable_bufnr)
				assert(ok, err)
			end,
		},
		{
			"test_live_diff_queued_automatic_closes_skip_failed_closing_owner",
			function()
				for _, event in ipairs({ "base_window", "editable_window", "base_buffer", "rename" }) do
					local f = setup()
					local s = opened()
					local close, util = layout.close, require("lazyvcs.util")
					local notify, calls, messages = util.notify, 0, {}
					local ok, err = xpcall(function()
						---@diagnostic disable-next-line: duplicate-set-field
						layout.close = function()
							calls = calls + 1
							error("persistent cleanup failure")
						end
						---@diagnostic disable-next-line: duplicate-set-field
						util.notify = function(message)
							messages[#messages + 1] = message
						end
						-- Queue real lifecycle events before the failing close removes their autocmds.
						if event == "base_window" then
							api.nvim_win_close(s.base_win, true)
						elseif event == "editable_window" then
							api.nvim_win_close(s.editable_win, true)
						elseif event == "base_buffer" then
							api.nvim_buf_delete(s.base_bufnr, { force = true })
						else
							vim.cmd("file " .. vim.fn.fnameescape(f.root .. "/renamed.txt"))
						end
						actions.close(s.editable_bufnr)
						vim.wait(100, function()
							return false
						end, 10)
						assert(calls == 2 and #messages == 1, event .. " retried a closing owner")
						for _ = 1, 3 do
							vim.cmd.enew()
							vim.cmd.edit(vim.fn.fnameescape(f.file2))
							vim.cmd.tabnew()
							vim.cmd.tabclose()
							vim.wait(20, function()
								return false
							end, 10)
						end
						assert(calls == 2 and #messages == 1, "navigation repeated failed cleanup")
						actions.close(s.editable_bufnr)
						assert(calls == 3 and #messages == 2, "explicit retry did not report failure")
					end, debug.traceback)
					layout.close, util.notify = close, notify
					actions.close(s.editable_bufnr)
					ctx.wait_for(function()
						return not state.get(s.editable_bufnr)
					end, "automatic close spec stranded its session")
					assert(ok, err)
					h.cleanup()
					vim.cmd("silent! only!")
				end
			end,
		},
		{
			"test_live_diff_open_target_refuses_closing_buffer_in_other_tab",
			function()
				local f = setup()
				local s = opened()
				local close = layout.close
				---@diagnostic disable-next-line: duplicate-set-field
				layout.close = function()
					error("persistent cleanup failure")
				end
				vim.cmd.tabnew()
				local destination = api.nvim_get_current_win()
				local result = actions.open_target({
					backend = "git",
					kind = "git_worktree",
					path = f.file1,
					root = f.root,
					relpath = "alpha.txt",
					editable_side = "right",
					left = { label = "HEAD", lines = s.base_lines },
					right = { label = "WORKTREE", path = f.file1, modifiable = true },
				})
				assert(not result, "comparison replaced a buffer whose close is unfinished")
				assert(state.get(s.editable_bufnr) == s and state.for_window(s.base_win) == s)
				assert(not state.for_window(destination) and #api.nvim_tabpage_list_wins(0) == 1)
				layout.close = close
				ctx.wait_for(function()
					return not state.get(s.editable_bufnr)
				end, "blocked comparison stranded original cleanup")
				assert(not api.nvim_win_is_valid(s.base_win) and not api.nvim_buf_is_valid(s.base_bufnr))
			end,
		},
		{
			"test_live_diff_explicit_failed_close_reports_each_attempt",
			function()
				setup()
				local s = opened()
				local close, util = layout.close, require("lazyvcs.util")
				local notify = util.notify
				local calls, messages = 0, {}
				local ok, err = xpcall(function()
					---@diagnostic disable-next-line: duplicate-set-field
					layout.close = function()
						calls = calls + 1
						error("persistent cleanup failure")
					end
					---@diagnostic disable-next-line: duplicate-set-field
					util.notify = function(message)
						messages[#messages + 1] = message
					end
					actions.close(s.editable_bufnr)
					ctx.wait_for(function()
						return calls == 2
					end, "automatic close retry did not run")
					assert(#messages == 1, "automatic retry repeated cleanup notification")
					actions.close(s.editable_bufnr)
					assert(#messages == 2, "explicit failed close was silent")
					assert(state.current() == s and s.phase == "closing", "closing owner must remain discoverable")
					assert(actions.open({ silent = true }) == s)
					assert(#messages == 2, "silent open warned about closing window owner")
					actions.open()
					assert(#messages == 3 and messages[3]:find("cleanup is unfinished"), "blocked open was silent")
					vim.cmd.tabnew()
					assert(actions.open({ bufnr = s.editable_bufnr, silent = true }) == s)
					assert(#messages == 3, "silent open warned about closing buffer owner")
					actions.open({ bufnr = s.editable_bufnr })
					assert(
						#messages == 4 and messages[4]:find("cleanup is unfinished"),
						"closing buffer owner was silent"
					)
				end, debug.traceback)
				layout.close, util.notify = close, notify
				actions.close(s.editable_bufnr)
				ctx.wait_for(function()
					return state.get(s.editable_bufnr) == nil
				end, "explicit close spec stranded its session")
				assert(ok, err)
			end,
		},
		{
			"test_live_diff_reload_refreshes_without_another_edit",
			function()
				for _, command in ipairs({ "edit!", "checktime" }) do
					local f = setup()
					vim.bo.autoread = true
					local s = opened()
					h.write_file(f.file1, "reloaded replacement with different size\n")
					vim.cmd(command)
					assert(
						api.nvim_buf_get_lines(s.editable_bufnr, 0, 1, false)[1]:find("reloaded replacement"),
						"reload fixture did not reload"
					)
					ctx.wait_for(function()
						return s.current_text and s.current_text.lines[1] == "reloaded replacement with different size"
					end, command .. " left stale diff text")
					local expected = require("lazyvcs.diff").compute_text_hunks(s.base_text, s.current_text)
					assert(vim.deep_equal(s.hunks, expected), "reload left stale hunks")
					h.cleanup()
					vim.cmd("silent! only!")
				end
			end,
		},
		{
			"test_live_diff_cleanup_tolerates_wiped_buffer_and_closed_window",
			function()
				setup()
				local s = opened()
				local editor = require("lazyvcs.integrations.editor")
				local aerial = require("lazyvcs.integrations.aerial")
				local snapshot = editor.guard_markdown_buffer(s.editable_bufnr, "source.md")
				vim.cmd("belowright new")
				api.nvim_win_close(s.editable_win, true)
				api.nvim_buf_delete(s.editable_bufnr, { force = true })
				assert(not api.nvim_buf_is_valid(s.editable_bufnr) and not api.nvim_win_is_valid(s.editable_win))
				for _ = 1, 2 do
					require("lazyvcs.align").clear(s)
					assert(aerial.disable_buffer(s.editable_bufnr, { detach = true }) == nil)
					editor.restore_buffer(snapshot)
					require("lazyvcs.highlighting").release(s.editable_win)
				end
				ctx.wait_for(function()
					return not state.get(s.editable_bufnr)
				end, "wiped owner retained session")
				assert(
					not api.nvim_win_is_valid(s.base_win) and not api.nvim_buf_is_valid(s.base_bufnr),
					"invalid source aborted cleanup before base pane closed"
				)
			end,
		},

		{
			"test_live_diff_async_open_keeps_origin_and_completion_focus",
			function()
				for _, variant in ipairs({ "tab", "sibling", "closed", "replaced", "moved", "failure" }) do
					local f = setup()
					local win, buf, tab =
						api.nvim_get_current_win(), api.nvim_get_current_buf(), api.nvim_get_current_tabpage()
					local release = hold()
					local callback_focus
					actions.open({
						on_open = function()
							callback_focus = api.nvim_get_current_win()
						end,
					})
					local complete = release()
					if variant == "sibling" or variant == "closed" or variant == "moved" then
						vim.cmd.vsplit()
					else
						vim.cmd.tabnew()
					end
					vim.cmd.edit(vim.fn.fnameescape(f.file2))
					api.nvim_buf_set_lines(0, 0, 1, false, { "unsaved unrelated text" })
					local other, other_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
					local other_tab = api.nvim_get_current_tabpage()
					local view = api.nvim_win_call(other, vim.fn.winsaveview)
					local text = api.nvim_buf_get_lines(other_buf, 0, -1, false)
					if variant == "closed" then
						api.nvim_win_close(win, true)
					elseif variant == "replaced" then
						api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
					elseif variant == "moved" then
						vim.cmd.tabnew()
						api.nvim_win_set_config(win, { win = api.nvim_get_current_win(), split = "right" })
						assert(
							api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) ~= tab,
							"fixture must move the original handle to another tab"
						)
						api.nvim_set_current_win(other)
					end
					local count = #api.nvim_tabpage_list_wins(other_tab)
					local origin_count = api.nvim_tabpage_is_valid(tab) and #api.nvim_tabpage_list_wins(tab)
					local open = layout.open
					if variant == "failure" then
						---@diagnostic disable-next-line: duplicate-set-field
						layout.open = function(s)
							open(s)
							error("forced failure after split creation")
						end
					end
					complete()
					layout.open = open
					local s = state.get(buf)
					if variant == "tab" or variant == "sibling" then
						assert(s and s.editable_win == win, "async open replaced the completion-time window")
						assert(api.nvim_win_get_tabpage(s.base_win) == tab, "base opened outside originating tab")
						assert(callback_focus == other, "on_open ran before focus restoration")
					else
						assert(not s, "obsolete or failed destination installed a session")
						for _, candidate in ipairs(api.nvim_list_bufs()) do
							assert(
								not api.nvim_buf_get_name(candidate):match("^lazyvcs://"),
								"cancelled or failed open retained a base buffer"
							)
						end
						if variant == "failure" then
							assert(
								#api.nvim_tabpage_list_wins(tab) == origin_count,
								"failed open left a partial pane in the original tab"
							)
						end
					end
					assert(api.nvim_get_current_win() == other, "completion changed focus")
					assert(api.nvim_win_get_buf(other) == other_buf, "completion replaced unrelated buffer")
					assert(vim.deep_equal(api.nvim_buf_get_lines(other_buf, 0, -1, false), text))
					assert(vim.bo[other_buf].modified, "completion changed unrelated modified flag")
					assert(
						vim.deep_equal(api.nvim_win_call(other, vim.fn.winsaveview), view),
						"completion changed unrelated view"
					)
					local added = variant == "sibling" and 1 or 0
					assert(#api.nvim_tabpage_list_wins(other_tab) == count + added, "completion left a partial pane")
					h.cleanup()
					vim.cmd("silent! tabonly!")
					vim.cmd("silent! only!")
				end
			end,
		},
		{
			"test_live_diff_detach_reconciles_after_textlock",
			function()
				detaches(false)
				delete_displayed(false)
				local f = setup()
				local s = opened()
				local release = hold()
				vim.o.hidden = false
				vim.cmd.edit(vim.fn.fnameescape(f.file2))
				local obsolete = release()
				vim.cmd.edit(vim.fn.fnameescape(f.file1))
				ctx.wait_for(function()
					return s.phase == "active"
				end, "return to source did not restore its attachment")
				api.nvim_buf_set_lines(0, 0, 1, false, { "reattached edit" })
				ctx.wait_for(function()
					return s.current_text and s.current_text.lines[1] == "reattached edit"
				end, "unloaded source was not reattached")
				obsolete()
				assert(
					state.get(s.editable_bufnr) == s and s.phase == "active",
					"obsolete request replaced current session"
				)
			end,
		},
		{
			"test_svn_live_diff_nohidden_transfer",
			function()
				detaches(true)
				delete_displayed(true)
			end,
		},
		{
			"test_live_diff_failed_close_retains_cleanup_ownership",
			function()
				setup()
				local s = opened()
				local close, notify = layout.close, require("lazyvcs.util").notify
				local calls, messages = 0, {}
				---@diagnostic disable-next-line: duplicate-set-field
				layout.close = function(...)
					calls = calls + 1
					if calls == 1 then
						error("forced teardown failure\nsecond line")
					end
					return close(...)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				require("lazyvcs.util").notify = function(message)
					messages[#messages + 1] = message
				end
				actions.close(s.editable_bufnr)
				assert(state.get(s.editable_bufnr) == s, "failed close discarded cleanup ownership")
				actions.open({ bufnr = s.editable_bufnr })
				assert(state.get(s.editable_bufnr) == s, "open replaced an unfinished close")
				ctx.wait_for(function()
					return state.get(s.editable_bufnr) == nil
				end, "scheduled retry did not finish cleanup")
				assert(calls == 2 and not api.nvim_win_is_valid(s.base_win), "failed close left a base pane")
				assert(
					#messages == 2 and not messages[1]:find("\n") and messages[2]:find("cleanup is unfinished"),
					"failed close or blocked open did not notify"
				)
				layout.close, require("lazyvcs.util").notify = close, notify
				-- A later explicit close can finish a persistent failure without closing a new owner.
				setup()
				s = opened()
				---@diagnostic disable-next-line: duplicate-set-field
				layout.close = function()
					error("persistent teardown failure")
				end
				actions.close(s.editable_bufnr)
				vim.wait(50, function()
					return false
				end)
				assert(state.get(s.editable_bufnr) == s, "persistent failure lost its session")
				local replacement = api.nvim_create_buf(true, false)
				api.nvim_win_call(s.base_win, function()
					vim.cmd.split()
				end)
				api.nvim_win_set_buf(s.base_win, replacement)
				layout.close = close
				actions.close(s.editable_bufnr)
				assert(
					not state.get(s.editable_bufnr) and api.nvim_win_is_valid(s.base_win),
					"retry closed replacement window"
				)
				assert(api.nvim_win_get_buf(s.base_win) == replacement)
			end,
		},
	}
	for _, case in ipairs(cases) do
		case[2] = guarded(case[2])
	end
	return cases
end
