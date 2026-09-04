-- Regression specs for source-control mutation and process-output safety.
--
-- This module keeps new cases out of tests/spec.lua, whose top-level chunk is
-- already at LuaJIT's local-variable limit.

---@class LazyVcsSafetySpecContext
---@field helpers table
---@field wait_for fun(predicate: function, msg: string?, timeout: number?)
---@field async_timeout_ms number
---@field open_diff fun(): table

---@param ctx LazyVcsSafetySpecContext
---@return table[] cases
return function(ctx)
	local helpers = ctx.helpers
	local wait_for = ctx.wait_for
	local ASYNC_TIMEOUT_MS = ctx.async_timeout_ms
	local open_diff = ctx.open_diff

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

	local function test_buffer_discard_session_choice_suppresses_second_prompt()
		require("lazyvcs").setup({ source_control = { confirm_mutations = true } })

		local fixture = helpers.make_git_fixture()
		local backends = require("lazyvcs.backends")
		local buffer_ops = require("lazyvcs.buffer_ops")
		local confirm = require("lazyvcs.source_control.confirm")
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))

		local previous_confirm_open = confirm.open
		local previous_is_versioned = backends.is_versioned_async
		local previous_revert = backends.revert_file_async
		local prompt_count = 0
		local revert_count = 0
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			prompt_count = prompt_count + 1
			on_choice("confirm_session")
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
		backends.revert_file_async = function(_, on_done)
			revert_count = revert_count + 1
			vim.schedule(function()
				on_done({ code = 0, stdout = "", stderr = "" })
			end)
			return {}
		end

		local ok, err = xpcall(function()
			buffer_ops.revert_buffer()
			wait_for(function()
				return revert_count == 1
			end, "first direct discard should reach the backend", ASYNC_TIMEOUT_MS)
			buffer_ops.revert_buffer()
			wait_for(function()
				return revert_count == 2
			end, "second direct discard should reach the backend", ASYNC_TIMEOUT_MS)
			assert(prompt_count == 1, "option 2 should suppress the second direct discard prompt")
		end, debug.traceback)
		backends.is_versioned_async = previous_is_versioned
		backends.revert_file_async = previous_revert
		confirm.open = previous_confirm_open
		if confirm._test_reset_session then
			confirm._test_reset_session()
		end
		if not ok then
			error(err, 0)
		end
	end

	local function test_buffer_discard_cancel_releases_request_owner()
		require("lazyvcs").setup({ source_control = { confirm_mutations = true } })

		local fixture = helpers.make_git_fixture()
		local backends = require("lazyvcs.backends")
		local buffer_ops = require("lazyvcs.buffer_ops")
		local confirm = require("lazyvcs.source_control.confirm")
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))

		local previous_confirm_open = confirm.open
		local previous_is_versioned = backends.is_versioned_async
		local previous_revert = backends.revert_file_async
		local revert_count = 0
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			on_choice("cancel")
			return {}
		end
		---@diagnostic disable-next-line: duplicate-set-field
		backends.is_versioned_async = function(_, on_done)
			on_done(true)
			return {}
		end
		---@diagnostic disable-next-line: duplicate-set-field
		backends.revert_file_async = function()
			revert_count = revert_count + 1
			return {}
		end

		local ok, err = xpcall(function()
			local owner = assert(buffer_ops.revert_buffer(), "discard request should return its owner")
			assert(owner.active == false, "canceling the confirmation should release the discard request owner")
			assert(revert_count == 0, "canceling the confirmation must not reach the backend")
		end, debug.traceback)
		backends.is_versioned_async = previous_is_versioned
		backends.revert_file_async = previous_revert
		confirm.open = previous_confirm_open
		if not ok then
			error(err, 0)
		end
	end

	local function test_source_control_confirm_session_survives_sidebar_reopen()
		require("lazyvcs").setup({ source_control = { confirm_mutations = true } })

		local root = helpers.tempdir()
		local confirm = require("lazyvcs.source_control.confirm")
		local model = require("lazyvcs.source_control.model")
		local native = require("lazyvcs.source_control.native")
		local ops = require("lazyvcs.source_control.ops")
		local persist = require("lazyvcs.source_control.persist")
		local util = require("lazyvcs.util")
		local previous_confirm_open = confirm.open
		local previous_discover = model.discover_async
		local previous_save_state = persist.save_state
		local previous_system_start = util.system_start
		local prompt_count = 0
		local mutation_count = 0
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			prompt_count = prompt_count + 1
			on_choice("confirm_session")
			return {}
		end
		---@diagnostic disable-next-line: duplicate-set-field
		model.discover_async = function()
			return { kill = function() end }
		end
		---@diagnostic disable-next-line: duplicate-set-field
		persist.save_state = function() end
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, _, on_exit)
			assert(table.concat(args, " "):match("^git add"), "unexpected mutation command")
			mutation_count = mutation_count + 1
			local result = { code = 0, stdout = "", stderr = "" }
			on_exit(result, nil, result)
			return {}
		end

		local repo = {
			root = root,
			name = "repo",
			vcs = "git",
			counts = { local_changes = 1, staged = 0, remote = 0 },
		}
		local node = {
			type = "file",
			path = root .. "/changed.txt",
			extra = { repo_root = root, relpath = "changed.txt" },
		}
		local function stage_from_open_sidebar()
			local state = native.open({ path = root, focus = false })
			state.lazyvcs_repo_cache[root] = repo
			ops.stage_file(state, node)
		end

		local ok, err = xpcall(function()
			stage_from_open_sidebar()
			wait_for(function()
				return mutation_count == 1
			end, "first sidebar mutation should start", ASYNC_TIMEOUT_MS)
			native.close()
			stage_from_open_sidebar()
			wait_for(function()
				return mutation_count == 2
			end, "reopened sidebar mutation should start", ASYNC_TIMEOUT_MS)
			assert(prompt_count == 1, "sidebar reopen should not restore mutation prompts for this session")
		end, debug.traceback)
		pcall(native.close)
		model.discover_async = previous_discover
		persist.save_state = previous_save_state
		util.system_start = previous_system_start
		confirm.open = previous_confirm_open
		if confirm._test_reset_session then
			confirm._test_reset_session()
		end
		if not ok then
			error(err, 0)
		end
	end

	local function test_direct_hunk_revert_uses_session_confirmation()
		require("lazyvcs").setup({
			debounce_ms = 0,
			use_gitsigns = false,
			source_control = { confirm_mutations = true },
		})

		local fixture = helpers.make_git_fixture()
		local confirm = require("lazyvcs.source_control.confirm")
		local signs = require("lazyvcs.signs")
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		local bufnr = vim.api.nvim_get_current_buf()
		local loaded = false
		signs.refresh(bufnr, true, function(state)
			loaded = state ~= nil
		end)
		wait_for(function()
			return loaded
		end, "direct signs state should load", ASYNC_TIMEOUT_MS)

		local previous_confirm_open = confirm.open
		local prompt_count = 0
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			prompt_count = prompt_count + 1
			on_choice("confirm_session")
			return {}
		end

		local ok, err = xpcall(function()
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			signs.revert_hunk()
			assert(vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] == "two", "first hunk revert should apply")
			vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "changed again" })
			signs.refresh(bufnr, false)
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			signs.revert_hunk()
			assert(vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] == "two", "second hunk revert should apply")
			assert(prompt_count == 1, "option 2 should suppress the second direct hunk revert prompt")
		end, debug.traceback)
		confirm.open = previous_confirm_open
		if confirm._test_reset_session then
			confirm._test_reset_session()
		end
		if not ok then
			error(err, 0)
		end
	end

	local function test_direct_hunk_revert_requires_explicit_confirmation()
		require("lazyvcs").setup({
			debounce_ms = 0,
			use_gitsigns = false,
			source_control = { confirm_mutations = true },
		})

		local fixture = helpers.make_git_fixture()
		local confirm = require("lazyvcs.source_control.confirm")
		local signs = require("lazyvcs.signs")
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		local bufnr = vim.api.nvim_get_current_buf()
		local loaded = false
		signs.refresh(bufnr, true, function(state)
			loaded = state ~= nil
		end)
		wait_for(function()
			return loaded
		end, "direct signs state should load", ASYNC_TIMEOUT_MS)

		local previous_confirm_open = confirm.open
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			on_choice(nil)
			return {}
		end

		local ok, err = xpcall(function()
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			local before = vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1]
			signs.revert_hunk()
			assert(
				vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] == before,
				"hunk revert must not run for an unknown confirmation choice"
			)
		end, debug.traceback)
		confirm.open = previous_confirm_open
		if not ok then
			error(err, 0)
		end
	end

	local function test_direct_hunk_revert_refuses_stale_buffer_state()
		require("lazyvcs").setup({
			debounce_ms = 0,
			use_gitsigns = false,
			source_control = { confirm_mutations = true },
		})

		local fixture = helpers.make_git_fixture()
		local confirm = require("lazyvcs.source_control.confirm")
		local signs = require("lazyvcs.signs")
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		local bufnr = vim.api.nvim_get_current_buf()
		local loaded = false
		signs.refresh(bufnr, true, function(state)
			loaded = state ~= nil
		end)
		wait_for(function()
			return loaded
		end, "direct signs state should load", ASYNC_TIMEOUT_MS)

		local previous_confirm_open = confirm.open
		local confirm_choice
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			confirm_choice = on_choice
			return {}
		end

		local ok, err = xpcall(function()
			vim.api.nvim_win_set_cursor(0, { 2, 0 })
			signs.revert_hunk()
			assert(type(confirm_choice) == "function", "hunk revert should wait for confirmation")
			vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "edited while confirmation was open" })
			confirm_choice("confirm")
			assert(
				vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] == "edited while confirmation was open",
				"confirmation must not reset a hunk after its buffer changes"
			)
		end, debug.traceback)
		confirm.open = previous_confirm_open
		if confirm._test_reset_session then
			confirm._test_reset_session()
		end
		if not ok then
			error(err, 0)
		end
	end

	local function test_sign_state_isolated_and_cleared_on_wipe()
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { debounce_ms = 0 },
		})

		local fixture = helpers.make_git_transfer_fixture()
		local signs = require("lazyvcs.signs")
		local function load(path)
			vim.cmd.edit(vim.fn.fnameescape(path))
			local bufnr = vim.api.nvim_get_current_buf()
			local loaded
			signs.refresh(bufnr, true, function(state)
				loaded = state
			end)
			wait_for(function()
				return loaded ~= nil
			end, "sign state should load for " .. path, ASYNC_TIMEOUT_MS)
			return bufnr, loaded
		end

		local first_bufnr, first_state = load(fixture.file1)
		local second_bufnr, second_state = load(fixture.file2)
		assert(first_bufnr ~= second_bufnr, "fixtures should use separate buffers")
		assert(first_state ~= second_state, "sign state must not be shared between buffers")
		assert(first_state.path == fixture.file1, "first buffer should keep its own sign path")
		assert(second_state.path == fixture.file2, "second buffer should keep its own sign path")
		assert(vim.deep_equal(first_state.base_lines, fixture.base1), "first buffer should keep its own base")
		assert(vim.deep_equal(second_state.base_lines, fixture.base2), "second buffer should keep its own base")

		vim.api.nvim_buf_delete(first_bufnr, { force = true })
		assert(signs.current_state(first_bufnr) == nil, "wiping a buffer must remove its sign state")
		assert(signs.current_state(second_bufnr) == second_state, "wiping one buffer must preserve another's state")
	end

	local function test_gitsigns_hunk_revert_refuses_changed_window()
		require("lazyvcs").setup({
			use_gitsigns = true,
			source_control = { confirm_mutations = true },
		})

		local fixture = helpers.make_git_fixture()
		local backends = require("lazyvcs.backends")
		local confirm = require("lazyvcs.source_control.confirm")
		local signs = require("lazyvcs.signs")
		local previous_gitsigns = package.loaded["gitsigns"]
		local previous_resolve_cached = backends.resolve_cached
		local reset_count = 0
		local hunks = { { added = { start = 2, count = 1 }, removed = { start = 2, count = 1 } } }
		package.loaded["gitsigns"] = {
			get_hunks = function()
				return hunks
			end,
			reset_hunk = function()
				reset_count = reset_count + 1
			end,
		}
		---@diagnostic disable-next-line: duplicate-set-field
		backends.resolve_cached = function()
			return { name = "git" }
		end
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))

		local previous_confirm_open = confirm.open
		local confirm_choice
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			confirm_choice = on_choice
			return {}
		end

		local ok, err = xpcall(function()
			signs.revert_hunk()
			assert(type(confirm_choice) == "function", "gitsigns revert should wait for confirmation")
			vim.cmd.enew()
			confirm_choice("confirm")
			assert(reset_count == 0, "confirmation must not invoke gitsigns in a different buffer")
		end, debug.traceback)
		confirm.open = previous_confirm_open
		package.loaded["gitsigns"] = previous_gitsigns
		backends.resolve_cached = previous_resolve_cached
		if confirm._test_reset_session then
			confirm._test_reset_session()
		end
		if not ok then
			error(err, 0)
		end
	end

	local function test_gitsigns_hunk_revert_refuses_changed_hunk_state()
		require("lazyvcs").setup({
			use_gitsigns = true,
			source_control = { confirm_mutations = true },
		})

		local fixture = helpers.make_git_fixture()
		local backends = require("lazyvcs.backends")
		local confirm = require("lazyvcs.source_control.confirm")
		local signs = require("lazyvcs.signs")
		local previous_gitsigns = package.loaded["gitsigns"]
		local previous_resolve_cached = backends.resolve_cached
		local hunks = { { added = { start = 2, count = 1 }, removed = { start = 2, count = 1 } } }
		local reset_count = 0
		package.loaded["gitsigns"] = {
			get_hunks = function()
				return hunks
			end,
			reset_hunk = function()
				reset_count = reset_count + 1
			end,
		}
		---@diagnostic disable-next-line: duplicate-set-field
		backends.resolve_cached = function()
			return { name = "git" }
		end
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		vim.api.nvim_win_set_cursor(0, { 2, 0 })

		local previous_confirm_open = confirm.open
		local confirm_choice
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			confirm_choice = on_choice
			return {}
		end

		local ok, err = xpcall(function()
			signs.revert_hunk()
			assert(type(confirm_choice) == "function", "gitsigns revert should wait for confirmation")
			hunks = { { added = { start = 4, count = 1 }, removed = { start = 4, count = 1 } } }
			confirm_choice("confirm")
			assert(reset_count == 0, "confirmation must not invoke gitsigns after its hunk state changes")
		end, debug.traceback)
		confirm.open = previous_confirm_open
		package.loaded["gitsigns"] = previous_gitsigns
		backends.resolve_cached = previous_resolve_cached
		if confirm._test_reset_session then
			confirm._test_reset_session()
		end
		if not ok then
			error(err, 0)
		end
	end

	local function test_live_diff_hunk_revert_refuses_stale_buffer_state()
		require("lazyvcs").setup({
			debounce_ms = 0,
			use_gitsigns = false,
			source_control = { confirm_mutations = true },
		})

		local fixture = helpers.make_git_fixture()
		local actions = require("lazyvcs.actions")
		local confirm = require("lazyvcs.source_control.confirm")
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		local session = open_diff()
		vim.api.nvim_set_current_win(session.editable_win)
		vim.api.nvim_win_set_cursor(session.editable_win, { 2, 0 })

		local previous_confirm_open = confirm.open
		local confirm_choice
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			confirm_choice = on_choice
			return {}
		end

		local ok, err = xpcall(function()
			actions.revert_hunk()
			assert(type(confirm_choice) == "function", "live-diff hunk revert should wait for confirmation")
			vim.api.nvim_buf_set_lines(session.editable_bufnr, 1, 2, false, { "edited while confirmation was open" })
			confirm_choice("confirm")
			assert(
				vim.api.nvim_buf_get_lines(session.editable_bufnr, 1, 2, false)[1]
					== "edited while confirmation was open",
				"live-diff confirmation must not revert edits made after the prompt opened"
			)
		end, debug.traceback)
		confirm.open = previous_confirm_open
		if confirm._test_reset_session then
			confirm._test_reset_session()
		end
		actions.close(session.editable_bufnr)
		if not ok then
			error(err, 0)
		end
	end

	local function test_live_diff_hunk_revert_refuses_changed_base_state()
		require("lazyvcs").setup({
			debounce_ms = 0,
			use_gitsigns = false,
			source_control = { confirm_mutations = true },
		})

		local fixture = helpers.make_git_fixture()
		local actions = require("lazyvcs.actions")
		local confirm = require("lazyvcs.source_control.confirm")
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		local session = open_diff()
		vim.api.nvim_set_current_win(session.editable_win)
		vim.api.nvim_win_set_cursor(session.editable_win, { 2, 0 })
		local changed_line = vim.api.nvim_buf_get_lines(session.editable_bufnr, 1, 2, false)[1]

		local previous_confirm_open = confirm.open
		local confirm_choice
		---@diagnostic disable-next-line: duplicate-set-field
		confirm.open = function(_, on_choice)
			confirm_choice = on_choice
			return {}
		end

		local ok, err = xpcall(function()
			actions.revert_hunk()
			assert(type(confirm_choice) == "function", "live-diff hunk revert should wait for confirmation")
			session.base_lines[2] = "base changed while confirmation was open"
			confirm_choice("confirm")
			assert(
				vim.api.nvim_buf_get_lines(session.editable_bufnr, 1, 2, false)[1] == changed_line,
				"live-diff confirmation must not revert against a changed comparison base"
			)
		end, debug.traceback)
		confirm.open = previous_confirm_open
		if confirm._test_reset_session then
			confirm._test_reset_session()
		end
		actions.close(session.editable_bufnr)
		if not ok then
			error(err, 0)
		end
	end

	local function test_confirmation_validates_before_restoring_cursor()
		local confirm = require("lazyvcs.source_control.confirm")
		local original_win = vim.api.nvim_get_current_win()
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one", "two", "three" })
		vim.api.nvim_win_set_cursor(original_win, { 2, 0 })
		local observed_line
		local chosen

		local popup = confirm.open({
			prompt = "Confirm test?",
			before_confirm = function()
				observed_line = vim.api.nvim_win_get_cursor(original_win)[1]
				return false
			end,
		}, function(choice)
			chosen = choice
		end)
		vim.api.nvim_win_set_cursor(original_win, { 3, 0 })
		popup.owner:finish("confirm")

		assert(observed_line == 3, "confirmation must validate the live cursor before restoring it")
		assert(chosen == "cancel", "failed pre-confirm validation must cancel the mutation")
	end

	local function test_confirmation_fails_closed_when_validation_is_unknown()
		local confirm = require("lazyvcs.source_control.confirm")
		local chosen
		local popup = confirm.open({
			prompt = "Confirm test?",
			before_confirm = function()
				return nil
			end,
		}, function(choice)
			chosen = choice
		end)

		popup.owner:finish("confirm")
		assert(chosen == "cancel", "unknown pre-confirm validation must cancel the mutation")
	end

	local function test_json_file_completes_partial_writes_before_replace()
		local json_file = require("lazyvcs.json_file")
		local root = helpers.tempdir()
		local path = root .. "/state.json"
		local previous_write = vim.uv.fs_write
		local write_calls = 0
		---@diagnostic disable-next-line: duplicate-set-field
		vim.uv.fs_write = function(fd, data, offset)
			write_calls = write_calls + 1
			if write_calls == 1 then
				local partial = math.max(1, math.floor(#data / 2))
				return previous_write(fd, data:sub(1, partial), offset)
			end
			return previous_write(fd, data, offset)
		end

		local ok, err = xpcall(function()
			assert(json_file.write(path, { replacement = "complete" }))
			assert(write_calls >= 2, "a partial state write should continue with the remaining bytes")
			assert(
				vim.deep_equal(json_file.read(path), { replacement = "complete" }),
				"atomic replacement must contain the full JSON document"
			)
			assert(vim.fn.glob(path .. ".tmp.*") == "", "a completed partial write should not leave a temporary file")

			local stalled_calls = 0
			---@diagnostic disable-next-line: duplicate-set-field
			vim.uv.fs_write = function(fd, data, offset)
				stalled_calls = stalled_calls + 1
				if stalled_calls == 1 then
					return previous_write(fd, data:sub(1, 1), offset)
				end
				return 0
			end
			local replaced, replace_err = json_file.write(path, { replacement = "truncated" })
			assert(not replaced and replace_err, "a partial write that stops making progress should fail")
			assert(
				vim.deep_equal(json_file.read(path), { replacement = "complete" }),
				"a stalled partial write must leave the previous state intact"
			)
			assert(vim.fn.glob(path .. ".tmp.*") == "", "a stalled partial write should remove its temporary file")
		end, debug.traceback)
		vim.uv.fs_write = previous_write
		if not ok then
			error(err, 0)
		end
	end

	local function test_ai_attachment_completes_partial_writes_before_provider_start()
		require("lazyvcs").setup({
			ai = {
				commit_message = {
					provider = "copilot_cli",
					confirm_privacy = false,
				},
			},
		})

		local ai = require("lazyvcs.source_control.ai")
		local util = require("lazyvcs.util")
		local previous_system_start = util.system_start
		local previous_write = vim.uv.fs_write
		local attachment_path
		local attachment_content
		local write_calls = 0
		ai._test_reset_privacy()
		ai._test_set_executable_checker(function(name)
			return name == "copilot"
		end)
		---@diagnostic disable-next-line: duplicate-set-field
		vim.uv.fs_write = function(fd, data, offset)
			write_calls = write_calls + 1
			if write_calls == 1 then
				local partial = math.max(1, math.floor(#data / 2))
				return previous_write(fd, data:sub(1, partial), offset)
			end
			return previous_write(fd, data, offset)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, _, on_exit)
			local command = table.concat(args, " ")
			if command:match("^git diff %-%-staged") then
				local result = {
					code = 0,
					stdout = "diff --git a/app.lua b/app.lua\n+return 'complete attachment'\n",
					stderr = "",
				}
				on_exit(result, nil, result)
			elseif command:match("^copilot ") then
				for index, arg in ipairs(args) do
					if arg == "--attachment" then
						attachment_path = args[index + 1]
						break
					end
				end
				assert(attachment_path, "Copilot CLI should receive a private attachment")
				attachment_content = table.concat(vim.fn.readfile(attachment_path, "b"), "\n")
				local result = { code = 0, stdout = "Describe complete attachment\n", stderr = "" }
				on_exit(result, nil, result)
			else
				error("unexpected command: " .. command)
			end
			return {}
		end

		local message
		local generate_err
		local ok, err = xpcall(function()
			ai.generate({ vcs = "git", root = helpers.tempdir() }, function(generated, callback_err)
				message = generated
				generate_err = callback_err
			end)
			wait_for(function()
				return message ~= nil or generate_err ~= nil
			end, "Copilot CLI generation should finish", ASYNC_TIMEOUT_MS)
			assert(not generate_err, generate_err)
			assert(write_calls >= 2, "a partial attachment write should continue with the remaining bytes")
			assert(
				attachment_content:match("complete attachment"),
				"the provider must receive the complete private attachment"
			)
			assert(not vim.uv.fs_stat(attachment_path), "the private attachment should be deleted after generation")
		end, debug.traceback)
		vim.uv.fs_write = previous_write
		util.system_start = previous_system_start
		ai._test_reset_privacy()
		if not ok then
			error(err, 0)
		end
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

	local function test_buffer_guard_matches_an_external_alias_to_a_tracked_file()
		local fixture = helpers.make_git_fixture()
		local alias = vim.fn.tempname()
		assert(vim.uv.fs_symlink(fixture.file, alias), "test symlink should be created")

		local ok, err = xpcall(function()
			vim.cmd.edit(vim.fn.fnameescape(alias))
			vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved through external alias" })
			local modified = require("lazyvcs.source_control.buffer_guard").modified(fixture.root, { fixture.file })

			assert(#modified == 1, "a modified regular file opened through an alias must block repository mutation")
		end, debug.traceback)
		pcall(function()
			vim.cmd("bdelete!")
		end)
		pcall(vim.fn.delete, alias)
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

	local function test_source_control_sync_refuses_modified_buffer_before_merge()
		require("lazyvcs").setup({ source_control = { confirm_mutations = false, sync_button_behavior = "direct" } })

		local fixture = helpers.make_git_fixture()
		local ops = require("lazyvcs.source_control.ops")
		local session_state = require("lazyvcs.state")
		local util = require("lazyvcs.util")
		local repo = {
			root = fixture.root,
			name = "repo",
			vcs = "git",
			branch = "main",
			counts = { local_changes = 1, staged = 0, remote = 1 },
			sync = { status = "incoming" },
		}
		local state = {
			path = fixture.root,
			lazyvcs_commit_drafts = {},
			lazyvcs_repo_cache = { [fixture.root] = repo },
		}
		local node = {
			type = "repo_changes",
			path = fixture.root,
			extra = { repo_root = fixture.root },
		}
		local responses = {
			["git branch --show-current"] = "main\n",
			["git for-each-ref --format=%(upstream:short) refs/heads/main"] = "origin/main\n",
			["git fetch --prune --quiet origin"] = "",
			["git status --branch --porcelain=v1 --untracked-files=no --ignored=no"] = "## main...origin/main [behind 1]\n M sample.txt\n",
		}
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved editor text" })

		local previous_system_start = util.system_start
		local calls = {}
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, _, on_exit)
			local key = table.concat(args, " ")
			calls[#calls + 1] = key
			assert(responses[key] ~= nil, "unexpected command: " .. key)
			local result = { code = 0, stdout = responses[key], stderr = "" }
			on_exit(result, nil, result)
			return {}
		end

		local ok, err = xpcall(function()
			ops.sync_repo(state, node)
			assert(not vim.tbl_contains(calls, "git merge --ff-only origin/main"), "sync must guard its merge")
			local job = assert(session_state.get_repo_job(fixture.root), "refused sync should report its failure")
			assert(job.status == "error", "refused sync should finish as an error")
		end, debug.traceback)
		util.system_start = previous_system_start
		session_state.clear_repo_job(fixture.root)
		if not ok then
			error(err, 0)
		end
	end

	local function test_source_control_sync_push_allows_modified_buffer()
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
			counts = { local_changes = 1, staged = 0, remote = 1 },
			sync = { status = "outgoing" },
		}
		local state = {
			path = fixture.root,
			lazyvcs_commit_drafts = {},
			lazyvcs_repo_cache = { [fixture.root] = repo },
		}
		local node = {
			type = "repo_changes",
			path = fixture.root,
			extra = { repo_root = fixture.root },
		}
		local responses = {
			["git branch --show-current"] = "main\n",
			["git for-each-ref --format=%(upstream:short) refs/heads/main"] = "origin/main\n",
			["git fetch --prune --quiet origin"] = "",
			["git status --branch --porcelain=v1 --untracked-files=no --ignored=no"] = "## main...origin/main [ahead 1]\n M sample.txt\n",
			["git push origin main:main"] = "",
		}
		vim.cmd.edit(vim.fn.fnameescape(fixture.file))
		vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved editor text" })

		local previous_system_start = util.system_start
		local calls = {}
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, _, on_exit)
			local key = table.concat(args, " ")
			calls[#calls + 1] = key
			assert(responses[key] ~= nil, "unexpected command: " .. key)
			local result = { code = 0, stdout = responses[key], stderr = "" }
			on_exit(result, nil, result)
			return {}
		end

		local ok, err = xpcall(function()
			ops.sync_repo(state, node)
			assert(vim.tbl_contains(calls, "git push origin main:main"), "push-only sync must remain available")
		end, debug.traceback)
		util.system_start = previous_system_start
		session_state.clear_repo_job(fixture.root)
		if not ok then
			error(err, 0)
		end
	end

	local function test_source_control_create_branch_allows_modified_buffer()
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
				{ kind = "command", action = "git_create_branch", preserves_worktree = true, label = "save-work" },
				{ "git", "switch", "-c", "save-work" },
				{ cwd = target_repo.root }
			)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, _, on_exit)
			assert(table.concat(args, " ") == "git switch -c save-work", "unexpected branch command")
			mutation_started = true
			local result = { code = 0, stdout = "", stderr = "" }
			on_exit(result, nil, result)
			return {}
		end

		local ok, err = xpcall(function()
			ops.switch_repo(state, node)
			assert(mutation_started, "creating a branch at current HEAD must remain available")
		end, debug.traceback)
		repo_switch.open_async = previous_open_async
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
			"test_buffer_discard_session_choice_suppresses_second_prompt",
			test_buffer_discard_session_choice_suppresses_second_prompt,
		},
		{
			"test_buffer_discard_cancel_releases_request_owner",
			test_buffer_discard_cancel_releases_request_owner,
		},
		{
			"test_source_control_confirm_session_survives_sidebar_reopen",
			test_source_control_confirm_session_survives_sidebar_reopen,
		},
		{
			"test_direct_hunk_revert_uses_session_confirmation",
			test_direct_hunk_revert_uses_session_confirmation,
		},
		{
			"test_direct_hunk_revert_requires_explicit_confirmation",
			test_direct_hunk_revert_requires_explicit_confirmation,
		},
		{
			"test_direct_hunk_revert_refuses_stale_buffer_state",
			test_direct_hunk_revert_refuses_stale_buffer_state,
		},
		{
			"test_sign_state_isolated_and_cleared_on_wipe",
			test_sign_state_isolated_and_cleared_on_wipe,
		},
		{
			"test_gitsigns_hunk_revert_refuses_changed_window",
			test_gitsigns_hunk_revert_refuses_changed_window,
		},
		{
			"test_gitsigns_hunk_revert_refuses_changed_hunk_state",
			test_gitsigns_hunk_revert_refuses_changed_hunk_state,
		},
		{
			"test_live_diff_hunk_revert_refuses_stale_buffer_state",
			test_live_diff_hunk_revert_refuses_stale_buffer_state,
		},
		{
			"test_live_diff_hunk_revert_refuses_changed_base_state",
			test_live_diff_hunk_revert_refuses_changed_base_state,
		},
		{
			"test_confirmation_validates_before_restoring_cursor",
			test_confirmation_validates_before_restoring_cursor,
		},
		{
			"test_confirmation_fails_closed_when_validation_is_unknown",
			test_confirmation_fails_closed_when_validation_is_unknown,
		},
		{
			"test_json_file_completes_partial_writes_before_replace",
			test_json_file_completes_partial_writes_before_replace,
		},
		{
			"test_ai_attachment_completes_partial_writes_before_provider_start",
			test_ai_attachment_completes_partial_writes_before_provider_start,
		},
		{
			"test_buffer_guard_preserves_a_tracked_symlink_path",
			test_buffer_guard_preserves_a_tracked_symlink_path,
		},
		{
			"test_buffer_guard_matches_an_external_alias_to_a_tracked_file",
			test_buffer_guard_matches_an_external_alias_to_a_tracked_file,
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
			"test_source_control_sync_refuses_modified_buffer_before_merge",
			test_source_control_sync_refuses_modified_buffer_before_merge,
		},
		{
			"test_source_control_sync_push_allows_modified_buffer",
			test_source_control_sync_push_allows_modified_buffer,
		},
		{
			"test_source_control_create_branch_allows_modified_buffer",
			test_source_control_create_branch_allows_modified_buffer,
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
