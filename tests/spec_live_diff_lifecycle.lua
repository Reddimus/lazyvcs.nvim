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
					assert(restored.rhs == mapping.rhs, "detach lost original buffer mapping")
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
						api.nvim_set_current_win(win)
						vim.cmd("wincmd T")
						api.nvim_set_current_win(other)
					end
					local count = #api.nvim_tabpage_list_wins(other_tab)
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
					#messages == 1 and not messages[1]:find("\n"),
					"cleanup failure was not one single-line notification"
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
