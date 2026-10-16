return function(ctx)
	local s = require("signs_helpers")(ctx)
	local function fixture(count)
		local f, buf = s.fixture(false)
		local base, changed = {}, {}
		for i = 1, count do
			base[i] = string.format("line %05d", i)
			changed[i] = base[i] .. (i % 10 == 0 and " changed" or "")
		end
		s.h.write_file(f.file, table.concat(base, "\n") .. "\n")
		s.h.exec({ "git", "add", "sample.txt" }, f.root)
		vim.cmd("edit!")
		s.refresh(buf, true)
		require("lazyvcs.config").get().signs.enabled = true
		return f, buf, base, changed
	end
	return {
		{
			"test_signs_costly_refresh_keeps_main_loop_responsive",
			s.guard(function()
				local _, buf, _, changed = fixture(50000)
				local text, diff = require("lazyvcs.compare_text"), require("lazyvcs.diff")
				local base = s.signs.current_state(buf).base_text
				s.api.nvim_buf_set_lines(buf, 0, -1, false, changed)
				local current = assert(text.capture(buf, require("lazyvcs.config").get().signs.max_file_bytes))
				local started = vim.uv.hrtime()
				local expected = diff.compute_text_hunks(base, current)
				local synchronous_ms = (vim.uv.hrtime() - started) / 1e6
				local original, queued, completed, applied = vim.uv.new_work, 0, 0, 0
				vim.uv.new_work = function(worker, done)
					local work = original(worker, function(supported, ...)
						assert(supported, "vim.diff unavailable in worker")
						completed = completed + 1
						done(supported, ...)
						vim.schedule(function()
							local state = s.signs.current_state(buf)
							if state and vim.deep_equal(state.hunks, expected) then
								applied = applied + 1
							end
						end)
					end)
					return {
						queue = function(_, ...)
							queued = queued + 1
							return work:queue(...)
						end,
					}
				end
				local timer = assert(vim.uv.new_timer())
				local last, gap, beats = vim.uv.hrtime(), 0, 0
				timer:start(
					0,
					10,
					vim.schedule_wrap(function()
						local now = vim.uv.hrtime()
						gap, last, beats = math.max(gap, (now - last) / 1e6), now, beats + 1
					end)
				)
				local ok, err = pcall(function()
					s.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
					s.wait(function()
						local state = s.signs.current_state(buf)
						return state
							and state.rendered_identity
							and state.rendered_identity.changedtick == s.api.nvim_buf_get_changedtick(buf)
					end, "costly refresh did not finish", 20000)
					vim.wait(40)
					assert(
						queued > 0 and completed == queued and applied == completed,
						"worker work was not queued and applied"
					)
					local limit_ms = synchronous_ms * 0.5 + 30
					assert(
						gap < limit_ms,
						string.format("sign refresh gap %.1f ms exceeded measured budget %.1f ms", gap, limit_ms)
					)
					assert(beats >= 10, "heartbeat did not run during costly refresh")
					local state = s.signs.current_state(buf)
					assert(#state.hunks == 5000, "worker changed histogram hunk boundaries")
					print(
						string.format(
							"sign heartbeat: %d beats, maximum gap %.1f ms, synchronous %.1f ms, workers %d queued/%d applied",
							beats,
							gap,
							synchronous_ms,
							queued,
							applied
						)
					)
				end)
				timer:stop()
				timer:close()
				vim.uv.new_work = original
				assert(ok, err)
			end),
		},
		{
			"test_signs_gitsigns_attach_before_worker_result_releases_compute_waiters",
			s.guard(function()
				local _, buf, _, changed = fixture(4000)
				require("lazyvcs.config").get().use_gitsigns = true
				local attached, work, completed, loaded, failure = false, nil, 0, nil, nil
				package.loaded.gitsigns = {
					get_hunks = function()
						return attached and {} or nil
					end,
				}
				local original = vim.uv.new_work
				vim.uv.new_work = function(_, done)
					work = {
						done = done,
						queue = function()
							return true
						end,
					}
					return work
				end
				local ok, err = pcall(function()
					s.edit(buf, changed)
					s.signs.refresh(buf, false, function(state, why)
						completed, loaded, failure = completed + 1, state, why
					end)
					assert(work, "diff worker did not start")
					attached = true
					work.done(true, vim.mpack.encode({ { 10, 1, 10, 1 } }))
					s.wait(function()
						return completed > 0
					end, "delegation stranded compute waiter")
					assert(
						completed == 1
							and not loaded
							and type(failure) == "string"
							and failure:find("delegated", 1, true),
						"worker result ignored gitsigns attachment"
					)
					assert(#s.marks(buf) == 0 and s.signs.current_state(buf).delegated)
				end)
				vim.uv.new_work = original
				assert(ok, err)
			end),
		},
		{
			"test_signs_thread_results_reject_edits_and_base_changes",
			s.guard(function()
				local f, buf, base, changed = fixture(4000)
				local original, work = vim.uv.new_work, {}
				vim.uv.new_work = function(_, done)
					local worker = {
						done = done,
						queue = function()
							return true
						end,
					}
					work[#work + 1] = worker
					return worker
				end
				local ok, err = pcall(function()
					s.edit(buf, changed)
					s.signs.refresh(buf, false)
					assert(#work == 1, "large refresh did not queue a diff worker")
					s.edit(buf, base)
					work[1].done(true, vim.mpack.encode({ { 10, 1, 10, 1 } }))
					vim.wait(30)
					assert(#s.signs.current_state(buf).hunks == 0, "stale changedtick diff was applied")
					s.edit(buf, changed)
					s.signs.refresh(buf, false)
					assert(#work == 2)
					local change = s.signs.begin_base_change(f.root)
					work[2].done(true, vim.mpack.encode({ { 10, 1, 10, 1 } }))
					vim.wait(30)
					assert(
						not s.signs.current_state(buf).loaded and #s.marks(buf) == 0,
						"obsolete base diff was published"
					)
					s.signs.finish_base_change(change)
					s.wait(function()
						return #work == 3
					end, "new base did not queue replacement work", 15000)
					vim.cmd("enew!")
					s.api.nvim_buf_delete(buf, { unload = true, force = true })
					work[3].done(true, vim.mpack.encode({ { 10, 1, 10, 1 } }))
					vim.wait(30)
					assert(s.signs.current_state(buf) == nil, "worker resurrected unloaded state")
				end)
				vim.uv.new_work = original
				assert(ok, err)
			end),
		},
	}
end
