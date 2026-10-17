return function(ctx)
	local s = require("signs_helpers")(ctx)
	local text, compat = require("lazyvcs.compare_text"), require("lazyvcs.compat")
	local function fixture(svn, count)
		local f, buf = s.fixture(svn)
		local base, edited = {}, {}
		for i = 1, count do
			base[i] = string.format("line %05d", i)
			edited[i] = base[i] .. (i % 10 == 0 and " changed" or "")
		end
		s.h.write_file(f.file, table.concat(base, "\n") .. "\n")
		s.h.exec(svn and { "svn", "commit", "-m", "preview base" } or { "git", "add", "sample.txt" }, f.root)
		vim.cmd("edit!")
		s.refresh(buf, true)
		s.edit(buf, edited)
		local state = assert(s.refresh(buf, false))
		assert(not state.computing and #state.hunks == count / 10, "hunk worker did not settle")
		local started = vim.uv.hrtime()
		local expected = compat.diff(
			text.serialize(state.base_text),
			text.serialize(state.current_text),
			{ algorithm = "histogram", result_type = "unified" }
		)
		return f, buf, state, expected, (vim.uv.hrtime() - started) / 1e6
	end
	local function hold()
		local requests = {}
		---@diagnostic disable-next-line: duplicate-set-field
		vim.uv.new_work = function(_, done)
			local request = { done = done }
			function request:queue(_, _, result_type)
				self.result_type = result_type
				requests[#requests + 1] = self
				return true
			end
			return request
		end
		return requests
	end
	local function preview_text(expected)
		assert(vim.bo.filetype == "diff", "preview did not open")
		assert(
			vim.deep_equal(s.api.nvim_buf_get_lines(0, 0, -1, false), require("lazyvcs.util").split_lines(expected)),
			"preview output differs from histogram diff"
		)
		vim.fn.maparg("q", "n", false, true).callback()
	end
	local cases = {}
	for _, svn in ipairs({ false, true }) do
		cases[#cases + 1] = {
			(svn and "test_svn_" or "test_") .. "signs_large_preview_uses_worker_after_cached_hunks",
			s.guard(function()
				local _, buf, state, expected = fixture(svn, 4000)
				local source = s.api.nvim_get_current_win()
				local requests = hold()
				vim.cmd("LazyVCS preview")
				assert(
					#requests == 1 and requests[1].result_type == "unified",
					"cached-hunk preview bypassed unified worker"
				)
				assert(s.api.nvim_get_current_win() == source and state.native_holds == 1)
				vim.cmd("LazyVCS preview")
				assert(#requests == 1 and state.native_holds == 1, "duplicate preview queued another worker or hold")
				requests[1].done(true, expected)
				s.wait(function()
					return s.api.nvim_get_current_win() ~= source
				end, "worker preview did not open")
				preview_text(expected)
				assert(state.native_holds == 0 and not state.preview_work, "preview retained work or hold")
				local notices = {}
				vim.notify = function(message)
					notices[#notices + 1] = message
				end
				vim.cmd("LazyVCS preview")
				requests[2].done(true, "", "injected worker failure\nsecond line")
				s.wait(function()
					return state.native_holds == 0
				end, "worker failure retained hold")
				assert(#notices == 1 and not notices[1]:find("\n"), "worker failure was not reported once on one line")
				vim.cmd("LazyVCS preview")
				requests[3].done(false, "")
				s.wait(function()
					return state.native_holds == 0
				end, "unsupported worker retained hold")
				assert(
					#notices == 2 and s.api.nvim_get_current_buf() == buf,
					"unsupported worker opened synchronous preview"
				)
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.new_work = function()
					error("injected worker creation failure")
				end
				vim.cmd("LazyVCS preview")
				assert(
					#notices == 3 and state.native_holds == 0 and not state.preview_pending and not state.preview_work,
					"worker creation failure stranded preview"
				)
			end),
		}
	end
	cases[#cases + 1] = {
		"test_signs_large_preview_keeps_main_loop_responsive",
		s.guard(function()
			local _, _, state, expected, synchronous_ms = fixture(false, 50000)
			local source = s.api.nvim_get_current_win()
			local beats, gap, last = 0, 0, vim.uv.hrtime()
			local timer = assert(vim.uv.new_timer())
			timer:start(
				0,
				10,
				vim.schedule_wrap(function()
					local now = vim.uv.hrtime()
					gap, last, beats = math.max(gap, (now - last) / 1e6), now, beats + 1
				end)
			)
			local ok, err = pcall(function()
				local started = vim.uv.hrtime()
				vim.cmd("LazyVCS preview")
				local call_ms = (vim.uv.hrtime() - started) / 1e6
				assert(state.preview_work, "large preview ran synchronously")
				s.wait(function()
					return s.api.nvim_get_current_win() ~= source
				end, "real worker preview did not open", 20000)
				assert(beats >= 10, "preview blocked heartbeat")
				local budget = synchronous_ms * 0.5 + 30
				assert(gap < budget and call_ms < budget, "preview exceeded measured event-loop budget")
				preview_text(expected)
				print(
					string.format(
						"preview heartbeat: %d beats, maximum gap %.1f ms, call %.1f ms, synchronous %.1f ms",
						beats,
						gap,
						call_ms,
						synchronous_ms
					)
				)
			end)
			timer:stop()
			timer:close()
			assert(ok, err)
		end),
	}
	cases[#cases + 1] = {
		"test_signs_preview_rejects_stale_completion",
		s.guard(function()
			local original = vim.uv.new_work
			for _, change in ipairs({
				"edit",
				"base",
				"rename",
				"unload",
				"replace",
				"close",
				"focus",
				"focus_return",
				"cursor",
				"options",
				"supersede",
			}) do
				vim.uv.new_work = original
				local f, buf, state, expected = fixture(false, 4000)
				local source = s.api.nvim_get_current_win()
				local requests = hold()
				vim.cmd("LazyVCS preview")
				assert(#requests == 1, "preview did not defer publication")
				local mutation
				if change == "edit" then
					s.edit(buf, { "edited again" })
				elseif change == "base" then
					mutation = s.signs.begin_base_change(f.root, { f.file })
				elseif change == "rename" then
					s.api.nvim_buf_set_name(buf, f.file .. ".renamed")
				elseif change == "unload" then
					vim.cmd("enew!")
					s.api.nvim_buf_delete(buf, { force = true })
				elseif change == "replace" then
					vim.cmd("enew!")
				elseif change == "close" then
					vim.cmd.split()
					s.api.nvim_win_close(source, true)
				elseif change == "focus" or change == "focus_return" then
					vim.cmd.split()
					if change == "focus_return" then
						s.api.nvim_set_current_win(source)
					end
				elseif change == "cursor" then
					s.api.nvim_win_set_cursor(0, { 20, 0 })
				elseif change == "options" then
					vim.bo[buf].endofline = false
				else
					s.signs.refresh(buf, true)
				end
				if change == "edit" then
					vim.cmd("LazyVCS preview")
					assert(#requests == 1, "cancelled preview queued a second physical worker")
				end
				local wins = #s.api.nvim_list_wins()
				requests[1].done(true, expected)
				s.wait(function()
					return state.native_holds == 0 and not state.preview_work
				end, "stale preview retained hold")
				assert(
					#s.api.nvim_list_wins() == wins and vim.bo.filetype ~= "diff",
					"stale preview opened after " .. change
				)
				assert(not state.preview_work, "completed stale worker retained bookkeeping")
				if mutation then
					s.signs.finish_base_change(mutation)
				end
				s.h.cleanup()
				vim.cmd("silent! only!")
			end
		end),
	}
	return cases
end
