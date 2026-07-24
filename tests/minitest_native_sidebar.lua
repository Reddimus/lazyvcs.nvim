local MiniTest = require("mini.test")

local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()
local repo_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

local function child_setup()
	child.restart({ "--cmd", "set lines=40 columns=120" })
	child.cmd("let $LAZYVCS_REPO_ROOT = " .. vim.fn.string(repo_root))
	child.cmd("luafile " .. vim.fn.fnameescape(repo_root .. "/tests/minitest_child_init.lua"))
	child.cmd("set lines=40 columns=120")
end

local function make_workspace()
	return child.lua_get([[(function()
local function exec(args, cwd)
  local result = vim.system(args, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. "\n" .. (result.stderr or ""))
end

local root = vim.fn.tempname()
local repos = {
  root .. "/team-a/integrated-solutions-rdk-webserver",
  root .. "/team-b/libadn",
}
for _, repo in ipairs(repos) do
  vim.fn.mkdir(repo, "p")
  exec({ "git", "init" }, repo)
  vim.fn.writefile({ "changed" }, repo .. "/changed.txt")
end
return root
end)()]])
end

local function sidebar_state()
	return child.lua_get([[(function()
local state = require("lazyvcs.source_control.native")._state()
if not state then
  return nil
end
return {
  winid = state.winid,
  bufnr = state.bufnr,
  width = vim.api.nvim_win_is_valid(state.winid) and vim.api.nvim_win_get_width(state.winid) or nil,
  current_win = vim.api.nvim_get_current_win(),
  cursor = vim.api.nvim_win_is_valid(state.winid) and vim.api.nvim_win_get_cursor(state.winid) or nil,
  text = vim.api.nvim_buf_is_valid(state.bufnr) and table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n") or "",
}
end)()]])
end

T["native sidebar"] = MiniTest.new_set({
	hooks = {
		pre_case = child_setup,
		post_once = function()
			child.stop()
		end,
	},
})

T["native sidebar"]["opens with command"] = function()
	local workspace = make_workspace()
	child.cmd("LazyVCS sidebar open " .. vim.fn.fnameescape(workspace))

	local state = sidebar_state()
	eq(type(state.winid), "number")
	eq(state.width, 24)
	assert(state.text:match("Repositories %(2%)"), state.text)
	assert(state.text:match("integrated"), state.text)
end

T["native sidebar"]["opens from leader mapping"] = function()
	local workspace = make_workspace()
	child.cmd("nnoremap <leader>vs <cmd>LazyVCS sidebar toggle " .. vim.fn.fnameescape(workspace) .. "<cr>")
	child.type_keys("<Space>vs")

	local state = sidebar_state()
	eq(type(state.winid), "number")
	assert(state.text:match("Repositories %(2%)"), state.text)
end

T["native sidebar"]["e toggles auto width and preserves cursor"] = function()
	local workspace = make_workspace()
	child.cmd("LazyVCS sidebar open " .. vim.fn.fnameescape(workspace))
	child.lua([[
local state = require("lazyvcs.source_control.native")._state()
vim.api.nvim_win_set_width(state.winid, 24)
vim.api.nvim_set_current_win(state.winid)
vim.api.nvim_win_set_cursor(state.winid, { 1, 0 })
]])

	child.type_keys("e")
	local expanded = sidebar_state()
	eq(expanded.cursor, { 1, 0 })
	assert(expanded.width > 24, "expected auto-fit to expand the sidebar")
	assert(expanded.width <= 60, "expected auto-fit to respect the 50% width cap")

	child.type_keys("e")
	local restored = sidebar_state()
	eq(restored.width, 24)
	eq(restored.cursor, { 1, 0 })
end

T["native sidebar"]["space toggles section rows without repo lookup errors"] = function()
	local workspace = make_workspace()
	child.cmd("LazyVCS sidebar open " .. vim.fn.fnameescape(workspace))
	child.lua([[
local state = require("lazyvcs.source_control.native")._state()
vim.api.nvim_set_current_win(state.winid)
vim.api.nvim_win_set_cursor(state.winid, { 2, 0 })
]])

	child.type_keys(" ")
	local after = child.lua_get([[(function()
local state = require("lazyvcs.source_control.native")._state()
local node = state.lazyvcs_line_nodes[2]
return {
  expanded = state.lazyvcs_expanded[node.id],
  node_type = node.type,
  text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n"),
}
end)()]])
	assert(after.text:match("Repositories %(2%)"), after.text)
	eq(after.node_type, "view_section")
	eq(after.expanded, false)
end

