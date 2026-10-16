return function(ctx)
	local s = require("signs_helpers")(ctx)
	local ops, store = require("lazyvcs.source_control.ops"), require("lazyvcs.state")
	local function sidebar(f, svn)
		local repo = {
			root = f.root,
			name = "fixture",
			vcs = svn and "svn" or "git",
			counts = { staged = 0, local_changes = 1 },
		}
		return {
			path = f.root,
			lazyvcs_repo_cache = { [f.root] = repo },
			lazyvcs_commit_drafts = { [f.root] = "sign base regression" },
			lazyvcs_render = function() end,
		}, {
			type = "file",
			path = f.file,
			extra = { repo_root = f.root, relpath = "sample.txt", section = "unstaged", status = " M" },
		}
	end
	local function finished(f)
		s.wait(function()
			local job = store.get_repo_job(f.root)
			return not job or job.status ~= "running"
		end, "mutation did not settle", 15000)
	end
	local function hunk_count(buf, n, message)
		s.wait(function()
			local state = s.signs.current_state(buf)
			return state and state.loaded and #state.hunks == n
		end, message, 15000)
	end
	local cases = {
		{
			"test_signs_native_stage_then_growth_clears_stale_marks",
			s.guard(function()
				local f, buf = s.fixture(false, { signs = { max_file_bytes = 64 } })
				s.refresh(buf, true)
				local sidebar_state, node = sidebar(f)
				ops.stage_file(sidebar_state, node)
				finished(f)
				hunk_count(buf, 0, "stage did not settle")
				s.edit(buf, { "one", "post-stage edit", "three" })
				s.wait(function()
					return #s.marks(buf) > 0
				end, "native edit signs absent")
				s.edit(buf, { "one", string.rep("x", 80), "three" })
				s.wait(function()
					return #s.marks(buf) == 0
				end, "oversized buffer retained stale marks")
				local state = assert(s.signs.current_state(buf))
				assert(state.skipped and not state.base_text and not state.current_text)
				assert(not state.gitsigns_refresh_needed, "native stage set a gitsigns freshness mark")
			end),
		},
		{
			"test_signs_stage_reloads_index_before_hunk_actions",
			s.guard(function()
				local f, buf = s.fixture(false)
				s.refresh(buf, true)
				local state, node = sidebar(f)
				ops.stage_file(state, node)
				finished(f)
				hunk_count(buf, 0, "stage left the previous index cached")
				assert(#s.marks(buf) == 0)
				vim.cmd("LazyVCS preview")
				assert(s.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "No changes")
				s.api.nvim_win_close(0, true)
				s.api.nvim_win_set_cursor(0, { 2, 0 })
				vim.cmd("LazyVCS hunk revert")
				assert(s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed")
				state, node = sidebar(f)
				ops.unstage_file(state, node)
				finished(f)
				hunk_count(buf, 1, "unstage did not reload index")
				state = sidebar(f)
				ops.run_primary_action(state, { extra = { repo_root = f.root, action = "stage_all" } })
				finished(f)
				hunk_count(buf, 0, "stage-all did not reload index")
			end),
		},
		{
			"test_signs_base_change_rejects_pending_revert",
			s.guard(function()
				local f, buf = s.fixture(false)
				s.refresh(buf, true)
				local config = require("lazyvcs.config").get()
				config.source_control.confirm_mutations = true
				s.api.nvim_win_set_cursor(0, { 2, 0 })
				vim.cmd("LazyVCS hunk revert")
				local accept = vim.fn.maparg("1", "n", false, true).callback
				assert(type(accept) == "function")
				config.source_control.confirm_mutations = false
				local state, node = sidebar(f)
				ops.unstage_file(state, node)
				finished(f)
				hunk_count(buf, 1, "unchanged index did not reload")
				accept()
				vim.wait(100)
				assert(
					s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed",
					"revert accepted an obsolete base generation"
				)
				local backends, held = require("lazyvcs.backends"), nil
				local load = backends.load_base_async
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_base_async = function(_, cb)
					held = cb
					return { kill = function() end }
				end
				s.signs.refresh(buf, true)
				s.wait(function()
					return held ~= nil
				end, "old load did not start", 15000)
				backends.load_base_async = load
				state, node = sidebar(f)
				ops.stage_file(state, node)
				finished(f)
				hunk_count(buf, 0, "replacement index did not load")
				assert(held)({ root = f.root, relpath = "sample.txt", base_lines = { "one", "two", "three" } })
				assert(#s.signs.current_state(buf).hunks == 0, "obsolete load replaced the new index")
			end),
		},
		{
			"test_signs_failed_commit_keeps_successfully_staged_base",
			s.guard(function()
				local f, buf = s.fixture(false)
				s.refresh(buf, true)
				local state, node = sidebar(f)
				ops.stage_file(state, node)
				finished(f)
				s.h.exec({ "git", "config", "user.name", "" }, f.root)
				state = sidebar(f)
				state.lazyvcs_repo_cache[f.root].counts.staged = 1
				ops.commit_repo(state, { path = f.root })
				finished(f)
				hunk_count(buf, 0, "failed commit restored obsolete pre-stage base")
				assert(store.get_repo_job(f.root), "commit should fail without an author")
			end),
		},
		{
			"test_signs_mutation_ownership_waits_for_process_settlement",
			s.guard(function()
				local f, buf = s.fixture(false)
				s.refresh(buf, true)
				local util = require("lazyvcs.util")
				local start, exit, process_opts = util.system_start, nil, nil
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, options, cb)
					if args[1] == "git" and args[2] == "add" then
						exit, process_opts = cb, options
						return {
							cancel = function()
								return true
							end,
						}
					end
					return start(args, options, cb)
				end
				local ok, err = pcall(function()
					local state, node = sidebar(f)
					ops.stage_file(state, node)
					assert(exit, "mutation did not start")
					assert(not s.signs.current_state(buf).loaded, "mutation start left base available")
					local raw = { code = 130, stdout = "", stderr = "Cancelled", cancelled = true }
					assert(process_opts).on_terminate(nil, "Cancelled", raw)
					assert(not s.signs.current_state(buf).loaded, "logical cancellation released base ownership")
					local source = s.api.nvim_get_current_win()
					vim.cmd("LazyVCS preview")
					vim.wait(30)
					assert(s.api.nvim_get_current_win() == source, "command consumed an unsettled base")
					assert(exit)(nil, "Cancelled", raw)
					s.wait(function()
						return s.api.nvim_get_current_win() ~= source
					end, "waiting preview did not resume", 15000)
					s.api.nvim_win_close(0, true)
					assert(s.signs.current_state(buf).loaded)
					require("lazyvcs.config").get().signs.enabled = false
					vim.cmd.write()
					local backends, held = require("lazyvcs.backends"), nil
					local load = backends.load_base_async
					---@diagnostic disable-next-line: duplicate-set-field
					backends.load_base_async = function(_, cb)
						held = cb
						return { kill = function() end }
					end
					vim.cmd("LazyVCS preview")
					s.wait(function()
						return held ~= nil
					end, "explicit load did not start", 15000)
					state, node = sidebar(f)
					ops.stage_file(state, node)
					backends.load_base_async = load
					assert(exit)(nil, "Cancelled", raw)
					s.wait(function()
						return s.api.nvim_get_current_win() ~= source
					end, "disabled-sign command lost its pending load at mutation", 15000)
					s.api.nvim_win_close(0, true)
					assert(#s.marks(buf) == 0)
				end)
				util.system_start = start
				assert(ok, err)
			end),
		},
		{
			"test_svn_signs_commit_reloads_base",
			s.guard(function()
				local f, buf = s.fixture(true)
				s.refresh(buf, true)
				local state = sidebar(f, true)
				ops.commit_repo(state, { path = f.root })
				finished(f)
				hunk_count(buf, 0, "SVN commit left previous BASE cached")
				assert(#s.marks(buf) == 0)
			end),
		},
	}
	cases[#cases + 1] = {
		"test_signs_confirmed_revert_warns_when_validation_base_changes",
		s.guard(function()
			local f, buf = s.fixture(false, { source_control = { confirm_mutations = true } })
			s.refresh(buf, true)
			local backends = require("lazyvcs.backends")
			local validate, held = backends.validate_editable_base_async, nil
			---@diagnostic disable-next-line: duplicate-set-field
			backends.validate_editable_base_async = function(_, _, cb)
				held = cb
			end
			local ok, err = pcall(function()
				s.api.nvim_win_set_cursor(0, { 2, 0 })
				vim.cmd("LazyVCS hunk revert")
				local accept = vim.fn.maparg("1", "n", false, true).callback
				assert(type(accept) == "function")
				accept()
				assert(held, "confirmed revert did not validate base")
				local messages = {}
				vim.notify = function(message, level)
					messages[#messages + 1] = { message, level }
				end
				local change = s.signs.begin_base_change(f.root)
				held(true)
				assert(s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "changed")
				assert(#messages == 1, "stale confirmed revert returned silently")
				assert(messages[1][1] == "Hunk base changed while confirmation was open; nothing was reverted")
				assert(messages[1][2] == vim.log.levels.WARN)
				s.signs.finish_base_change(change)
			end)
			backends.validate_editable_base_async = validate
			assert(ok, err)
		end),
	}
	cases[#cases + 1] = {
		"test_signs_spawn_failure_releases_base_change_and_waiting_command",
		s.guard(function()
			local f, buf = s.fixture(false)
			s.refresh(buf, true)
			local system, source, attempted = vim.system, s.api.nvim_get_current_win(), false
			vim.system = function(args, ...)
				if args[1] == "git" and args[2] == "add" then
					attempted = true
					assert(not s.signs.current_state(buf).loaded)
					vim.cmd("LazyVCS preview")
					error("injected spawn failure")
				end
				return system(args, ...)
			end
			local ok, err = pcall(function()
				local state, node = sidebar(f)
				ops.stage_file(state, node)
				finished(f)
				assert(attempted, "mutation spawn was not attempted")
				s.wait(function()
					return s.api.nvim_get_current_win() ~= source
				end, "spawn failure stranded waiting preview", 15000)
				s.api.nvim_win_close(0, true)
				hunk_count(buf, 1, "spawn failure stranded sign base")
			end)
			vim.system = system
			assert(ok, err)
		end),
	}
	for _, svn in ipairs({ false, true }) do
		cases[#cases + 1] = {
			(svn and "test_svn_" or "test_") .. "signs_base_change_matches_symlinked_directory",
			s.guard(function()
				local f, buf = s.fixture(svn)
				s.refresh(buf, true)
				local alias = s.h.tempdir() .. "/alias"
				assert(vim.uv.fs_symlink(f.root, alias, { dir = true }))
				local util = require("lazyvcs.util")
				assert(
					util.canonical_entry_path(alias .. "/sample.txt") == util.canonical_entry_path(util.buf_path(buf))
				)
				local change = s.signs.begin_base_change(alias, { alias .. "/sample.txt" })
				local invalidated = not s.signs.current_state(buf).loaded
				s.signs.finish_base_change(change)
				assert(invalidated, "symlinked mutation path did not invalidate sign base")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_signs_base_change_matches_windows_drive_case",
		s.guard(function()
			local _, buf = s.fixture(false)
			s.refresh(buf, true)
			local state = s.signs.current_state(buf)
			local path, root, ignorecase = state.path, state.root, vim.o.fileignorecase
			local ok, err = pcall(function()
				vim.o.fileignorecase = true
				state.path, state.root = "C:/repo/sample.txt", "C:/repo"
				local change = s.signs.begin_base_change("c:/repo", { "c:/repo/sample.txt" })
				local invalidated = not state.loaded
				state.path, state.root = path, root
				s.signs.finish_base_change(change)
				assert(invalidated, "Windows drive case prevented per-file invalidation")
			end)
			state.path, state.root, vim.o.fileignorecase = path, root, ignorecase
			assert(ok, err)
		end),
	}
	return cases
end
