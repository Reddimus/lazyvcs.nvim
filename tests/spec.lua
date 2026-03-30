local helpers = require("helpers")

local function eq(left, right, msg)
	assert(vim.deep_equal(left, right), msg or (vim.inspect(left) .. " ~= " .. vim.inspect(right)))
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

test_diff_reset()
test_diff_reset_for_insertion()
test_diff_reset_for_deletion()
test_diff_reset_for_top_deletion()
test_config_normalization()
test_git_backend()
test_svn_backend()
test_git_integration()
test_svn_integration()

print("lazyvcs tests: ok")
