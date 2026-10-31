return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local util = require("lazyvcs.util")
	local model = require("lazyvcs.source_control.model")
	local function mutation(f, args, guards)
		local done, failure
		require("lazyvcs.source_control.mutation_start").start(
			{ root = f.root, vcs = "git" },
			args,
			{ cwd = f.root, timeout = 15000 },
			guards,
			function(_, err)
				failure = err
				done = true
			end
		)
		wait(function()
			return done
		end, "mutation did not finish", 20000)
		return failure
	end
	local cases = {
		{
			"test_source_control_a3_intent_to_add_discard_preserves_bytes",
			function()
				local f = h.make_git_fixture()
				local path = f.root .. "/precious"
				h.write_file(path, "precious bytes\n")
				h.exec({ "git", "add", "-N", "--", "precious" }, f.root)
				local err = mutation(f, { "git", "restore", "--worktree", "--", "precious" }, {
					guard_modified_buffers = true,
					guard_paths = { path },
					guard_relpaths = { "precious" },
					git_intent_guard = "precious",
				})
				assert(err, "intent-to-add must be refused")
				assert(table.concat(vim.fn.readfile(path), "\n") == "precious bytes", "bytes lost")
			end,
		},
		{
			"test_source_control_a3_staged_delete_collision_preserves_bytes",
			function()
				local f = h.make_git_fixture()
				local rel = vim.fs.basename(f.file)
				h.exec({ "git", "rm", "-f", "--", rel }, f.root)
				h.write_file(f.file, "independent replacement\n")
				local err = mutation(f, { "git", "restore", "--source=HEAD", "--staged", "--worktree", "--", rel }, {
					guard_modified_buffers = true,
					guard_paths = { f.file },
					guard_relpaths = { rel },
					git_head_restore = {
						rel,
					},
				})
				assert(err, "independent file collision must be refused")
				assert(vim.fn.readfile(f.file)[1] == "independent replacement", "replacement lost")
			end,
		},
		{
			"test_source_control_a3_pending_remote_does_not_lose_completed_snapshot",
			function()
				local remote = require("lazyvcs.source_control.remote_refresh")
				local root = h.tempdir()
				local first = remote.begin(root)
				local second = remote.begin(root)
				assert(remote.publish(first, { { relpath = "a" } }), "older success must survive pending newer check")
				assert(remote.read(root).items[1].relpath == "a")
				assert(remote.publish(second, { { relpath = "b" } }))
				local stale = remote.begin(root)
				remote.invalidate(root)
				assert(not remote.publish(stale, {}), "invalidated result published")
			end,
		},
		{
			"test_source_control_a3_preferences_merge_only_explicit_changes",
			function()
				local p = require("lazyvcs.source_control.persist")
				local root = h.tempdir()
				require("lazyvcs").setup({ source_control = { selection_mode = "multiple" } })
				local a, b = { path = root }, { path = root }
				p.apply_state(a, root)
				p.apply_state(b, root)
				model.collect(a, { root = root })
				model.collect(b, { root = root })
				p.save_state(a)
				assert(p.load(root).changes_view_mode == nil, "defaults must not freeze")
				b.lazyvcs_changes_view_mode = "tree"
				p.save_state(b)
				a.lazyvcs_changes_sort = "name"
				p.save_state(a)
				local saved = p.load(root)
				assert(saved.changes_view_mode == "tree", "stale save reverted view")
				assert(saved.changes_sort == "name")
			end,
		},
	}
	local function load(f, loader)
		local status, failure, done
		loader({ root = f.root, vcs = "git", name = "repo" }, {}, function(args, opts, cb)
			return util.system_start(args, { cwd = f.root, output_limit = opts.output_limit_bytes }, cb)
		end, function(value, err)
			status, failure, done = value, err, true
		end)
		wait(function()
			return done
		end, "load timed out", 15000)
		return assert(status, failure)
	end
	vim.list_extend(cases, {
		{
			"test_source_control_a3_one_bounded_detail_scan_and_unborn_metadata",
			function()
				local calls = {}
				---@type lazyvcs.RepositoryStatus?
				local status
				model.load_repo_details_async(
					{ root = h.tempdir(), vcs = "git", name = "repo" },
					{ previous = { has_remotes = false } },
					function(args, opts, done)
						calls[#calls + 1] = args
						assert(opts.output_limit_bytes == 64 * 1024 * 1024, "stdout budget is not 32 MiB")
						done({
							code = 0,
							stdout = "# branch.oid (initial)\0# branch.head main\0# branch.upstream origin/main\0? new\0",
						})
					end,
					function(result, err)
						status = assert(result, err)
					end
				)
				status = assert(status)
				assert(#calls == 1 and vim.tbl_contains(calls[1], "--porcelain=v2"))
				assert(status.unborn and status.branch == "main" and status.upstream == "origin/main")
				assert(status.counts.local_changes == 1 and status.counts.staged == 0)
			end,
		},
		{
			"test_source_control_a3_no_remote_is_clean_and_fetch_without_upstream",
			function()
				local f = h.make_git_fixture()
				h.exec({ "git", "add", "-A" }, f.root)
				h.exec({ "git", "commit", "-m", "clean" }, f.root)
				local status = load(f, model.load_repo_summary_async)
				assert(
					status.has_remotes == false and status.sync.status == "synced",
					"remote-less repo offers Publish"
				)
				local fetched, loaded = false, nil
				model.load_repo_summary_async(
					{ root = f.root, vcs = "git", name = "repo" },
					{ remote_refresh = true },
					function(args, command_opts, done)
						if args[2] == "remote" then
							assert(command_opts.kind == "summary", "local remote-list metadata requested remote scope")
						elseif args[2] == "fetch" then
							assert(command_opts.kind == "remote", "fetch lost remote scope")
							fetched = true
						end
						done({
							code = 0,
							stdout = args[2] == "remote" and "origin\n" or args[2] == "status" and "## main\n" or "",
						})
					end,
					function(result, err)
						loaded = assert(result, err)
					end
				)
				assert(fetched and assert(loaded).has_remotes, "explicit remote refresh skipped untracked branch")
			end,
		},
		{
			"test_source_control_a3_conflicts_cannot_enter_stage_all_commit",
			function()
				local f = h.make_git_fixture()
				local oid = h.exec({ "git", "rev-parse", "HEAD:sample.txt" }, f.root):gsub("%s+$", "")
				h.exec({ "git", "update-index", "--force-remove", "sample.txt" }, f.root)
				local index = "100644 "
					.. oid
					.. " 1\tsample.txt\n100644 "
					.. oid
					.. " 2\tsample.txt\n100644 "
					.. oid
					.. " 3\tsample.txt\n"
				local result = vim.system({ "git", "update-index", "--index-info" }, { cwd = f.root, stdin = index })
					:wait()
				assert(result.code == 0)
				local summary, detail = load(f, model.load_repo_summary_async), load(f, model.load_repo_details_async)

				assert(
					summary.counts.staged == 0
						and detail.counts.staged == 0
						and summary.counts.conflicts == 1
						and detail.counts.conflicts == 1
				)
				assert(
					mutation(f, { "git", "add", "-A" }, { git_require_resolved = true }),
					"unresolved index reached stage all"
				)
				assert(h.exec({ "git", "ls-files", "--unmerged" }, f.root) ~= "", "stage all resolved index implicitly")
			end,
		},
		{
			"test_source_control_a3_ai_context_preserves_utf8_and_escapes_invalid_bytes",
			function()
				local convert = require("lazyvcs.source_control.ai")._test_utf8_context
				assert(convert("café " .. string.char(233, 128) .. " ✓") == "café \\xE9\\x80 ✓")
				assert(convert(string.char(237, 160, 128)) == "\\xED\\xA0\\x80", "surrogate bytes entered JSON")
			end,
		},
		{
			"test_source_control_a3_sidebar_mappings_toggle_and_active_highlights",
			function()
				require("lazyvcs").setup({ source_control = { remote_refresh = "manual", show_clean = true } })
				local native = require("lazyvcs.source_control.native")
				local f = h.make_git_fixture()
				local other = h.tempdir()
				local state = native.open({ path = f.root })
				wait(function()
					return not state.lazyvcs_discovering
						and state.lazyvcs_repo_cache[f.root]
						and not state.lazyvcs_repo_cache[f.root].loading_summary
				end, "sidebar not loaded", 15000)
				local space, mouse
				for _, map in ipairs(vim.api.nvim_buf_get_keymap(state.bufnr, "n")) do
					if map.lhs == " " then
						space = map
					end
					if map.lhs == "<2-LeftMouse>" then
						mouse = map
					end
				end
				assert(space and space.nowait == 0 and mouse, "sidebar captures Space leaders or omits double-click")
				state.lazyvcs_repo_cache[f.root] = load(f, model.load_repo_details_async)
				state.lazyvcs_force_expand = { [model.repo_changes_id(f.root)] = true }
				native.render(state)
				local file_line
				for line, node in pairs(state.lazyvcs_line_nodes) do
					if node.type == "file" then
						file_line = line
						assert(
							(vim.api.nvim_buf_get_lines(state.bufnr, line - 1, line, false)[1]):match("M$"),
							"status letter not flush right"
						)
					end
				end
				assert(file_line, "first activation did not expand sections")
				local active
				for _, mark in
					ipairs(
						vim.api.nvim_buf_get_extmarks(
							state.bufnr,
							-1,
							{ file_line - 1, 0 },
							{ file_line - 1, -1 },
							{ details = true }
						)
					)
				do
					if mark[4].hl_group == "LazyVcsFile" then
						active = true
					end
				end
				assert(active, "active file styled as disabled")
				local switched = native.toggle({ path = other })
				assert(switched and switched.path == other, "toggle closed instead of switching path")
				native.toggle({ path = other .. "/./" })
				assert(
					not native._state() or not vim.api.nvim_win_is_valid(native._state().winid),
					"equivalent path did not close"
				)
			end,
		},
	})
	vim.list_extend(cases, {
		{
			"test_source_control_a3_remote_branch_creation_does_not_track",
			function()
				local f = h.make_git_fixture()
				h.exec({ "git", "config", "branch.autoSetupMerge", "always" }, f.root)
				h.exec({ "git", "remote", "add", "origin", f.root }, f.root)
				h.exec({ "git", "update-ref", "refs/remotes/origin/main", "HEAD" }, f.root)
				local mutated
				require("lazyvcs.source_control.switch").open_async({ root = f.root, vcs = "git", name = "repo" }, {
					select = function(items, _, done)
						for _, item in ipairs(items) do
							if
								item.action == "git_create_branch_from"
								or item.refname == "refs/remotes/origin/main"
							then
								return done(item)
							end
						end
						error("branch choice missing")
					end,
					input = function(_, done)
						done("topic")
					end,
					run_mutation = function(_, _, args)
						h.exec(args, f.root)
						mutated = true
					end,
				}, function(args, opts, done)
					return util.system_start(args, { cwd = f.root, timeout = opts.timeout_ms }, done)
				end)
				wait(function()
					return mutated
				end, "branch was not created", 15000)
				assert(h.exec({ "git", "branch", "--show-current" }, f.root):match("topic"))
				local upstream = vim.system({ "git", "rev-parse", "--abbrev-ref", "@{upstream}" }, { cwd = f.root })
					:wait()
				assert(upstream.code ~= 0, "new branch inherited remote main upstream")
			end,
		},
		{
			"test_source_control_a3_ai_draft_confirmation_ownership",
			function()
				local ai, picker, ops =
					require("lazyvcs.source_control.ai"),
					require("lazyvcs.picker"),
					require("lazyvcs.source_control.ops")
				local generate, select = ai.generate, picker.select
				local completed, choose
				---@diagnostic disable-next-line: duplicate-set-field
				ai.generate = function(_, done)
					completed = done
					return { cancel = function() end }
				end
				---@diagnostic disable-next-line: duplicate-set-field
				picker.select = function(_, _, done)
					choose = done
				end
				local ok, err = xpcall(function()
					for _, choice in ipairs({ "Replace", "Keep", "dismiss", "cancel" }) do
						local root = h.tempdir()
						local state = {
							lazyvcs_repo_cache = { [root] = { root = root, vcs = "git", name = "repo" } },
							lazyvcs_commit_drafts = { [root] = "draft" },
							lazyvcs_repaint = function() end,
						}
						ops.generate_commit_message(state, { path = root })
						assert(state.lazyvcs_commit_pending[root])
						completed("generated")
						assert(state.lazyvcs_commit_drafts[root] == "draft" and choose)
						if choice == "cancel" then
							ops.cancel_commit_generations(state, root)
						end
						if choice == "dismiss" then
							choose(nil)
						else
							choose(choice == "cancel" and "Replace" or choice)
						end
						assert(state.lazyvcs_commit_drafts[root] == (choice == "Replace" and "generated" or "draft"))
					end
				end, debug.traceback)
				ai.generate, picker.select = generate, select
				assert(ok, err)
			end,
		},
		{
			"test_source_control_a3_file_save_refreshes_local_rows",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { remote_refresh = "manual", show_clean = true },
				})
				local native = require("lazyvcs.source_control.native")
				local f = h.make_git_fixture()
				local state = native.open({ path = f.root })
				wait(function()
					return not state.lazyvcs_discovering
						and state.lazyvcs_repo_cache[f.root]
						and state.lazyvcs_repo_cache[f.root].summary_loaded
				end, "summary not ready", 15000)
				assert(state.lazyvcs_repo_cache[f.root].counts.local_changes == 1)
				vim.api.nvim_set_current_win(state.editor_winid)
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/saved.txt"))
				vim.api.nvim_buf_set_lines(0, 0, -1, false, { "saved change" })
				vim.cmd.write()
				wait(function()
					return state.lazyvcs_repo_cache[f.root].counts.local_changes == 2
				end, "save did not refresh local status", 15000)
				native.close()
			end,
		},
	})

	cases[#cases + 1] = {
		"test_source_control_a3_large_status_keeps_complete_counts",
		function()
			require("lazyvcs").setup({
				use_gitsigns = false,
				signs = { enabled = false },
				source_control = { remote_refresh = "manual", show_clean = true },
			})
			local f = h.make_git_fixture()
			for i = 1, 6000 do
				local fd =
					assert(vim.uv.fs_open(f.root .. string.format("/file%05d-", i) .. string.rep("x", 90), "w", 384))
				assert(vim.uv.fs_close(fd))
			end
			local native = require("lazyvcs.source_control.native")
			local state = native.open({ path = f.root })
			wait(function()
				return not state.lazyvcs_discovering
					and state.lazyvcs_repo_cache[f.root]
					and state.lazyvcs_repo_cache[f.root].summary_loaded
			end, "large summary did not finish", 20000)
			local status = state.lazyvcs_repo_cache[f.root]
			assert(not status.error, status.error)
			assert(status.counts.local_changes == 6001, "large summary lost paths")
			require("lazyvcs.source_control.ops").load_repo_details(state, f.root)
			wait(function()
				return state.lazyvcs_repo_cache[f.root].details_loaded
			end, "large details did not finish", 20000)
			assert(state.lazyvcs_repo_cache[f.root].counts.local_changes == 6001, "large details lost paths")
			native.close()
		end,
	}

	vim.list_extend(cases, {
		{
			"test_source_control_a3_split_actions_use_invoking_selection",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { confirm_mutations = false, remote_refresh = "manual", show_clean = true },
				})
				local f = h.make_git_fixture()
				h.write_file(f.root .. "/new.txt", "new bytes\n")
				local native = require("lazyvcs.source_control.native")
				local state = native.open({ path = f.root })
				wait(function()
					return not state.lazyvcs_discovering
						and state.lazyvcs_repo_cache[f.root]
						and state.lazyvcs_repo_cache[f.root].summary_loaded
				end, "summary not ready", 15000)
				state.lazyvcs_repo_cache[f.root] = load(f, model.load_repo_details_async)
				state.lazyvcs_force_expand = { [model.repo_changes_id(f.root)] = true }
				native.render(state)
				local original, new
				for line, node in pairs(state.lazyvcs_line_nodes) do
					if node.type == "file" then
						if node.extra.relpath == "new.txt" then
							new = line
						else
							original = line
						end
					end
				end
				vim.api.nvim_win_set_cursor(state.winid, { assert(original), 0 })
				vim.cmd("split")
				local split = vim.api.nvim_get_current_win()
				vim.api.nvim_win_set_cursor(split, { assert(new), 0 })
				native.dispatch("stage_file")
				wait(function()
					return not require("lazyvcs.state").get_repo_job(f.root)
				end, "stage did not settle", 15000)
				assert(
					util.trim(h.exec({ "git", "diff", "--cached", "--name-only" }, f.root)) == "new.txt",
					"split staged original window's row"
				)
				vim.api.nvim_win_close(split, true)
				native.close()
			end,
		},
		{
			"test_source_control_a3_refresh_preserves_file_across_status_change",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { remote_refresh = "manual", show_clean = true },
				})
				local f = h.make_git_fixture()
				for _, name in ipairs({ "a", "b", "c" }) do
					h.write_file(f.root .. "/" .. name, "base\n")
				end
				h.exec({ "git", "add", "-A" }, f.root)
				h.exec({ "git", "commit", "-m", "files" }, f.root)
				for _, name in ipairs({ "a", "b", "c" }) do
					h.write_file(f.root .. "/" .. name, "changed\n")
				end
				local native = require("lazyvcs.source_control.native")
				local state = native.open({ path = f.root })
				wait(function()
					return not state.lazyvcs_discovering
						and state.lazyvcs_repo_cache[f.root]
						and state.lazyvcs_repo_cache[f.root].summary_loaded
				end, "summary not ready", 15000)
				state.lazyvcs_repo_cache[f.root] = load(f, model.load_repo_details_async)
				state.lazyvcs_force_expand = { [model.repo_changes_id(f.root)] = true }
				native.render(state)
				for line, node in pairs(state.lazyvcs_line_nodes) do
					if node.type == "file" and node.extra.relpath == "b" then
						vim.api.nvim_win_set_cursor(state.winid, { line, 0 })
					end
				end
				h.exec({ "git", "restore", "--", "a" }, f.root)
				assert(vim.uv.fs_unlink(f.root .. "/b"))
				native.refresh(false)
				wait(function()
					return not state.lazyvcs_discovering
						and state.lazyvcs_repo_cache[f.root]
						and state.lazyvcs_repo_cache[f.root].details_loaded
				end, "refresh details not restored", 15000)
				native.render(state)
				local node = state.lazyvcs_line_nodes[vim.api.nvim_win_get_cursor(state.winid)[1]]
				assert(
					node and node.extra.relpath == "b" and node.extra.status == " D",
					"selection lost when status changed"
				)
				native.close()
			end,
		},
	})

	return cases
end
