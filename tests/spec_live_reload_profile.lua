return function(ctx)
	local api, h = vim.api, ctx.helpers
	local backends, text, util = require("lazyvcs.backends"), require("lazyvcs.compare_text"), require("lazyvcs.util")
	local actions, state
	local function guard(fn)
		return function()
			local base, load, profile, notify = backends.load_base_async, backends.load_async, text.profile, util.notify
			local hidden = vim.o.hidden
			local ok, err = xpcall(fn, debug.traceback)
			backends.load_base_async, backends.load_async, text.profile, util.notify = base, load, profile, notify
			vim.o.hidden = hidden
			h.cleanup()
			assert(ok, err)
		end
	end
	local function fixture()
		actions, state = require("lazyvcs.actions"), require("lazyvcs.state")
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			blame = { persist = false },
			debounce_ms = 5,
		})
		vim.o.hidden = true
		local f = h.make_git_transfer_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		local buf = api.nvim_get_current_buf()
		actions.open()
		ctx.wait_for(function()
			return state.get(buf) and state.get(buf).hunk_cache
		end, "source did not open", 15000)
		local s = assert(state.get(buf))
		api.nvim_set_current_win(s.editable_win)
		return f, buf, s
	end
	local function hold_base(f, fail_second)
		local original = backends.load_base_async
		local held = { reads = 0 }
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_base_async = function(path, done, opts)
			if path ~= f.file1 then
				return original(path, done, opts)
			end
			held.reads = held.reads + 1
			local number = held.reads
			return original(path, function(...)
				if number == 1 then
					local args = { ... }
					held.release = function()
						done(unpack(args))
					end
				elseif number == 2 and fail_second then
					done(nil, "current base read failed")
				else
					done(...)
				end
			end, opts)
		end
		actions.refresh_current()
		ctx.wait_for(function()
			return held.release
		end, "real base completion not held", 15000)
		return held
	end
	local function option(buf, name, value)
		api.nvim_buf_call(buf, function()
			vim.bo[buf][name] = value
			api.nvim_exec_autocmds("OptionSet", { pattern = name })
		end)
	end
	local function settled(buf, s, held, count)
		ctx.wait_for(function()
			return s.phase == "active"
				and not s.refresh_job
				and not s.base_invalid
				and s.base_text
				and s.base_text.profile_key == text.profile(buf).key
				and s.hunk_cache
		end, "latest profile base did not settle", 15000)
		vim.wait(50)
		assert(held.reads == count, "base reads did not coalesce: " .. held.reads)
	end
	local cases = {}
	for _, name in ipairs({ "fileformat", "bomb" }) do
		cases[#cases + 1] = {
			"test_live_diff_reload_profile_saved_" .. name,
			guard(function()
				local f, buf, s = fixture()
				local held = hold_base(f)
				option(buf, name, name == "bomb" and true or "dos")
				api.nvim_buf_call(buf, vim.cmd.write)
				vim.wait(50)
				assert(held.reads == 1 and s.refresh_job, "profile event replaced the pending owner early")
				held.release()
				settled(buf, s, held, 2)
			end),
		}
	end
	cases[#cases + 1] = {
		"test_live_diff_reload_rapid_profiles_coalesce_and_unchanged_profile_reads_once",
		guard(function()
			local f, buf, s = fixture()
			local held = hold_base(f)
			held.release()
			settled(buf, s, held, 1)
			held = hold_base(f)
			for _, value in ipairs({
				{ "fileformat", "dos" },
				{ "bomb", true },
				{ "bomb", false },
				{ "fileformat", "unix" },
				{ "fileformat", "dos" },
			}) do
				option(buf, value[1], value[2])
			end
			vim.wait(50)
			held.release()
			settled(buf, s, held, 2)
		end),
	}
	cases[#cases + 1] = {
		"test_live_diff_reload_latest_read_failure_stops_and_manual_retry_recovers",
		guard(function()
			local notices = {}
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function(message)
				notices[#notices + 1] = message
			end
			local f, buf, s = fixture()
			local held = hold_base(f, true)
			option(buf, "fileformat", "dos")
			vim.wait(50)
			held.release()
			ctx.wait_for(function()
				return held.reads == 2 and not s.refresh_job and s.reload_error
			end, "replacement read failure did not settle", 15000)
			vim.wait(100)
			assert(held.reads == 2 and s.base_invalid and #notices == 1)
			assert(s.reload_error == "current base read failed")
			actions.refresh_current()
			settled(buf, s, held, 3)
		end),
	}
	for _, action in ipairs({ "close", "rename" }) do
		cases[#cases + 1] = {
			"test_live_diff_reload_profile_" .. action .. "_does_not_resurrect_owner",
			guard(function()
				local f, buf = fixture()
				local held = hold_base(f)
				option(buf, "fileformat", "dos")
				vim.wait(50)
				if action == "close" then
					actions.close(buf)
				else
					api.nvim_buf_set_name(buf, f.root .. "/renamed.txt")
				end
				held.release()
				ctx.wait_for(function()
					return not state.get(buf)
				end, "obsolete owner remained open")
				vim.wait(100)
				assert(held.reads == 1 and not state.get(buf), "late read restarted obsolete source")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_live_diff_reload_unsupported_profile_fails_once_then_recovers",
		guard(function()
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function() end
			local f, buf, s = fixture()
			local held = hold_base(f)
			option(buf, "binary", true)
			vim.wait(50)
			held.release()
			ctx.wait_for(function()
				return held.reads == 2 and not s.refresh_job and s.failed_profile_key == text.profile(buf).key
			end, "unsupported profile did not settle", 15000)
			vim.wait(100)
			assert(held.reads == 2 and s.base_invalid and #s.hunks == 0, "unsupported profile retried indefinitely")
			option(buf, "binary", false)
			settled(buf, s, held, 3)
		end),
	}
	cases[#cases + 1] = {
		"test_live_diff_reload_invalid_profile_remains_silent_without_retry_loop",
		guard(function()
			local f, buf, s = fixture()
			local held = hold_base(f)
			local original = text.profile
			---@diagnostic disable-next-line: duplicate-set-field
			text.profile = function(target)
				if target ~= buf then
					return original(target)
				end
			end
			held.release()
			vim.wait(100)
			assert(held.reads == 1 and not s.refresh_job, "unavailable profile caused a retry loop")
			text.profile = original
			assert(state.get(buf) == s)
		end),
	}
	cases[#cases + 1] = {
		"test_live_diff_reload_superseded_generation_ignores_old_profile_result",
		guard(function()
			local f, buf, s = fixture()
			local held = hold_base(f)
			option(buf, "fileformat", "dos")
			local change = actions.begin_base_change(f.root, { f.file1 })
			actions.finish_base_change(change)
			settled(buf, s, held, 2)
			held.release()
			settled(buf, s, held, 2)
		end),
	}
	cases[#cases + 1] = {
		"test_live_diff_reload_deferred_profile_retries_once_on_retained_return",
		guard(function()
			local f, buf, s = fixture()
			local held = hold_base(f)
			local original, late = backends.load_async, nil
			---@diagnostic disable-next-line: duplicate-set-field
			backends.load_async = function(path, done, opts)
				return original(path, function(...)
					if path == f.file2 then
						local args = { ... }
						late = function()
							done(unpack(args))
						end
					else
						done(...)
					end
				end, opts)
			end
			vim.cmd.edit(vim.fn.fnameescape(f.file2))
			local target = api.nvim_get_current_buf()
			ctx.wait_for(function()
				return late and s.phase == "loading"
			end, "target did not remain pending", 15000)
			option(buf, "fileformat", "dos")
			held.release()
			local pending = assert(state.peek_pending_transfer(s.editable_win))
			assert(pending.refresh_completion and held.reads == 1, "hidden completion was not deferred")
			vim.cmd.buffer(buf)
			settled(buf, s, held, 2)
			assert(late)()
			vim.wait(50)
			assert(state.get(buf) == s and not state.get(target) and held.reads == 2)
		end),
	}
	return cases
end
