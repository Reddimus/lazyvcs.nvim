local helpers = require("helpers")

local function eq(left, right, msg)
	assert(vim.deep_equal(left, right), msg or (vim.inspect(left) .. " ~= " .. vim.inspect(right)))
end

local function diff_window_count()
	local count = 0
	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.wo[winid].diff then
			count = count + 1
		end
	end
	return count
end

local function diff_hl_id(winid, line)
	local hl_id = 0
	vim.api.nvim_win_call(winid, function()
		hl_id = vim.fn.diff_hlID(line, 1)
	end)
	return hl_id
end

local function assert_transfer_session_matches(session, expected)
	eq(vim.api.nvim_buf_get_lines(session.base_bufnr, 0, -1, false), expected.base_lines)
	eq(diff_window_count(), 2, "transferred session should leave exactly two diff windows")
	assert(vim.wo[session.editable_win].diff, "editable window should stay in diff mode after transfer")
	assert(vim.wo[session.base_win].diff, "base window should stay in diff mode after transfer")
	assert(diff_hl_id(session.editable_win, expected.changed_line) ~= 0, "changed line should be highlighted")
	assert(diff_hl_id(session.base_win, expected.changed_line) ~= 0, "base changed line should be highlighted")
	eq(
		diff_hl_id(session.editable_win, expected.unchanged_line),
		0,
		"unchanged editable line should not be highlighted"
	)
	eq(diff_hl_id(session.base_win, expected.unchanged_line), 0, "unchanged base line should not be highlighted")
end

local function test_diff_reset()
	local diff = require("lazyvcs.diff")
	local current = { "one", "changed", "three" }
	local base = { "one", "two", "three" }
	local hunks = diff.compute_hunks(base, current)

	eq(#hunks, 1, "expected one hunk")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, current)
	diff.reset_hunk(buf, base, hunks[1])
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), base, "reset_hunk should restore base lines")
end

local function test_diff_reset_for_insertion()
	local diff = require("lazyvcs.diff")
	local current = { "one", "inserted", "two", "three" }
	local base = { "one", "two", "three" }
	local hunks = diff.compute_hunks(base, current)

	eq(#hunks, 1, "expected one insertion hunk")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, current)
	diff.reset_hunk(buf, base, hunks[1])
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), base, "reset_hunk should remove inserted lines")
end

local function test_diff_reset_for_deletion()
	local diff = require("lazyvcs.diff")
	local current = { "one", "three" }
	local base = { "one", "two", "three" }
	local hunks = diff.compute_hunks(base, current)

	eq(#hunks, 1, "expected one deletion hunk")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, current)
	diff.reset_hunk(buf, base, hunks[1])
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), base, "reset_hunk should restore deleted lines")
end

local function test_diff_reset_for_top_deletion()
	local diff = require("lazyvcs.diff")
	local current = { "one", "two" }
	local base = { "zero", "one", "two" }
	local hunks = diff.compute_hunks(base, current)

	eq(#hunks, 1, "expected one top deletion hunk")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, current)
	diff.reset_hunk(buf, base, hunks[1])
	eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), base, "reset_hunk should restore top-of-file deletions")
end

local function test_config_normalization()
	local config = require("lazyvcs.config")
	local opts = config.setup({
		debounce_ms = 12.9,
		base_window = {
			width = 40,
		},
	})

	eq(opts.debounce_ms, 12)
	eq(opts.base_window.width, 40)

	local ok, err = pcall(config.setup, {
		base_window = {
			width = 0,
		},
	})
	assert(ok == false and tostring(err):match("base_window.width"), "invalid width should fail validation")
end

local function test_compute_target_view_centered_hunk()
	local diff = require("lazyvcs.diff")
	local view = diff.compute_target_view({
		current_start = 100,
		current_count = 3,
		base_start = 100,
		base_count = 3,
	}, 22, 200)

	eq(view.lnum, 100)
	eq(view.topline, 91)
end

local function test_compute_target_view_large_hunk()
	local diff = require("lazyvcs.diff")
	local view = diff.compute_target_view({
		current_start = 100,
		current_count = 40,
		base_start = 100,
		base_count = 40,
	}, 22, 200)

	eq(view.lnum, 100)
	eq(view.topline, 100)
end

local function test_compute_target_view_start_and_end_clamping()
	local diff = require("lazyvcs.diff")

	local start_view = diff.compute_target_view({
		current_start = 3,
		current_count = 2,
		base_start = 3,
		base_count = 2,
	}, 22, 200)
	eq(start_view.topline, 1)

	local end_view = diff.compute_target_view({
		current_start = 198,
		current_count = 2,
		base_start = 198,
		base_count = 2,
	}, 22, 200)
	eq(end_view.topline, 179)
end

local function test_compute_target_view_for_deletion_hunk()
	local diff = require("lazyvcs.diff")
	local view = diff.compute_target_view({
		current_start = 50,
		current_count = 0,
		base_start = 51,
		base_count = 1,
	}, 22, 200)

	eq(view.lnum, 50)
	eq(view.topline, 40)
end

local function test_git_backend()
	local backend = require("lazyvcs.backends.git")
	local fixture = helpers.make_git_fixture()
	local info = assert(backend.load(fixture.file))

	eq(info.name, "git")
	eq(info.base_label, "INDEX")
	eq(info.base_lines, { "one", "two", "three" })
end

