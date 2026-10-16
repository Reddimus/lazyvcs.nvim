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
	local function wait_for_refresh(no_refresh_api)
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
					return resets > 0
				end, "large-file revert did not reach attached gitsigns")
				assert(resets == 1 and s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two")
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
					assert(exit, "stage process did not start")
					vim.cmd("LazyVCS hunk revert")
					vim.wait(50)
					assert(resets == 0, "large-file delegated revert consumed unsettled index")
					-- Refreshes while waiting must retain the command's settlement waiter.
					s.signs.refresh(buf, false)
					s.h.write_file(f.file, "one\nstaged\nthree\n")
					s.h.exec({ "git", "add", "sample.txt" }, f.root)
					exit({ code = 0, stdout = "", stderr = "" }, nil, { code = 0 })
					s.wait(function()
						return resets > 0
					end, "large-file revert did not resume after staging")
					assert(
						resets == 1 and s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "staged",
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
				local started = vim.uv.hrtime()
				s.wait(function()
					return #notices > 0
				end, "missing gitsigns refresh did not time out", 3000)
				assert((vim.uv.hrtime() - started) / 1e6 >= 1800, "refresh wait expired too soon")
				assert(notices[1]:find("retry", 1, true))
				assert(pending.resets == 0 and type(pending.confirmation()) ~= "function")
				assert(s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "changed")
				assert((s.signs.current_state(pending.buf).native_holds or 0) == 0)
				pending.publish(pending.buf)
				vim.wait(50)
				assert(#notices == 1 and pending.resets == 0 and type(pending.confirmation()) ~= "function")
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
					return pending.resets == 1
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
					return pending.resets == 1
				end, "watcher hunk was not reset")
				assert(s.api.nvim_buf_get_lines(pending.buf, 1, 2, false)[1] == "staged")
				assert((s.signs.current_state(pending.buf).native_holds or 0) == 0)
			end),
		},
		{
			"test_signs_large_file_refresh_wait_cancels_on_unload_or_base_change",
			s.guard(function()
				for _, unload in ipairs({ true, false }) do
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
						return resets > 0 or s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two"
					end, "revert absent", 15000)
					assert(
						s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two",
						"stale gitsigns hunk reset the buffer"
					)
					assert(resets == (mode == "matching" and 1 or 0), "incompatible gitsigns hunk was delegated")
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
				local _, buf = s.fixture(false, { use_gitsigns = true, source_control = { confirm_mutations = true } })
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
				state.base_generation = state.base_generation + 1
				vim.fn.maparg("1", "n", false, true).callback()
				vim.wait(30)
				assert(resets == 0, "delegated confirmation ignored changed base generation")
				assert(s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed")
				assert((state.native_holds or 0) == 0)
			end),
		},
	}
end
