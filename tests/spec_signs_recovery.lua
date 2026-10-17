return function(ctx)
	local s = require("signs_helpers")(ctx)
	local ops, store = require("lazyvcs.source_control.ops"), require("lazyvcs.state")
	local function stage(f)
		ops.stage_file({
			path = f.root,
			lazyvcs_repo_cache = {
				[f.root] = { root = f.root, name = "fixture", vcs = "git", counts = { staged = 0, local_changes = 1 } },
			},
			lazyvcs_render = function() end,
		}, {
			type = "file",
			path = f.file,
			extra = { repo_root = f.root, relpath = "sample.txt", section = "unstaged", status = " M" },
		})
	end
	local function recovered(f, buf)
		s.wait(function()
			local job = store.get_repo_job(f.root)
			local state = s.signs.current_state(buf)
			return (not job or job.status ~= "running") and state and state.loaded
		end, "stage did not reload suspended base", 15000)
		s.edit(buf, { "unsaved after stage" })
		s.wait(function()
			local state = s.signs.current_state(buf)
			return state and #state.hunks == 1 and #s.marks(buf) > 0
		end, "unsaved edit did not recover signs", 15000)
		assert(s.h.exec({ "git", "show", ":sample.txt" }, f.root) == "resolved\n")
		s.api.nvim_buf_delete(buf, { force = true })
		assert(s.signs.current_state(buf) == nil, "unload retained suspended metadata")
	end
	return {
		{
			"test_signs_recover_after_queued_conflict_stage",
			s.guard(function()
				local f, buf = s.fixture(false, { source_control = { background = { git_workers = 1 } } })
				s.h.exec({ "git", "checkout", "-b", "conflict" }, f.root)
				s.h.write_file(f.file, "branch\n")
				s.h.exec({ "git", "commit", "-am", "branch" }, f.root)
				s.h.exec({ "git", "checkout", "-b", "resolution", "HEAD~1" }, f.root)
				s.h.write_file(f.file, "other\n")
				s.h.exec({ "git", "commit", "-am", "other" }, f.root)
				assert(vim.system({ "git", "merge", "conflict" }, { cwd = f.root }):wait().code ~= 0)
				s.h.write_file(f.file, "resolved\n")
				vim.cmd("edit!")
				local exit
				require("lazyvcs.source_control.jobs").command(
					{ root = f.root, vcs = "git" },
					"blocker",
					{ "git", "status" },
					{
						start = function(_, _, done)
							exit = done
							return {}
						end,
					},
					function() end
				)
				assert(exit, "scheduler blocker did not start")
				stage(f)
				vim.cmd("enew!")
				vim.cmd.buffer(buf)
				local failed = s.refresh(buf, true)
				assert(not failed, "unmerged base unexpectedly loaded")
				assert(s.h.exec({ "git", "ls-files", "-u" }, f.root) ~= "", "stage ran before buffer return")
				local state = s.signs.current_state(buf)
				local retained = state
					and not state.loaded
					and not state.base_text
					and not state.current_text
					and #s.marks(buf) == 0
				exit({ code = 0, stdout = "", stderr = "" })
				assert(retained, "unavailable conflict base lost eligibility metadata")
				recovered(f, buf)
			end),
		},
		{
			"test_signs_recover_after_staging_shrunk_oversized_base",
			s.guard(function()
				local f, buf = s.fixture(false, { signs = { max_file_bytes = 64 } })
				s.h.write_file(f.file, string.rep("large base", 20) .. "\n")
				s.h.exec({ "git", "add", "sample.txt" }, f.root)
				s.h.write_file(f.file, "resolved\n")
				vim.cmd("edit!")
				local loaded, err = s.refresh(buf, true)
				assert(not loaded and err, "oversized base unexpectedly loaded")
				local state = s.signs.current_state(buf)
				assert(
					state and not state.loaded and not state.base_text and not state.base_lines and #s.marks(buf) == 0,
					"oversized base lost eligibility metadata"
				)
				local generation = state.base_generation
				local unrelated = s.signs.begin_base_change(f.root, { f.root .. "/other.txt" })
				s.signs.finish_base_change(unrelated)
				assert(state.base_generation == generation, "unrelated path retried suspended base")
				local other_root = s.signs.begin_base_change(s.h.tempdir())
				s.signs.finish_base_change(other_root)
				assert(state.base_generation == generation, "unrelated root retried suspended base")
				stage(f)
				recovered(f, buf)
			end),
		},
		{
			"test_signs_suspended_base_ignores_edits_until_base_change",
			s.guard(function()
				local f, buf = s.fixture(false, { debounce_ms = 10, signs = { max_file_bytes = 64 } })
				s.h.write_file(f.file, string.rep("large base", 20) .. "\n")
				s.h.exec({ "git", "add", "sample.txt" }, f.root)
				s.h.write_file(f.file, "resolved\n")
				vim.cmd("edit!")
				assert(not s.refresh(buf, true), "oversized base unexpectedly loaded")
				local state = assert(s.signs.current_state(buf))
				local generation = state.base_generation
				for index = 1, 3 do
					s.edit(buf, { "unsaved " .. index })
					vim.wait(60)
				end
				-- Each retry would read the whole oversized base again.
				assert(state.base_generation == generation and not state.loaded, "edits reloaded a suspended base")
				s.edit(buf, { "resolved" })
				stage(f)
				recovered(f, buf)
			end),
		},
	}
end
