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
					s.edit(buf, changed)
					s.wait(function()
						local state = s.signs.current_state(buf)
						return state
							and state.rendered_identity
							and state.rendered_identity.changedtick == s.api.nvim_buf_get_changedtick(buf)
					end, "costly refresh did not finish", 20000)
					vim.wait(40)
					assert(gap < 500, string.format("sign refresh blocked main loop for %.0f ms", gap))
					assert(beats >= 10, "heartbeat did not run during costly refresh")
					local state = s.signs.current_state(buf)
					assert(#state.hunks == 5000, "worker changed histogram hunk boundaries")
					print(string.format("sign heartbeat: %d beats, maximum gap %.1f ms", beats, gap))
				end)
				timer:stop()
				timer:close()
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
