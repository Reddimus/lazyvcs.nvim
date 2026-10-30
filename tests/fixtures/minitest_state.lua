local root, scratch = arg[1], arg[2]
vim.env.XDG_STATE_HOME = scratch .. "/inherited-state"
vim.env.XDG_CACHE_HOME = scratch .. "/inherited-cache"
vim.env.LAZYVCS_REPO_ROOT = root
package.path = root .. "/tests/?.lua;" .. root .. "/lua/?.lua;" .. package.path
local h = require("helpers")
local f = h.make_git_fixture()
local inherited_state = vim.fs.normalize(vim.fn.stdpath("state"))
local inherited_cache = vim.fs.normalize(vim.fn.stdpath("cache"))
local legacy = inherited_state .. "/lazyvcs/source_control.json"
vim.fn.mkdir(vim.fs.dirname(legacy), "p")
h.write_file(legacy, vim.json.encode({ [f.root] = { show_clean = false } }))
local inherited_preferences = vim.fn.glob(scratch .. "/inherited-state/**/source_control/*.json")

dofile(root .. "/tests/minitest_child_init.lua")
local state_path = vim.fs.normalize(vim.fn.stdpath("state"))
local cache_path = vim.fs.normalize(vim.fn.stdpath("cache"))
vim.fn.mkdir(cache_path, "p")
h.write_file(cache_path .. "/marker", "owned cache\n")
local plugin = require("lazyvcs")
local native = require("lazyvcs.source_control.native")
local function open()
	plugin.source_control_open({ path = f.root })
	local state = assert(native._state())
	assert(
		vim.wait(15000, function()
			return state.lazyvcs_discovering ~= true and state.lazyvcs_repo_specs ~= nil
		end, 10),
		"MiniTest sidebar did not discover fixture"
	)
	return state
end
local state = open()
local show_clean = state.lazyvcs_show_clean
plugin.source_control_close()
local preferences = #vim.fn.glob(state_path .. "/lazyvcs/source_control/*.json", false, true)
-- Leave a sidebar active so its VimLeavePre persistence runs before storage cleanup.
open()
h.cleanup()
h.write_file(
	scratch .. "/report.json",
	vim.json.encode({
		state = state_path,
		cache = cache_path,
		inherited_state = inherited_state,
		inherited_cache = inherited_cache,
		inherited_preferences = inherited_preferences,
		preferences = preferences,
		show_clean = show_clean,
	})
)
vim.cmd("qa!")
