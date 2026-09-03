-- Regression specs for source-control mutation and process-output safety.
--
-- This module keeps new cases out of tests/spec.lua, whose top-level chunk is
-- already at LuaJIT's local-variable limit.

---@class LazyVcsSafetySpecContext
---@field helpers table
---@field wait_for fun(predicate: function, msg: string?, timeout: number?)
---@field async_timeout_ms number

---@param ctx LazyVcsSafetySpecContext
---@return table[] cases
return function(ctx)
	local helpers = ctx.helpers
	local wait_for = ctx.wait_for
	local ASYNC_TIMEOUT_MS = ctx.async_timeout_ms

	local function find_first_node(root, node_type)
		if root.type == node_type then
			return root
		end
		for _, child in ipairs(root.children or {}) do
			local found = find_first_node(child, node_type)
			if found then
				return found
			end
		end
	end

	local function test_source_control_discard_refuses_loaded_modified_buffer()
		require("lazyvcs").setup({
			source_control = {
				scan_depth = 1,
				show_clean = true,
				confirm_mutations = false,
			},
		})

		local fixture = helpers.make_git_fixture()
		local model = require("lazyvcs.source_control.model")
		local ops = require("lazyvcs.source_control.ops")
		local session_state = require("lazyvcs.state")
		local specs = model.discover(fixture.root, 1)
		local state = {
			path = fixture.root,
			lazyvcs_commit_drafts = {},
			lazyvcs_repo_specs = specs,
			lazyvcs_repo_cache = {},
			lazyvcs_changes_sort = "path",
			lazyvcs_force_expand = {
				[model.repo_changes_id(fixture.root)] = true,
			},
			lazyvcs_render = function() end,
		}

		local completed = false
		model.load_repo_details_async(specs[1], { changes_sort = "path" }, function(args, opts, on_done)
			return require("lazyvcs.util").system_start(args, {
				cwd = opts.cwd or fixture.root,
				timeout = opts.timeout_ms,
			}, on_done)
		end, function(repo, err)
			assert(repo, err)
			state.lazyvcs_repo_cache[fixture.root] = repo
			completed = true
		end)
		wait_for(function()
			return completed
		end, "repository details should load", ASYNC_TIMEOUT_MS)

		local tree = model.collect(state, { root = fixture.root, scan_depth = 1 })
		local file_node = assert(find_first_node(tree, "file"), "missing changed-file node")
		local disk_before = vim.fn.readfile(fixture.file)

		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved editor text" })
		assert(vim.bo.modified, "test buffer should be modified")

		ops.revert_file(state, file_node)
		vim.wait(250, function()
			return session_state.get_repo_job(fixture.root) == nil
		end, 10)

		assert(vim.bo.modified, "discard refusal should preserve the modified buffer")
		assert(
			vim.deep_equal(vim.fn.readfile(fixture.file), disk_before),
			"discard must not change the file while its loaded buffer is modified"
		)
	end

	local function test_buffer_discard_refuses_modified_current_buffer()
		require("lazyvcs").setup({ source_control = { confirm_mutations = false } })

		local fixture = helpers.make_git_fixture()
		local buffer_ops = require("lazyvcs.buffer_ops")
		local disk_before = vim.fn.readfile(fixture.file)
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved editor text" })

		buffer_ops.revert_buffer()
		vim.wait(250, function()
			return false
		end, 10)

		assert(vim.bo.modified, "discard refusal should preserve the modified buffer")
		assert(
			vim.deep_equal(vim.fn.readfile(fixture.file), disk_before),
			"buffer discard must not change the file while the current buffer is modified"
		)
	end

	local function test_buffer_guard_preserves_a_tracked_symlink_path()
		local root = vim.fn.tempname()
		local outside = vim.fn.tempname()
		vim.fn.mkdir(root, "p")
		vim.fn.writefile({ "outside" }, outside)
		local link = root .. "/tracked-link"
		assert(vim.uv.fs_symlink(outside, link), "test symlink should be created")

		local ok, err = xpcall(function()
			vim.cmd.edit(vim.fn.fnameescape(link))
			vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved through symlink" })
			local modified = require("lazyvcs.source_control.buffer_guard").modified(root, { link })

			assert(#modified == 1, "a modified tracked symlink must block repository mutation")
			assert(
				modified[1].path == require("lazyvcs.util").canonical_entry_path(link),
				"the guard must report the repository entry, not its target"
			)
		end, debug.traceback)
		pcall(function()
			vim.cmd("bdelete!")
		end)
		pcall(vim.fn.delete, link)
		pcall(vim.fn.delete, root, "rf")
		pcall(vim.fn.delete, outside)
		if not ok then
			error(err, 0)
		end
	end

	local function test_buffer_discard_rechecks_before_restore()
		require("lazyvcs").setup({ source_control = { confirm_mutations = false } })

		local fixture = helpers.make_git_fixture()
		local backends = require("lazyvcs.backends")
		local confirm = require("lazyvcs.source_control.confirm")
		local util = require("lazyvcs.util")
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		assert(not vim.bo.modified, "test buffer should start clean")

		local previous_buffer_ops = package.loaded["lazyvcs.buffer_ops"]
		local previous_confirm_open = confirm.open
		local previous_is_versioned = backends.is_versioned_async
		local previous_revert = backends.revert_file_async
		local previous_system_start = util.system_start
		local revert_called = false
		local mutation_started = false
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			on_choice("confirm")
			return {}
		end
		---@diagnostic disable-next-line: duplicate-set-field
		backends.is_versioned_async = function(_, on_done)
			vim.schedule(function()
				on_done(true)
			end)
			return {}
		end
		---@diagnostic disable-next-line: duplicate-set-field
		backends.revert_file_async = function(_, on_done, opts)
			revert_called = true
			vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited while discard was preparing" })
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function()
				mutation_started = true
				return {}
			end
			assert(opts and opts.start, "buffer discard should guard the destructive process start")
			return opts.start({ "git", "restore", "--worktree", "--", "sample.txt" }, {}, function(result, err)
				on_done(result, err)
			end)
		end
		package.loaded["lazyvcs.buffer_ops"] = nil
		local buffer_ops = require("lazyvcs.buffer_ops")

		local ok, err = xpcall(function()
			buffer_ops.revert_buffer()
			wait_for(function()
				return revert_called
			end, "buffer discard should reach the backend", ASYNC_TIMEOUT_MS)
			assert(vim.bo.modified, "test buffer should become modified while discard is preparing")
			assert(not mutation_started, "discard must recheck the buffer before starting the restore command")
		end, debug.traceback)
		backends.is_versioned_async = previous_is_versioned
		backends.revert_file_async = previous_revert
		confirm.open = previous_confirm_open
		util.system_start = previous_system_start
		package.loaded["lazyvcs.buffer_ops"] = previous_buffer_ops
		if not ok then
			error(err, 0)
		end
	end

	local function test_source_control_switch_refuses_loaded_modified_buffer()
		require("lazyvcs").setup({ source_control = { confirm_mutations = false } })

		local fixture = helpers.make_git_fixture()
		local ops = require("lazyvcs.source_control.ops")
		local repo_switch = require("lazyvcs.source_control.switch")
		local session_state = require("lazyvcs.state")
		local util = require("lazyvcs.util")
		local repo = {
			root = fixture.root,
			name = "repo",
			vcs = "git",
			counts = { local_changes = 1, staged = 0, remote = 0 },
			sync = { status = "dirty" },
		}
		local state = {
			path = fixture.root,
			lazyvcs_commit_drafts = {},
			lazyvcs_repo_cache = { [fixture.root] = repo },
			lazyvcs_render = function() end,
		}
		local node = {
			type = "repo_changes",
			path = fixture.root,
			extra = { repo_root = fixture.root },
		}

		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved editor text" })

		local previous_open_async = repo_switch.open_async
		local previous_system_start = util.system_start
		local mutation_started = false
		---@diagnostic disable-next-line: duplicate-set-field
		repo_switch.open_async = function(target_repo, opts)
			opts.on_ready(target_repo)
			opts.run_mutation(
				target_repo,
				{ short = "other" },
				{ "git", "switch", "other" },
				{ cwd = target_repo.root }
			)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function()
			mutation_started = true
			return {}
		end

		local ok, err = xpcall(function()
			ops.switch_repo(state, node)
			assert(not mutation_started, "switch must not start while a repository buffer is modified")
			assert(session_state.get_repo_job(fixture.root) == nil, "refused switch must clear its pending job")
		end, debug.traceback)
		repo_switch.open_async = previous_open_async
		util.system_start = previous_system_start
		session_state.clear_repo_job(fixture.root)
		if not ok then
			error(err, 0)
		end
	end

	local function test_source_control_revision_mutations_refuse_loaded_modified_buffers()
		require("lazyvcs").setup({
			source_control = {
				confirm_mutations = false,
				sync_button_behavior = "direct",
			},
		})

		local fixture = helpers.make_git_fixture()
		local ops = require("lazyvcs.source_control.ops")
		local session_state = require("lazyvcs.state")
		local util = require("lazyvcs.util")
		local repo = {
			root = fixture.root,
			name = "repo",
			vcs = "git",
			branch = "main",
			counts = { local_changes = 0, staged = 0, remote = 1 },
			sync = { status = "incoming" },
		}
		local state = {
			path = fixture.root,
			lazyvcs_commit_drafts = {},
			lazyvcs_repo_cache = { [fixture.root] = repo },
			lazyvcs_render = function() end,
		}

		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved editor text" })

		local previous_system_start = util.system_start
		local mutation_started = false
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(_args, _opts, on_exit)
			mutation_started = true
			on_exit(nil, "mutation should have been refused", { code = 1, stdout = "", stderr = "" })
			return {}
		end

		local ok, err = xpcall(function()
			for _, case in ipairs({
				{ action = "pull", vcs = "git" },
				{ action = "sync", vcs = "git" },
				{ action = "update", vcs = "svn" },
			}) do
				repo.vcs = case.vcs
				mutation_started = false
				local node = {
					type = "action_button",
					path = fixture.root,
					extra = { repo_root = fixture.root, action = case.action },
				}
				ops.run_primary_action(state, node)
				assert(not mutation_started, case.action .. " must not start while a repository buffer is modified")
				assert(
					session_state.get_repo_job(fixture.root) == nil,
					"refused " .. case.action .. " must not leave a repository job"
				)
			end
		end, debug.traceback)
		util.system_start = previous_system_start
		session_state.clear_repo_job(fixture.root)
		if not ok then
			error(err, 0)
		end
	end

	local function test_source_control_pull_rechecks_buffers_before_merge()
		require("lazyvcs").setup({ source_control = { confirm_mutations = false } })

		local fixture = helpers.make_git_fixture()
		local ops = require("lazyvcs.source_control.ops")
		local session_state = require("lazyvcs.state")
		local util = require("lazyvcs.util")
		local repo = {
			root = fixture.root,
			name = "repo",
			vcs = "git",
			branch = "main",
			counts = { local_changes = 0, staged = 0, remote = 1 },
			sync = { status = "incoming" },
		}
		local state = {
			path = fixture.root,
			lazyvcs_commit_drafts = {},
			lazyvcs_repo_cache = { [fixture.root] = repo },
			lazyvcs_render = function() end,
		}
		local node = {
			type = "action_button",
			path = fixture.root,
			extra = { repo_root = fixture.root, action = "pull" },
		}

		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		assert(not vim.bo.modified, "test buffer should start clean")

		local previous_system_start = util.system_start
		local calls = {}
		local responses = {
			["git branch --show-current"] = "main\n",
			["git for-each-ref --format=%(upstream:short) refs/heads/main"] = "origin/main\n",
			["git fetch --prune --quiet origin"] = "",
			["git status --branch --porcelain=v1 --untracked-files=no --ignored=no"] = "## main...origin/main [behind 1]\n",
			["git merge --ff-only origin/main"] = "",
		}
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, _, on_exit)
			local key = table.concat(args, " ")
			calls[#calls + 1] = key
			assert(responses[key] ~= nil, "unexpected command: " .. key)
			if key == "git fetch --prune --quiet origin" then
				vim.api.nvim_buf_set_lines(0, 0, -1, false, { "edited while fetch was running" })
			end
			local result = { code = 0, stdout = responses[key], stderr = "" }
			on_exit(result, nil, result)
			return {}
		end

		local ok, err = xpcall(function()
			ops.run_primary_action(state, node)
			assert(vim.bo.modified, "test buffer should become modified during pull preparation")
			assert(
				not vim.tbl_contains(calls, "git merge --ff-only origin/main"),
				"pull must recheck loaded buffers before changing the worktree"
			)
			local job = assert(session_state.get_repo_job(fixture.root), "refused pull should report its failure")
			assert(job.status == "error", "refused pull should finish as an error")
			assert(job.error and job.error:match("modified buffers"), "refused pull should explain the buffer guard")
		end, debug.traceback)
		util.system_start = previous_system_start
		session_state.clear_repo_job(fixture.root)
		if not ok then
			error(err, 0)
		end
	end

	local function test_async_system_reports_per_stream_truncation()
		local util = require("lazyvcs.util")
		local previous_system = vim.system
		local process_exit
		local system_opts
		local callback_result
		local callback_raw
		---@diagnostic disable-next-line: duplicate-set-field
		vim.system = function(_, opts, on_exit)
			system_opts = opts
			process_exit = on_exit
			return { kill = function() end }
		end

		local ok, err = xpcall(function()
			util.system_start({ "fake-output" }, { output_limit = 256 }, function(result, callback_err, raw)
				assert(not callback_err, callback_err)
				callback_result = result
				callback_raw = raw
			end)
			system_opts.stdout(nil, string.rep("x", 400))
			system_opts.stderr(nil, string.rep("y", 400))
			process_exit({ code = 0, signal = 0, stdout = "", stderr = "" })
			wait_for(function()
				return callback_result ~= nil
			end, "async process callback should complete")

			assert(callback_result.stdout_truncated == true, "stdout truncation should be explicit")
			assert(callback_result.stderr_truncated == true, "stderr truncation should be explicit")
			assert(callback_raw.stdout_truncated == true, "raw result should preserve stdout truncation")
			assert(callback_raw.stderr_truncated == true, "raw result should preserve stderr truncation")
		end, debug.traceback)
		vim.system = previous_system
		if not ok then
			error(err, 0)
		end
	end

	local function test_source_control_status_hydration_refuses_truncated_output()
		require("lazyvcs").setup()
		local model = require("lazyvcs.source_control.model")
		local git_status = "## main\n M sample.txt\n"
		local svn_status = [[
			<?xml version="1.0"?>
			<status><target path="."></target></status>
		]]

		for _, case in ipairs({
			{
				name = "Git summary",
				vcs = "git",
				loader = model.load_repo_summary_async,
				stdout = git_status,
				truncate_call = 1,
			},
			{
				name = "Git details",
				vcs = "git",
				loader = model.load_repo_details_async,
				stdout = git_status,
				truncate_call = 2,
			},
			{
				name = "SVN summary",
				vcs = "svn",
				loader = model.load_repo_summary_async,
				stdout = svn_status,
				truncate_call = 1,
			},
			{
				name = "SVN details",
				vcs = "svn",
				loader = model.load_repo_details_async,
				stdout = svn_status,
				truncate_call = 2,
			},
		}) do
			local calls = 0
			local loaded
			local load_err
			case.loader({ root = "/repo", name = "repo", vcs = case.vcs }, {}, function(_, _, on_done)
				calls = calls + 1
				local result = {
					code = 0,
					stdout = case.stdout,
					stderr = "",
					stdout_truncated = calls == case.truncate_call,
					stderr_truncated = false,
				}
				on_done(result, nil, result)
			end, function(result, err)
				loaded = result
				load_err = err
			end)

			assert(loaded == nil, case.name .. " must not return partial repository state")
			assert(load_err and load_err:match("truncated"), case.name .. " should report truncation")
			assert(calls == case.truncate_call, case.name .. " should stop after the truncated command")
		end

		for _, case in ipairs({
			{ name = "Git remote list", truncate_call = 2 },
			{ name = "refreshed Git status", truncate_call = 4 },
		}) do
			local calls = 0
			local loaded
			local load_err
			local outputs = {
				"## main...origin/main\n",
				"origin\n",
				"",
				"## main...origin/main [behind 1]\n",
			}
			model.load_repo_summary_async(
				{ root = "/repo", name = "repo", vcs = "git" },
				{ remote_refresh = true },
				function(_, _, on_done)
					calls = calls + 1
					local result = {
						code = 0,
						stdout = outputs[calls],
						stderr = "",
						stdout_truncated = calls == case.truncate_call,
						stderr_truncated = false,
					}
					on_done(result, nil, result)
				end,
				function(result, err)
					loaded = result
					load_err = err
				end
			)

			assert(loaded == nil, case.name .. " must not return partial repository state")
			assert(load_err and load_err:match("truncated"), case.name .. " should report truncation")
			assert(calls == case.truncate_call, case.name .. " should stop after the truncated command")
		end
	end

	return {
		{
			"test_source_control_discard_refuses_loaded_modified_buffer",
			test_source_control_discard_refuses_loaded_modified_buffer,
		},
		{
			"test_buffer_discard_refuses_modified_current_buffer",
			test_buffer_discard_refuses_modified_current_buffer,
		},
		{
			"test_buffer_guard_preserves_a_tracked_symlink_path",
			test_buffer_guard_preserves_a_tracked_symlink_path,
		},
		{
			"test_buffer_discard_rechecks_before_restore",
			test_buffer_discard_rechecks_before_restore,
		},
		{
			"test_source_control_switch_refuses_loaded_modified_buffer",
			test_source_control_switch_refuses_loaded_modified_buffer,
		},
		{
			"test_source_control_revision_mutations_refuse_loaded_modified_buffers",
			test_source_control_revision_mutations_refuse_loaded_modified_buffers,
		},
		{
			"test_source_control_pull_rechecks_buffers_before_merge",
			test_source_control_pull_rechecks_buffers_before_merge,
		},
		{
			"test_async_system_reports_per_stream_truncation",
			test_async_system_reports_per_stream_truncation,
		},
		{
			"test_source_control_status_hydration_refuses_truncated_output",
			test_source_control_status_hydration_refuses_truncated_output,
		},
	}
end
