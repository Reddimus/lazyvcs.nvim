return function(ctx)
	local s = require("signs_helpers")(ctx)
	local function attach(buf, reset)
		package.loaded.gitsigns = {
			get_hunks = function(target)
				return target == buf
						and {
							{
								removed = { start = 2, count = 1, lines = { "two" } },
								added = { start = 2, count = 1, lines = { "changed" } },
							},
						}
					or nil
			end,
			reset_hunk = reset,
		}
		s.signs.refresh(buf, false)
		s.api.nvim_win_set_cursor(0, { 2, 0 })
	end
	local function wait_for_refresh(no_refresh_api, second_revert)
		local f, buf = s.fixture(false, {
			use_gitsigns = true,
			signs = { max_file_bytes = 1 },
			source_control = { confirm_mutations = true },
		})
		local pending = { buf = buf, resets = 0, refreshes = 0 }
		attach(buf, function()
			pending.resets = pending.resets + 1
			local hunks = assert(package.loaded.gitsigns.get_hunks(buf))
			s.api.nvim_buf_set_lines(buf, 1, 2, false, hunks[1].removed.lines)
		end)
		local hunks = assert(package.loaded.gitsigns.get_hunks(buf))
		---@diagnostic disable-next-line: duplicate-set-field
		package.loaded.gitsigns.get_hunks = function(target)
			return target == buf and hunks or nil
		end
		if not no_refresh_api then
			package.loaded.gitsigns.refresh = function()
				pending.refreshes = pending.refreshes + 1
			end
		end
		local change = s.signs.begin_base_change(f.root, { f.file })
		vim.cmd("LazyVCS hunk revert")
		s.wait(function()
			return (s.signs.current_state(buf).native_holds or 0) == 1
		end, "revert did not wait for base settlement")
		if second_revert then
			vim.cmd("LazyVCS hunk revert")
		end
		s.h.write_file(f.file, "one\nstaged\nthree\n")
		s.h.exec({ "git", "add", "sample.txt" }, f.root)
		s.signs.finish_base_change(change)
		if not no_refresh_api then
			s.wait(function()
				return pending.refreshes == 1
			end, "base settlement did not request gitsigns refresh")
		end
		function pending.publish(target)
			if target == buf then
				hunks[1].removed.lines = { "staged" }
			end
			s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = target } })
		end
		function pending.confirmation()
			return vim.fn.maparg("1", "n", false, true).callback
		end
		return pending
	end
	return {
		{
			"test_signs_oversized_cleanup_preserves_delegated_freshness",
			s.guard(function()
				local f, buf = s.fixture(false, { use_gitsigns = true, signs = { max_file_bytes = 64 } })
				s.refresh(buf, true)
				assert(#s.marks(buf) > 0)
				attach(buf, function() end)
				local change = s.signs.begin_base_change(f.root, { f.file })
				s.signs.finish_base_change(change)
				s.edit(buf, { "one", string.rep("x", 80), "three" })
				s.signs.refresh(buf, false)
				local state = assert(s.signs.current_state(buf))
				assert(state.skipped, "oversized delegated state was not marked skipped")
				assert(not state.base_text and not state.current_text and not state.decorated_hunks)
				assert(#s.marks(buf) == 0 and state.gitsigns_refresh_needed, "cleanup lost settlement freshness")
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return state.gitsigns_waiters and next(state.gitsigns_waiters) ~= nil
				end, "large revert bypassed freshness wait")
				s.api.nvim_buf_delete(buf, { force = true })
				assert((state.native_holds or 0) == 0 and not state.large_revert_pending)
			end),
		},
		{
			"test_signs_detach_during_confirmation_resumes_native_gutter",
			s.guard(function()
				for _, choice in ipairs({ "1", "3" }) do
					local _, buf = s.fixture(false, {
						use_gitsigns = true,
						source_control = { confirm_mutations = true },
					})
					s.refresh(buf, true)
					local resets = 0
					attach(buf, function()
						resets = resets + 1
					end)
					vim.cmd("LazyVCS hunk revert")
					s.wait(function()
						return type(vim.fn.maparg(choice, "n", false, true).callback) == "function"
					end, "confirmation absent", 15000)
					-- Detach publishes an update before dropping its cached hunks.
					s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
					---@diagnostic disable-next-line: duplicate-set-field
					package.loaded.gitsigns.get_hunks = function()
						return nil
					end
					vim.fn.maparg(choice, "n", false, true).callback()
					s.wait(function()
						return (s.signs.current_state(buf).native_holds or 0) == 0
					end, "confirmation hold was not released", 15000)
					-- A reset error would be contained, so count calls instead of raising.
					assert(resets == 0, "detached gitsigns was invoked")
					if choice == "1" then
						assert(
							s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two",
							"confirmed revert was not applied natively"
						)
					end
					s.edit(buf, { "one", "edited after detach", "three" })
					s.wait(function()
						return #s.marks(buf) > 0
					end, "detached confirmation suppressed native signs")
					assert(not s.signs.current_state(buf).delegate_after_command)
				end
			end),
		},
		{
			"test_signs_confirmation_dismissals_release_command_ownership",
			s.guard(function()
				for _, large in ipairs({ false, true }) do
					for _, dismissal in ipairs({ "q", "<Esc>", "window", "buffer" }) do
						local _, buf = s.fixture(false, {
							use_gitsigns = true,
							signs = { max_file_bytes = large and 1 or 1024 },
							source_control = { confirm_mutations = true },
						})
						local resets = 0
						attach(buf, function()
							resets = resets + 1
						end)
						vim.cmd("LazyVCS hunk revert")
						s.wait(function()
							return type(vim.fn.maparg("1", "n", false, true).callback) == "function"
						end, "confirmation absent", 15000)
						local state = s.signs.current_state(buf)
						if dismissal == "window" then
							s.api.nvim_win_close(0, true)
						elseif dismissal == "buffer" then
							s.api.nvim_buf_delete(0, { force = true })
						else
							vim.fn.maparg(dismissal, "n", false, true).callback()
						end
						s.wait(function()
							return (state.native_holds or 0) == 0
						end, "dismissal stranded hold")
						assert(not state.large_revert_pending and resets == 0)
						vim.cmd("LazyVCS hunk revert")
						s.wait(function()
							return type(vim.fn.maparg("3", "n", false, true).callback) == "function"
						end, "dismissal blocked the next revert", 15000)
						vim.fn.maparg("3", "n", false, true).callback()
					end
				end
			end),
		},
		{
			"test_signs_old_large_revert_release_preserves_new_command",
			s.guard(function()
				local _, buf = s.fixture(false, {
					use_gitsigns = true,
					signs = { max_file_bytes = 1 },
					source_control = { confirm_mutations = true },
				})
				attach(buf, function() end)
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return type(vim.fn.maparg("3", "n", false, true).callback) == "function"
				end, "first confirmation absent", 15000)
				local state = s.signs.current_state(buf)
				local old_release = assert(state.large_revert_pending)
				vim.fn.maparg("3", "n", false, true).callback()
				vim.cmd("LazyVCS hunk revert")
				local new_release = assert(state.large_revert_pending)
				old_release()
				assert(state.large_revert_pending == new_release, "old release cleared a newer command")
				assert(state.native_holds == 1)
				vim.fn.maparg("3", "n", false, true).callback()
			end),
		},
		{
			"test_signs_large_file_second_waiting_revert_is_rejected",
			s.guard(function()
				local notices = {}
				vim.notify = function(message)
					if message:find("already pending", 1, true) then
						notices[#notices + 1] = message
					end
				end
				local pending = wait_for_refresh(false, true)
				vim.cmd("LazyVCS hunk revert")
				assert(#notices == 2, "second reverts must report the pending command in both wait phases")
				assert((s.signs.current_state(pending.buf).native_holds or 0) == 1)
				pending.publish(pending.buf)
				s.wait(function()
					return type(pending.confirmation()) == "function"
				end, "first revert was orphaned")
				pending.confirmation()()
				s.wait(function()
					return s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "staged"
				end, "first revert never completed")
				assert((s.signs.current_state(pending.buf).native_holds or 0) == 0)
			end),
		},
		{
			"test_signs_recent_settlement_waits_for_buffer_update",
			s.guard(function()
				for _, large in ipairs({ true, false }) do
					local f, buf = s.fixture(false, {
						use_gitsigns = true,
						signs = { max_file_bytes = large and 1 or 1024 },
						source_control = { confirm_mutations = true },
					})
					local resets, refreshes = 0, 0
					attach(buf, function()
						resets = resets + 1
						s.api.nvim_buf_set_lines(buf, 1, 2, false, { "staged" })
					end)
					local hunks = assert(package.loaded.gitsigns.get_hunks(buf))
					---@diagnostic disable-next-line: duplicate-set-field
					package.loaded.gitsigns.get_hunks = function(target)
						return target == buf and hunks or nil
					end
					package.loaded.gitsigns.refresh = function()
						refreshes = refreshes + 1
					end
					local change = s.signs.begin_base_change(f.root, { f.file })
					s.h.write_file(f.file, "one\nstaged\nthree\n")
					s.h.exec({ "git", "add", "sample.txt" }, f.root)
					s.signs.finish_base_change(change)
					-- An automatic refresh between settlement and command must retain the mark.
					s.signs.refresh(buf, false)
					vim.cmd("LazyVCS hunk revert")
					s.wait(function()
						return refreshes == 1 or type(vim.fn.maparg("1", "n", false, true).callback) == "function"
					end, "recent settlement command did not start", 15000)
					if large then
						assert(refreshes == 1, "recent settlement consumed stale gitsigns hunks")
						assert(type(vim.fn.maparg("1", "n", false, true).callback) ~= "function")
						local other = s.api.nvim_create_buf(false, true)
						s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = other } })
						assert(type(vim.fn.maparg("1", "n", false, true).callback) ~= "function")
						s.api.nvim_buf_delete(other, { force = true })
						hunks[1].removed.lines = { "staged" }
						s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
						s.wait(function()
							return type(vim.fn.maparg("1", "n", false, true).callback) == "function"
						end, "matching update did not open confirmation")
					else
						assert(refreshes == 0, "native revert waited for gitsigns freshness")
					end
					assert(#s.marks(buf) == 0)
					vim.fn.maparg("1", "n", false, true).callback()
					s.wait(function()
						return s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "staged"
					end, "matching refreshed hunk did not delegate", 15000)
					assert(s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "staged")
					-- Once the update arrives, a later revert does not wait again.
					s.api.nvim_buf_set_lines(buf, 1, 2, false, { "changed" })
					vim.cmd("LazyVCS hunk revert")
					s.wait(function()
						return type(vim.fn.maparg("1", "n", false, true).callback) == "function"
					end, "settlement mark was not cleared", 15000)
					assert(refreshes == (large and 1 or 0))
					vim.fn.maparg("3", "n", false, true).callback()
				end
			end),
		},
		{
			"test_signs_refresh_callbacks_contain_errors",
			s.guard(function()
				local confirm = require("lazyvcs.source_control.confirm")
				local mutation = confirm.mutation
				local pending = wait_for_refresh()
				local notices = {}
				vim.notify = function(message)
					notices[#notices + 1] = message
				end
				---@diagnostic disable-next-line: duplicate-set-field
				confirm.mutation = function()
					error("confirmation UI failed")
				end
				local ok, err = pcall(pending.publish, pending.buf)
				confirm.mutation = mutation
				assert(ok, "error escaped into gitsigns: " .. tostring(err))
				assert(#notices == 1 and notices[1]:find("confirmation UI failed", 1, true))
				assert((s.signs.current_state(pending.buf).native_holds or 0) == 0)
			end),
		},
		{
			"test_signs_refresh_timeout_callback_contains_errors",
			s.guard(function()
				local new_timer, timeout = vim.uv.new_timer, nil
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.new_timer = function()
					local timer = assert(new_timer())
					return {
						start = function(_, ms, repeat_ms, callback)
							if ms == 2000 then
								timeout = callback
							else
								timer:start(ms, repeat_ms, callback)
							end
						end,
						stop = function()
							timer:stop()
						end,
						close = function()
							timer:close()
						end,
						is_closing = function()
							return timer:is_closing()
						end,
					}
				end
				local pending = wait_for_refresh()
				local notice
				vim.notify = function(message)
					if message:find("has not refreshed its hunks", 1, true) then
						error("timeout notification failed")
					end
					notice = message
				end
				assert(timeout)()
				s.wait(function()
					return notice ~= nil
				end, "timeout error escaped vim.schedule")
				assert(notice:find("timeout notification failed", 1, true))
				assert((s.signs.current_state(pending.buf).native_holds or 0) == 0 and pending.resets == 0)
			end),
		},
		{
			"test_signs_large_file_delegated_revert",
			s.guard(function()
				local _, buf = s.fixture(false, { use_gitsigns = true, signs = { max_file_bytes = 1 } })
				local resets = 0
				attach(buf, function()
					resets = resets + 1
					s.api.nvim_buf_set_lines(buf, 1, 2, false, { "two" })
				end)
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] ~= "changed"
				end, "large-file revert did not reach attached gitsigns")
				assert(resets == 0 and s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two")
				assert((s.signs.current_state(buf).native_holds or 0) == 0 and #s.marks(buf) == 0)
			end),
		},
		{
			"test_signs_large_file_delegated_revert_waits_for_staging",
			s.guard(function()
				local f, buf = s.fixture(false, { use_gitsigns = true, signs = { max_file_bytes = 1 } })
				local resets = 0
				attach(buf, function()
					resets = resets + 1
					local hunks = assert(package.loaded.gitsigns.get_hunks(buf))
					s.api.nvim_buf_set_lines(buf, 1, 2, false, hunks[1].removed.lines)
				end)
				local hunks = assert(package.loaded.gitsigns.get_hunks(buf))
				---@diagnostic disable-next-line: duplicate-set-field
				package.loaded.gitsigns.get_hunks = function(target)
					return target == buf and hunks or nil
				end
				package.loaded.gitsigns.refresh = function()
					assert(s.api.nvim_get_current_buf() == buf, "refreshed the wrong buffer")
					vim.defer_fn(function()
						hunks[1].removed.lines = { "staged" }
						s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
					end, 80)
				end
				local util = require("lazyvcs.util")
				local start, exit = util.system_start, nil
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, cb)
					if args[1] == "git" and args[2] == "add" then
						exit = cb
						return {
							cancel = function()
								return true
							end,
						}
					end
					return start(args, opts, cb)
				end
				local ok, err = xpcall(function()
					local repo =
						{ root = f.root, name = "fixture", vcs = "git", counts = { staged = 0, local_changes = 1 } }
					require("lazyvcs.source_control.ops").stage_file({
						path = f.root,
						lazyvcs_repo_cache = { [f.root] = repo },
						lazyvcs_render = function() end,
					}, {
						type = "file",
						path = f.file,
						extra = { repo_root = f.root, relpath = "sample.txt", section = "unstaged", status = " M" },
					})
					-- Stage runs an asynchronous obstruction preflight before spawning.
					vim.wait(1000, function()
						return exit ~= nil
					end, 5)
					assert(exit, "stage process did not start")
					vim.cmd("LazyVCS hunk revert")
					-- Backend discovery can outlast a fixed wait; a refresh before the revert holds would cancel it.
					s.wait(function()
						local state = s.signs.current_state(buf)
						return state and (state.native_holds or 0) == 1 and #(state.base_waiters or {}) == 1
					end, "large-file revert did not wait for staging", 15000)
					assert(
						resets == 0 and s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed",
						"large-file delegated revert consumed unsettled index"
					)
					-- Refreshes while waiting must retain the command's settlement waiter.
					s.signs.refresh(buf, false)
					s.h.write_file(f.file, "one\nstaged\nthree\n")
					s.h.exec({ "git", "add", "sample.txt" }, f.root)
					exit({ code = 0, stdout = "", stderr = "" }, nil, { code = 0 })
					s.wait(function()
						return s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] ~= "changed"
					end, "large-file revert did not resume after staging")
					assert(
						resets == 0 and s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "staged",
						"waited revert reset against stale pre-stage gitsigns hunks"
					)
					assert((s.signs.current_state(buf).native_holds or 0) == 0)
				end, debug.traceback)
				util.system_start = start
				assert(ok, err)
			end),
		},
		{
			"test_signs_large_file_refresh_timeout_reverts_nothing",
			s.guard(function()
				local notices = {}
				vim.notify = function(message)
					if message:find("has not refreshed its hunks", 1, true) then
						notices[#notices + 1] = message
					end
				end
				local pending = wait_for_refresh()
				local function timed_out(count)
					local started = vim.uv.hrtime()
					s.wait(function()
						return #notices >= count
					end, "missing gitsigns refresh did not time out", 3000)
					assert((vim.uv.hrtime() - started) / 1e6 >= 1800, "refresh wait expired too soon")
					assert(#notices == count and notices[count]:find("retry", 1, true))
					local state = s.signs.current_state(pending.buf)
					assert(pending.resets == 0 and type(pending.confirmation()) ~= "function")
					assert(s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "changed")
					assert((state.native_holds or 0) == 0)
					-- The cached gitsigns hunks still describe the pre-stage index.
					assert(state.gitsigns_refresh_needed, "timeout cleared the freshness mark")
				end
				local function retry(refreshes)
					vim.cmd("LazyVCS hunk revert")
					s.wait(function()
						return pending.refreshes == refreshes
					end, "retry did not request another gitsigns refresh")
				end
				timed_out(1)
				retry(2)
				timed_out(2)
				retry(3)
				pending.publish(pending.buf)
				s.wait(function()
					return type(pending.confirmation()) == "function"
				end, "refreshed hunks did not open confirmation")
				pending.confirmation()()
				s.wait(function()
					return s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "staged"
				end, "refreshed hunk was not reset")
				assert(
					s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "staged",
					"retry reset against stale gitsigns hunks"
				)
				local state = s.signs.current_state(pending.buf)
				assert(#notices == 2 and not state.gitsigns_refresh_needed and (state.native_holds or 0) == 0)
			end),
		},
		{
			"test_signs_large_file_refresh_ignores_other_buffer_updates",
			s.guard(function()
				local pending = wait_for_refresh()
				local other = s.api.nvim_create_buf(false, true)
				pending.publish(other)
				vim.wait(50)
				assert(pending.resets == 0 and type(pending.confirmation()) ~= "function")
				assert((s.signs.current_state(pending.buf).native_holds or 0) == 1)
				vim.defer_fn(function()
					pending.publish(pending.buf)
				end, 50)
				s.wait(function()
					return type(pending.confirmation()) == "function"
				end, "matching GitSignsUpdate did not open confirmation")
				assert(pending.resets == 0)
				pending.confirmation()()
				s.wait(function()
					return s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "staged"
				end, "refreshed hunk was not reset")
				assert(s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "staged")
				assert((s.signs.current_state(pending.buf).native_holds or 0) == 0)
				s.api.nvim_buf_delete(other, { force = true })
			end),
		},
		{
			"test_signs_large_file_waits_for_watcher_without_refresh_api",
			s.guard(function()
				local pending = wait_for_refresh(true)
				assert(pending.resets == 0 and type(pending.confirmation()) ~= "function")
				vim.defer_fn(function()
					pending.publish(pending.buf)
				end, 50)
				s.wait(function()
					return type(pending.confirmation()) == "function"
				end, "watcher update did not open confirmation")
				pending.confirmation()()
				s.wait(function()
					return s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "staged"
				end, "watcher hunk was not reset")
				assert(s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "staged")
				assert((s.signs.current_state(pending.buf).native_holds or 0) == 0)
			end),
		},
		{
			"test_signs_large_file_refresh_wait_cancels_on_unload_or_base_change",
			s.guard(function()
				for _, unload in ipairs({ true, false }) do
					local notices = {}
					vim.notify = function(message)
						if message:find("nothing was reverted", 1, true) then
							notices[#notices + 1] = message
						end
					end
					local pending = wait_for_refresh()
					local state = s.signs.current_state(pending.buf)
					if unload then
						s.api.nvim_buf_delete(pending.buf, { force = true })
					else
						local change =
							s.signs.begin_base_change(vim.fn.fnamemodify(s.api.nvim_buf_get_name(pending.buf), ":h"))
						s.signs.finish_base_change(change)
					end
					assert((state.native_holds or 0) == 0 and next(state.gitsigns_waiters) == nil)
					assert(#notices == (unload and 0 or 1), "base cancellation must warn; unload must stay silent")
					if not unload then
						assert(notices[1]:find("base changed", 1, true))
					end
					pending.publish(pending.buf)
					assert(pending.resets == 0 and type(pending.confirmation()) ~= "function")
				end
			end),
		},
		{
			"test_signs_large_file_confirmation_rejects_base_change",
			s.guard(function()
				for _, settle in ipairs({ false, true }) do
					local f, buf = s.fixture(false, {
						use_gitsigns = true,
						signs = { max_file_bytes = 1 },
						source_control = { confirm_mutations = true },
					})
					local resets = 0
					attach(buf, function()
						resets = resets + 1
					end)
					vim.cmd("LazyVCS hunk revert")
					s.wait(function()
						return type(vim.fn.maparg("1", "n", false, true).callback) == "function"
					end, "large-file confirmation absent")
					local change = s.signs.begin_base_change(f.root, { f.file })
					if settle then
						s.signs.finish_base_change(change)
					end
					vim.fn.maparg("1", "n", false, true).callback()
					vim.wait(30)
					assert(resets == 0, "large-file confirmation ignored a LazyVCS base change")
					assert(s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed")
					assert((s.signs.current_state(buf).native_holds or 0) == 0)
					s.signs.finish_base_change(change)
				end
			end),
		},
		{
			"test_signs_large_file_delegated_revert_reports_no_hunk",
			s.guard(function()
				local _, buf = s.fixture(false, { use_gitsigns = true, signs = { max_file_bytes = 1 } })
				local resets, notice = 0, nil
				attach(buf, function()
					resets = resets + 1
				end)
				---@diagnostic disable-next-line: duplicate-set-field
				package.loaded.gitsigns.get_hunks = function()
					return {}
				end
				vim.notify = function(message)
					notice = message
				end
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return notice ~= nil
				end, "missing gitsigns hunk was not reported")
				assert(notice == "No modified gitsigns hunk at the cursor" and resets == 0)
				assert((s.signs.current_state(buf).native_holds or 0) == 0)
			end),
		},
		{
			"test_signs_large_file_confirmation_checks_gitsigns_hunks",
			s.guard(function()
				local _, buf = s.fixture(false, {
					use_gitsigns = true,
					signs = { max_file_bytes = 1 },
					source_control = { confirm_mutations = true },
				})
				local resets = 0
				attach(buf, function()
					resets = resets + 1
				end)
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return type(vim.fn.maparg("1", "n", false, true).callback) == "function"
				end, "large-file confirmation absent")
				local hunks = assert(package.loaded.gitsigns.get_hunks(buf))
				hunks[1].removed.lines = { "staged" }
				---@diagnostic disable-next-line: duplicate-set-field
				package.loaded.gitsigns.get_hunks = function()
					return hunks
				end
				vim.fn.maparg("1", "n", false, true).callback()
				assert(resets == 0 and s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed")
				assert((s.signs.current_state(buf).native_holds or 0) == 0)
			end),
		},
		{
			"test_signs_delegated_revert_matches_native_hunk_and_eof",
			s.guard(function()
				for _, mode in ipairs({ "text", "range", "eof", "missing", "matching" }) do
					local _, buf = s.fixture(false, { use_gitsigns = true })
					s.refresh(buf, true)
					local resets = 0
					attach(buf, function()
						resets = resets + 1
						s.api.nvim_buf_set_lines(buf, 1, 2, false, { mode == "matching" and "two" or "obsolete" })
					end)
					local reported = assert(package.loaded.gitsigns.get_hunks(buf))
					if mode == "text" then
						reported[1].removed.lines = { "obsolete" }
					elseif mode == "range" then
						reported[1].removed.start = 1
					elseif mode == "eof" then
						reported[1].removed.no_nl_at_eof = true
					elseif mode == "missing" then
						reported = {}
					end
					---@diagnostic disable-next-line: duplicate-set-field
					package.loaded.gitsigns.get_hunks = function()
						return reported
					end
					vim.cmd("LazyVCS hunk revert")
					s.wait(function()
						return s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] ~= "changed"
							or s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two"
					end, "revert absent", 15000)
					assert(
						s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two",
						"stale gitsigns hunk reset the buffer"
					)
					assert(resets == 0, "native revert delegated hunk selection")
					assert((s.signs.current_state(buf).native_holds or 0) == 0 and #s.marks(buf) == 0)
				end
			end),
		},
		{
			"test_signs_native_fallback_resumes_after_gitsigns_detach",
			s.guard(function()
				local _, buf = s.fixture(false, { use_gitsigns = true })
				s.refresh(buf, true)
				attach(buf, function() end)
				local backend = require("lazyvcs.backends")
				local load, loads = backend.load_base_async, 0
				---@diagnostic disable-next-line: duplicate-set-field
				backend.load_base_async = function(...)
					loads = loads + 1
					return load(...)
				end
				local ok, err = xpcall(function()
					for _, event in ipairs({ "TextChanged", "TextChangedI" }) do
						attach(buf, function() end)
						loads = 0
						s.edit(buf, { "one", "attached edit", "three" })
						vim.wait(30)
						assert(loads == 0 and #s.marks(buf) == 0, "attached gitsigns loaded native signs")
						s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
						---@diagnostic disable-next-line: duplicate-set-field
						package.loaded.gitsigns.get_hunks = function()
							return nil
						end
						s.api.nvim_buf_set_lines(buf, 1, 2, false, { "detached edit" })
						s.api.nvim_exec_autocmds(event, { buffer = buf })
						s.wait(function()
							return #s.marks(buf) > 0
						end, "detached gitsigns suppressed native signs", 15000)
						assert(not s.signs.current_state(buf).delegated and loads > 0)
					end
				end, debug.traceback)
				backend.load_base_async = load
				assert(ok, err)
			end),
		},
		{
			"test_signs_delegated_revert_waits_for_base_settlement",
			s.guard(function()
				local f, buf = s.fixture(false, { use_gitsigns = true })
				s.refresh(buf, true)
				local resets = 0
				attach(buf, function()
					resets = resets + 1
					s.api.nvim_buf_set_lines(buf, 1, 2, false, { "two" })
				end)
				local util = require("lazyvcs.util")
				local start, exit, options = util.system_start, nil, nil
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, cb)
					if args[1] == "git" and args[2] == "add" then
						exit, options = cb, opts
						return {
							cancel = function()
								return true
							end,
						}
					end
					return start(args, opts, cb)
				end
				local ok, err = xpcall(function()
					local repo =
						{ root = f.root, name = "fixture", vcs = "git", counts = { staged = 0, local_changes = 1 } }
					require("lazyvcs.source_control.ops").stage_file({
						path = f.root,
						lazyvcs_repo_cache = { [f.root] = repo },
						lazyvcs_render = function() end,
					}, {
						type = "file",
						path = f.file,
						extra = {
							repo_root = f.root,
							relpath = "sample.txt",
							section = "unstaged",
							status = " M",
						},
					})
					-- Stage runs an asynchronous obstruction preflight before spawning.
					vim.wait(1000, function()
						return exit ~= nil
					end, 5)
					assert(exit, "stage process did not start")
					vim.cmd("LazyVCS hunk revert")
					vim.wait(30)
					assert(
						resets == 0 and s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed",
						"delegated revert consumed unsettled base"
					)
					assert(options).on_terminate(nil, "Cancelled", { code = 130, cancelled = true })
					vim.wait(30)
					assert(resets == 0 and not s.signs.current_state(buf).loaded)
					s.h.exec({ "git", "add", "sample.txt" }, f.root)
					exit({ code = 0, stdout = "", stderr = "" }, nil, { code = 0 })
					s.wait(function()
						return (s.signs.current_state(buf).native_holds or 0) == 0
					end, "revert did not settle", 15000)
					assert(resets == 0 and s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed")
					assert(s.h.exec({ "git", "show", ":sample.txt" }, f.root) == "one\nchanged\nthree\n")
				end, debug.traceback)
				util.system_start = start
				assert(ok, err)
			end),
		},
		{
			"test_signs_delegated_confirmation_rejects_changed_base_generation",
			s.guard(function()
				for _, stage in ipairs({ true, false }) do
					local f, buf =
						s.fixture(false, { use_gitsigns = true, source_control = { confirm_mutations = true } })
					s.refresh(buf, true)
					local resets = 0
					attach(buf, function()
						resets = resets + 1
					end)
					vim.cmd("LazyVCS hunk revert")
					s.wait(function()
						return type(vim.fn.maparg("1", "n", false, true).callback) == "function"
					end, "confirmation absent", 15000)
					local state = s.signs.current_state(buf)
					assert(#s.marks(buf) == 0, "native signs appeared while delegated confirmation was open")
					local before = s.api.nvim_buf_get_lines(buf, 0, -1, false)
					local generation = state.base_generation
					local base = vim.deepcopy(state.base_text)
					local config = require("lazyvcs.config").get()
					config.source_control.confirm_mutations = false
					local repo =
						{ root = f.root, name = "fixture", vcs = "git", counts = { staged = 0, local_changes = 1 } }
					require("lazyvcs.source_control.ops")[stage and "stage_file" or "unstage_file"]({
						path = f.root,
						lazyvcs_repo_cache = { [f.root] = repo },
						lazyvcs_render = function() end,
					}, {
						type = "file",
						path = f.file,
						extra = { repo_root = f.root, relpath = "sample.txt", section = "unstaged", status = " M" },
					})
					s.wait(function()
						return state.base_generation >= generation + 2
					end, "real index operation did not settle", 15000)
					-- A no-op unstage advances the generation without changing the base text.
					s.signs.refresh(buf, true, nil, true)
					s.wait(function()
						return state.loaded
					end, "native base did not reload", 15000)
					assert(vim.deep_equal(base, state.base_text) == not stage)
					config.source_control.confirm_mutations = true
					assert(
						s.h.exec({ "git", "show", ":sample.txt" }, f.root)
							== (stage and "one\nchanged\nthree\n" or "one\ntwo\nthree\n")
					)
					vim.fn.maparg("1", "n", false, true).callback()
					vim.wait(30)
					assert(resets == 0, "delegated confirmation ignored changed base generation")
					assert(
						vim.deep_equal(before, s.api.nvim_buf_get_lines(buf, 0, -1, false)),
						"stale confirmation changed buffer lines"
					)
					assert((state.native_holds or 0) == 0)
				end
			end),
		},
	}
end