T["native sidebar"]["render preserves editor focus and metadata spacing"] = function()
	local workspace = make_workspace()
	child.cmd("LazyVCS sidebar open " .. vim.fn.fnameescape(workspace))
	local result = child.lua_get([[(function()
local native = require("lazyvcs.source_control.native")
local state = native._state()
local editor_win = vim.api.nvim_get_current_win()
vim.cmd("wincmd l")
editor_win = vim.api.nvim_get_current_win()
local spec = state.lazyvcs_repo_specs[1]
state.lazyvcs_repo_cache[spec.root] = {
  root = spec.root,
  name = spec.name,
  vcs = "git",
  order = 1,
  relpath = spec.relpath,
  path_label = spec.path_label,
  branch = "feature/spacing-check",
  sections = {},
  counts = { local_changes = 2, staged = 0, remote = 0 },
  sync = { text = "Publish Branch", status = "publish", highlight = "DiagnosticInfo" },
  summary_loaded = true,
  details_loaded = true,
  loading_details = false,
  loading_summary = false,
}
vim.api.nvim_win_set_width(state.winid, 80)
native.render(state)
local text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
local line = text:match("[^\n]*spacing%-check[^\n]*")
return {
  focus_preserved = vim.api.nvim_get_current_win() == editor_win,
  line = line,
  text = text,
  repo_name = spec.name,
}
end)()]])

	eq(result.focus_preserved, true)
	assert(result.line, result.text)
	local name_start = assert(result.line:find(result.repo_name, 1, true), result.line)
	local after_name = result.line:sub(name_start + #result.repo_name, name_start + #result.repo_name)
	eq(after_name, " ")
	assert(result.line:find("spacing-check", 1, true), result.line)
end

T["native sidebar"]["confirmation popup supports numeric keys and restores focus"] = function()
	local workspace = make_workspace()
	child.cmd("LazyVCS sidebar open " .. vim.fn.fnameescape(workspace))
	local before = child.lua_get([[(function()
local state = require("lazyvcs.source_control.native")._state()
vim.api.nvim_set_current_win(state.winid)
vim.api.nvim_win_set_cursor(state.winid, { 2, 0 })
local result
local handle = require("lazyvcs.source_control.confirm").open({
  prompt = "Sync example?",
}, function(choice)
  result = choice
  vim.g.lazyvcs_confirm_test_result = choice
end)
return {
  sidebar_win = state.winid,
  popup_win = handle.winid,
  popup_lines = vim.api.nvim_buf_get_lines(handle.bufnr, 0, -1, false),
}
end)()]])
	eq(before.popup_lines, {
		"1. Confirm",
		"2. Confirm and do not ask again this session",
		"3. Cancel",
	})

	child.type_keys("2")
	local after = child.lua_get([[(function()
local state = require("lazyvcs.source_control.native")._state()
return {
  result = vim.g.lazyvcs_confirm_test_result,
  current_win = vim.api.nvim_get_current_win(),
  sidebar_win = state.winid,
  cursor = vim.api.nvim_win_get_cursor(state.winid),
}
end)()]])
	eq(after.result, "confirm_session")
	eq(after.current_win, after.sidebar_win)
	eq(after.cursor, { 2, 0 })
end

T["native sidebar"]["confirmation popup supports navigation and escape"] = function()
	local workspace = make_workspace()
	child.cmd("LazyVCS sidebar open " .. vim.fn.fnameescape(workspace))
	child.lua([[
local state = require("lazyvcs.source_control.native")._state()
vim.api.nvim_set_current_win(state.winid)
require("lazyvcs.source_control.confirm").open({
  prompt = "Sync example?",
}, function(choice)
  vim.g.lazyvcs_confirm_test_result = choice
end)
]])

	child.type_keys("j<CR>")
	eq(child.lua_get("vim.g.lazyvcs_confirm_test_result"), "confirm_session")

	child.lua([[
local state = require("lazyvcs.source_control.native")._state()
vim.api.nvim_set_current_win(state.winid)
require("lazyvcs.source_control.confirm").open({
  prompt = "Sync example?",
}, function(choice)
  vim.g.lazyvcs_confirm_test_result = choice
end)
]])
	child.type_keys("<CR>")
	eq(child.lua_get("vim.g.lazyvcs_confirm_test_result"), "confirm")

	child.lua([[
local state = require("lazyvcs.source_control.native")._state()
vim.api.nvim_set_current_win(state.winid)
require("lazyvcs.source_control.confirm").open({
  prompt = "Sync example?",
}, function(choice)
  vim.g.lazyvcs_confirm_test_result = choice
end)
]])
	child.type_keys("q")
	eq(child.lua_get("vim.g.lazyvcs_confirm_test_result"), "cancel")

	child.lua([[
local state = require("lazyvcs.source_control.native")._state()
vim.api.nvim_set_current_win(state.winid)
require("lazyvcs.source_control.confirm").open({
  prompt = "Sync example?",
}, function(choice)
  vim.g.lazyvcs_confirm_test_result = choice
end)
]])
	child.type_keys("<Esc>")
	eq(child.lua_get("vim.g.lazyvcs_confirm_test_result"), "cancel")
end

return T
