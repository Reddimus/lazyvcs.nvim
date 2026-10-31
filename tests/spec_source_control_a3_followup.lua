return function(ctx)
	local h = ctx.helpers
	local ai = require("lazyvcs.source_control.ai")
	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local function guarded(fn)
		return function()
			local generate, notify = ai.generate, util.notify
			local ok, err = xpcall(fn, debug.traceback)
			ai.generate, util.notify = generate, notify
			assert(ok, err)
		end
	end
	local function state_for(root)
		return {
			lazyvcs_repo_cache = { [root] = { root = root, vcs = "git", name = "repo" } },
			lazyvcs_commit_drafts = {},
		}, {
			path = root,
		}
	end
	local cases = {
		{
			"test_source_control_a3_actual_ai_notice_is_one_row",
			guarded(function()
				local notice
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function(value)
					notice = value
				end
				local ok, err = pcall(ai.notify_error, h.tempdir(), "provider failure\n" .. string.rep("é", 300))
				assert(ok, err)
				assert(not notice:find("[\r\n]") and vim.fn.strdisplaywidth(notice) < vim.o.columns)
			end),
		},
		{
			"test_source_control_a3_empty_draft_repaints_after_generated_write",
			guarded(function()
				local root = h.tempdir()
				local state, node = state_for(root)
				local callback, paint
				---@diagnostic disable-next-line: duplicate-set-field
				ai.generate = function(_, done)
					callback = done
					return { cancel = function() end }
				end
				state.lazyvcs_repaint = function()
					paint = state.lazyvcs_commit_drafts[root]
				end
				ops.generate_commit_message(state, node)
				callback("Visible generated subject")
				assert(paint == "Visible generated subject", "last repaint did not include generated draft")
			end),
		},
		{
			"test_source_control_a3_ai_success_clears_only_own_diagnostic",
			guarded(function()
				local root, other = h.tempdir(), h.tempdir()
				local state, node = state_for(root)
				local callback
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function() end
				pcall(ai.notify_error, root, "old failure")
				pcall(ai.notify_error, other, "other failure")
				---@diagnostic disable-next-line: duplicate-set-field
				ai.generate = function(_, done)
					callback = done
					return { cancel = function() end }
				end
				ops.generate_commit_message(state, node)
				callback("Successful subject")
				assert(not ai.last_error(root), "successful generation retained obsolete diagnostic")
				assert(ai.last_error(other) == "other failure", "success cleared another repository error")
			end),
		},
	}
	local model = require("lazyvcs.source_control.model")
	vim.list_extend(cases, {
		{
			"test_source_control_a3_git_status_cap_retains_complete_header",
			function()
				local repo = { root = h.tempdir(), vcs = "git", name = "repo" }
				local status
				model.load_repo_summary_async(repo, {}, function(_, _, done)
					done({
						code = 0,
						signal = 0,
						stdout = "## feature...origin/feature [ahead 2]\n M partial",
						stdout_truncated = true,
					})
				end, function(value)
					status = value
				end)
				assert(
					status and status.incomplete and status.counts_complete == false,
					"cap did not return explicit incomplete state"
				)
				assert(
					status.branch == "feature" and status.upstream == "origin/feature" and status.root == repo.root,
					"complete header lost"
				)
				assert(
					#status.sections == 0 and status.counts.local_changes == 0 and status.counts.complete == false,
					"partial rows became authoritative"
				)
			end,
		},
		{
			"test_source_control_a3_v2_status_cap_and_merge_keep_cached_counts_unknown",
			function()
				local repo = { root = h.tempdir(), vcs = "git", name = "repo" }
				local previous =
					{ branch = "old", sections = {}, counts = { local_changes = 7, staged = 3 }, details_loaded = true }
				local status
				model.load_repo_details_async(repo, { previous = previous }, function(_, _, done)
					done(nil, "output cap", {
						code = 0,
						signal = 0,
						stdout = "# branch.oid abc\0# branch.head feature\0# branch.upstream origin/feature\0# branch.ab +2 -1\0? partial",
						stdout_truncated = true,
					})
				end, function(value)
					status = value
				end)
				assert(
					status and status.incomplete and status.branch == "feature",
					"v2 cap lost complete branch headers"
				)
				assert(status.counts.local_changes == 7 and not status.counts_complete, "cached counts claimed current")
				local merged = model.merge_details(previous, status)
				assert(merged.incomplete and merged.detail_incomplete and merged.counts.complete == false)
				merged = model.merge_summary(merged, {
					root = repo.root,
					vcs = "git",
					name = "repo",
					sections = {},
					counts = { local_changes = 8, staged = 0 },
					sync = {},
					summary_loaded = true,
					details_loaded = false,
				})
				assert(
					merged.incomplete and merged.counts.complete == false,
					"complete sibling summary cleared incomplete details"
				)
			end,
		},
		{
			"test_source_control_a3_svn_status_cap_loads_independent_info",
			function()
				local repo = { root = h.tempdir(), vcs = "svn", name = "repo" }
				local status, calls = nil, 0
				model.load_repo_summary_async(repo, {}, function(args, _, done)
					calls = calls + 1
					if args[2] == "status" then
						return done({ code = 0, stdout = "<status><target><entry", stdout_truncated = true })
					end
					assert(
						args[2] == "info" and vim.tbl_contains(args, "empty"),
						"overflow did not use shallow independent local info"
					)
					done({
						code = 0,
						stdout = '<info><entry kind="dir" path="."><url>file:///repo/branches/feature%20one</url><repository><root>file:///repo</root></repository></entry></info>',
					})
				end, function(value)
					status = value
				end)
				assert(calls == 2 and status and status.incomplete and status.branch == "feature one")
				assert(status.counts.complete == false and #status.sections == 0, "truncated XML became local rows")
			end,
		},
		{
			"test_source_control_a3_incomplete_status_refuses_bulk_mutations",
			guarded(function()
				local root = h.tempdir()
				local repo = {
					root = root,
					vcs = "git",
					name = "repo",
					incomplete = true,
					error = "status incomplete",
					counts = { local_changes = 0, staged = 0 },
				}
				local state = { lazyvcs_repo_cache = { [root] = repo }, lazyvcs_commit_drafts = { [root] = "draft" } }
				local picker, jobs = require("lazyvcs.picker"), require("lazyvcs.source_control.jobs")
				local select, command, summary = picker.select, jobs.command, model.load_repo_summary_async
				local spawned = 0
				require("lazyvcs").setup({ source_control = { confirm_mutations = false } })
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function() end
				---@diagnostic disable-next-line: duplicate-set-field
				picker.select = function(_, _, done)
					done({ action = "stage_all" })
				end
				---@diagnostic disable-next-line: duplicate-set-field
				jobs.command = function()
					spawned = spawned + 1
				end
				---@diagnostic disable-next-line: duplicate-set-field
				model.load_repo_summary_async = function(_, _, _, done)
					done(repo)
				end
				local ok, err = xpcall(function()
					ops.repo_action_picker(state, { path = root })
					ops.commit_repo(state, { path = root })
				end, debug.traceback)
				picker.select, jobs.command, model.load_repo_summary_async = select, command, summary
				assert(ok, err)
				assert(spawned == 0, "incomplete state reached bulk mutation")
			end),
		},
	})
	local function push_fixture()
		local f = h.make_git_fixture()
		h.exec({ "git", "add", "-A" }, f.root)
		h.exec({ "git", "commit", "-m", "base" }, f.root)
		f.bare = h.tempdir() .. "/remote.git"
		h.exec({ "git", "init", "--bare", f.bare }, f.root)
		h.exec({ "git", "remote", "add", "origin", f.bare }, f.root)
		h.exec({ "git", "push", "origin", "HEAD:refs/heads/main" }, f.root)
		h.exec({ "git", "switch", "--no-track", "-c", "feature" }, f.root)
		h.exec({ "git", "config", "branch.feature.remote", "origin" }, f.root)
		h.exec({ "git", "config", "branch.feature.merge", "refs/heads/main" }, f.root)
		h.write_file(f.file, "outgoing\n")
		h.exec({ "git", "commit", "-am", "outgoing" }, f.root)
		f.before = util.trim(h.exec({ "git", "--git-dir", f.bare, "rev-parse", "refs/heads/main" }, f.root))
		return f
	end
	vim.list_extend(cases, {
		{
			"test_source_control_a3_mismatched_push_requires_explicit_upstream_policy",
			guarded(function()
				local picker = require("lazyvcs.picker")
				local select = picker.select
				require("lazyvcs").setup({
					source_control = { confirm_mutations = false, sync_button_behavior = "direct" },
				})
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function() end
				local ok, err = xpcall(function()
					for _, policy in ipairs({ "unset", "simple", "current", "matching", "nothing" }) do
						local f = push_fixture()
						if policy ~= "unset" then
							h.exec({ "git", "config", "push.default", policy }, f.root)
						end
						local state = {
							path = f.root,
							lazyvcs_repo_cache = {
								[f.root] = {
									root = f.root,
									vcs = "git",
									name = "repo",
									branch = "feature",
									upstream = "origin/main",
									counts = {},
									sync = { status = "outgoing" },
								},
							},
							lazyvcs_commit_drafts = {},
							lazyvcs_render = function() end,
						}
						for _, action in ipairs({ "push", "sync" }) do
							---@diagnostic disable-next-line: duplicate-set-field
							picker.select = function(_, _, done)
								done({ action = action })
							end
							ops.repo_action_picker(state, { path = f.root })
							ctx.wait_for(function()
								local job = require("lazyvcs.state").get_repo_job(f.root)
								return not job or job.status ~= "running"
							end, "push did not settle", 15000)
							assert(
								util.trim(
									h.exec({ "git", "--git-dir", f.bare, "rev-parse", "refs/heads/main" }, f.root)
								) == f.before,
								policy .. " pushed feature into main"
							)
							state.lazyvcs_repo_cache[f.root] = {
								root = f.root,
								vcs = "git",
								name = "repo",
								counts = {},
								sync = { status = "outgoing" },
							}
						end
					end
				end, debug.traceback)
				picker.select = select
				assert(ok, err)
			end),
		},
		{
			"test_source_control_a3_push_worker_rechecks_destination_and_policy",
			guarded(function()
				for _, changed in ipairs({ "destination", "policy", "branch" }) do
					local f = push_fixture()
					h.exec({ "git", "config", "push.default", "upstream" }, f.root)
					if changed == "destination" then
						h.exec({ "git", "config", "branch.feature.merge", "refs/heads/other" }, f.root)
					elseif changed == "policy" then
						h.exec({ "git", "config", "push.default", "simple" }, f.root)
					else
						h.exec({ "git", "switch", "--no-track", "-c", "other" }, f.root)
					end
					local done, failure
					require("lazyvcs.source_control.mutation_start").start(
						{ root = f.root, vcs = "git" },
						{ "git", "push", "--", "origin", "refs/heads/feature:refs/heads/main" },
						{ cwd = f.root, timeout = 15000 },
						{
							branch_ref = "refs/heads/feature",
							git_remote_intent = {
								branch = "feature",
								remote = "origin",
								target = "refs/heads/main",
								full = "refs/remotes/origin/main",
								policy = "upstream",
							},
						},
						function(_, err)
							done, failure = true, err
						end
					)
					ctx.wait_for(function()
						return done
					end, "guard did not settle", 15000)
					assert(failure, "changed destination was not refused")
					assert(
						util.trim(h.exec({ "git", "--git-dir", f.bare, "rev-parse", "refs/heads/main" }, f.root))
							== f.before
					)
				end
			end),
		},
	})

	vim.list_extend(cases, {
		{
			"test_source_control_a3_ai_reerror_eviction_keeps_fresh_diagnostic",
			guarded(function()
				local root = h.tempdir()
				---@diagnostic disable-next-line: duplicate-set-field
				util.notify = function() end
				ai.notify_error(root, "old")
				ai.clear_error(root)
				for i = 1, 31 do
					ai.notify_error(root .. "/" .. i, "other")
				end
				ai.notify_error(root, "fresh")
				ai.notify_error(root .. "/last", "last")
				assert(ai.last_error(root) == "fresh", "old cleared order slot evicted the new error")
			end),
		},
		{
			"test_source_control_a3_upstream_policy_confirmation_names_actual_destination",
			guarded(function()
				local confirm, picker = require("lazyvcs.source_control.confirm"), require("lazyvcs.picker")
				local mutation, select = confirm.mutation, picker.select
				local prompt
				---@diagnostic disable-next-line: duplicate-set-field
				confirm.mutation = function(opts, done)
					prompt = opts.prompt
					done()
				end
				local ok, err = xpcall(function()
					for _, action in ipairs({ "push", "sync" }) do
						local f = push_fixture()
						h.exec({ "git", "config", "push.default", "upstream" }, f.root)
						require("lazyvcs").setup({
							source_control = { confirm_mutations = true, sync_button_behavior = "direct" },
						})
						local state = {
							path = f.root,
							lazyvcs_repo_cache = {
								[f.root] = {
									root = f.root,
									vcs = "git",
									name = "repo",
									counts = {},
									sync = {
										status = "outgoing",
									},
								},
							},
							lazyvcs_render = function() end,
						}
						---@diagnostic disable-next-line: duplicate-set-field
						picker.select = function(_, _, done)
							done({ action = action })
						end
						ops.repo_action_picker(state, { path = f.root })
						ctx.wait_for(function()
							local job = require("lazyvcs.state").get_repo_job(f.root)
							return not job or job.status ~= "running"
						end, "push did not settle", 15000)
						assert(
							not require("lazyvcs.state").get_repo_job(f.root),
							vim.inspect(require("lazyvcs.state").get_repo_job(f.root))
						)
						assert(
							prompt and prompt:find("refs/heads/feature -> origin refs/heads/main", 1, true),
							"confirmation hid actual push destination"
						)
						assert(
							util.trim(h.exec({ "git", "--git-dir", f.bare, "rev-parse", "refs/heads/main" }, f.root))
								== util.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root))
						)
					end
				end, debug.traceback)
				confirm.mutation, picker.select = mutation, select
				assert(ok, err)
			end),
		},
	})

	cases[#cases + 1] = {
		"test_source_control_a3_cached_row_hidden_intent_never_loses_bytes",
		guarded(function()
			require("lazyvcs").setup({ source_control = { confirm_mutations = false } })
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function() end
			for _, flags in ipairs({
				{ "--assume-unchanged" },
				{ "--skip-worktree" },
				{ "--assume-unchanged", "--skip-worktree" },
			}) do
				local f = h.make_git_fixture()
				local rel = vim.fs.basename(f.file)
				h.write_file(f.file, "precious new contents\n")
				local before = table.concat(vim.fn.readfile(f.file, "b"), "\n")
				local repo = { root = f.root, vcs = "git", name = "repo" }
				local state =
					{ path = f.root, lazyvcs_repo_cache = { [f.root] = repo }, lazyvcs_render = function() end }
				local old = {
					type = "file",
					path = f.file,
					extra = {
						repo_root = f.root,
						relpath = rel,
						status = " M",
						section = "changes",
						change_kind = "modified",
					},
				}
				h.exec({ "git", "rm", "--cached", "-f", "--", rel }, f.root)
				h.exec({ "git", "add", "-N", "--", rel }, f.root)
				for _, flag in ipairs(flags) do
					h.exec({ "git", "update-index", flag, "--", rel }, f.root)
				end
				ops.revert_file(state, old)
				ctx.wait_for(function()
					for _, job in ipairs(require("lazyvcs.source_control.jobs").history()) do
						if job.root == f.root and job.kind == "discard_unstaged" then
							return true
						end
					end
				end, "discard did not settle", 15000)
				assert(
					table.concat(vim.fn.readfile(f.file, "b"), "\n") == before,
					"cached row erased hidden intent-to-add bytes"
				)
				assert(
					require("lazyvcs.state").get_repo_job(f.root).error,
					"hidden intent-to-add restore was not refused"
				)
			end
		end),
	}

	cases[#cases + 1] = {
		"test_source_control_a3_stale_ai_success_keeps_newer_diagnostic",
		guarded(function()
			local root = h.tempdir()
			local state, node = state_for(root)
			local callback
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function() end
			---@diagnostic disable-next-line: duplicate-set-field
			ai.generate = function(_, done)
				callback = done
				return { cancel = function() end }
			end
			ops.generate_commit_message(state, node)
			ops.cancel_commit_generations(state, root)
			ai.notify_error(root, "newer failure")
			callback("obsolete subject")
			assert(ai.last_error(root) == "newer failure" and state.lazyvcs_commit_drafts[root] == nil)
		end),
	}

	cases[#cases + 1] = {
		"test_source_control_a3_generated_subject_is_rendered_immediately",
		guarded(function()
			require("lazyvcs").setup({
				use_gitsigns = false,
				signs = { enabled = false },
				source_control = { remote_refresh = "manual", show_clean = true },
			})
			local native = require("lazyvcs.source_control.native")
			local f = h.make_git_fixture()
			local state = native.open({ path = f.root })
			local callback
			ctx.wait_for(function()
				return not state.lazyvcs_discovering
					and state.lazyvcs_repo_cache[f.root]
					and state.lazyvcs_repo_cache[f.root].summary_loaded
			end, "sidebar not ready", 15000)
			state.lazyvcs_force_expand = { [model.repo_changes_id(f.root)] = true }
			native.render(state)
			---@diagnostic disable-next-line: duplicate-set-field
			ai.generate = function(_, done)
				callback = done
				return { cancel = function() end }
			end
			local function text()
				return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
			end
			ops.generate_commit_message(state, { path = f.root })
			assert(text():find("Generating", 1, true))
			callback("Generate parser tests")
			assert(
				text():find("Generate parser tests", 1, true) and not text():find("Generating", 1, true),
				"generated draft absent from actual sidebar buffer"
			)
			native.close()
		end),
	}

	return cases
end