local function test_svn_backend()
	local backend = require("lazyvcs.backends.svn")
	local fixture = helpers.make_svn_fixture()
	local info = assert(backend.load(fixture.file))

	eq(info.name, "svn")
	eq(info.base_label, "BASE")
	eq(info.base_lines, { "one", "two", "three" })
end

local function test_git_integration()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_fixture()
	vim.cmd.edit(fixture.file)

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")

	local session = assert(actions.open())
	eq(session.backend, "git")
	assert(vim.wo[session.editable_win].diff, "editable window should be in diff mode")
	assert(vim.wo[session.base_win].diff, "base window should be in diff mode")

	vim.api.nvim_set_current_win(session.editable_win)
	vim.api.nvim_win_set_cursor(session.editable_win, { 2, 0 })
	actions.revert_hunk()
	vim.wait(100, function()
		return vim.deep_equal(vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), session.base_lines)
	end)

	eq(vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), session.base_lines)
	actions.close()
	assert(state.get(session.editable_bufnr) == nil, "session should be cleared after close")
end

local function test_git_buffer_transfer_reopens_session()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = assert(actions.open())

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(300, function()
		local live = state.current()
		return live and live.source_path == fixture.file2
	end)

	local second_session = assert(state.current())
	eq(second_session.backend, "git")
	eq(second_session.source_path, fixture.file2)
	assert(second_session.editable_bufnr ~= first_session.editable_bufnr, "should reopen on the new buffer")
	assert_transfer_session_matches(second_session, {
		base_lines = fixture.base2,
		changed_line = 4,
		unchanged_line = 2,
	})

	vim.cmd.buffer(vim.fn.fnameescape(fixture.file1))
	vim.wait(300, function()
		local live = state.current()
		return live and live.source_path == fixture.file1
	end)

	local third_session = assert(state.current())
	eq(third_session.backend, "git")
	eq(third_session.source_path, fixture.file1)
	assert_transfer_session_matches(third_session, {
		base_lines = fixture.base1,
		changed_line = 2,
		unchanged_line = 4,
	})

	actions.close()
end

local function test_svn_integration()
	require("lazyvcs").setup({ debounce_ms = 10, use_gitsigns = false })

	local fixture = helpers.make_svn_fixture()
	vim.cmd.edit(fixture.file)

	local actions = require("lazyvcs.actions")
	local session = assert(actions.open())
	eq(session.backend, "svn")

	vim.api.nvim_set_current_win(session.editable_win)
	vim.api.nvim_win_set_cursor(session.editable_win, { 2, 0 })
	actions.revert_hunk()
	vim.wait(100, function()
		return vim.deep_equal(vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), session.base_lines)
	end)

	eq(vim.api.nvim_buf_get_lines(session.editable_bufnr, 0, -1, false), session.base_lines)
	actions.close()
end

local function test_svn_buffer_transfer_reopens_session()
	require("lazyvcs").setup({ debounce_ms = 10, use_gitsigns = false })

	local fixture = helpers.make_svn_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = assert(actions.open())

	vim.cmd.badd(vim.fn.fnameescape(fixture.file2))
	vim.cmd.buffer(vim.fn.fnameescape(fixture.file2))
	vim.wait(300, function()
		local live = state.current()
		return live and live.source_path == fixture.file2
	end)

	local second_session = assert(state.current())
	eq(second_session.backend, "svn")
	eq(second_session.source_path, fixture.file2)
	assert(second_session.editable_bufnr ~= first_session.editable_bufnr, "should reopen on the new buffer")
	assert_transfer_session_matches(second_session, {
		base_lines = fixture.base2,
		changed_line = 4,
		unchanged_line = 2,
	})

	vim.cmd.buffer(vim.fn.fnameescape(fixture.file1))
	vim.wait(300, function()
		local live = state.current()
		return live and live.source_path == fixture.file1
	end)

	local third_session = assert(state.current())
	eq(third_session.backend, "svn")
	eq(third_session.source_path, fixture.file1)
	assert_transfer_session_matches(third_session, {
		base_lines = fixture.base1,
		changed_line = 2,
		unchanged_line = 4,
	})

	actions.close()
end

local function test_transfer_to_unsupported_buffer_closes_session()
	require("lazyvcs").setup({ debounce_ms = 10 })

	local fixture = helpers.make_git_transfer_fixture()
	vim.cmd.edit(vim.fn.fnameescape(fixture.file1))

	local actions = require("lazyvcs.actions")
	local state = require("lazyvcs.state")
	local first_session = assert(actions.open())

	vim.cmd.enew()
	vim.wait(300, function()
		return state.get(first_session.editable_bufnr) == nil and diff_window_count() == 0
	end)

	eq(state.get(first_session.editable_bufnr), nil, "old session should close on unsupported buffer transfer")
	eq(diff_window_count(), 0, "unsupported buffer transfer should clear tab diff state")
	eq(#vim.api.nvim_tabpage_list_wins(0), 1, "base window should close on unsupported buffer transfer")
end

test_diff_reset()
test_diff_reset_for_insertion()
test_diff_reset_for_deletion()
test_diff_reset_for_top_deletion()
test_config_normalization()
test_compute_target_view_centered_hunk()
test_compute_target_view_large_hunk()
test_compute_target_view_start_and_end_clamping()
test_compute_target_view_for_deletion_hunk()
test_git_backend()
test_svn_backend()
test_git_integration()
test_git_buffer_transfer_reopens_session()
test_svn_integration()
test_svn_buffer_transfer_reopens_session()
test_transfer_to_unsupported_buffer_closes_session()

print("lazyvcs tests: ok")
