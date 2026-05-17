local run_file = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo_root = vim.fn.fnamemodify(run_file, ":h:h")

vim.opt.runtimepath:prepend(repo_root)
package.path = table.concat({
	repo_root .. "/lua/?.lua",
	repo_root .. "/lua/?/init.lua",
	package.path,
}, ";")

vim.cmd.runtime("plugin/lazyvcs.lua")
require("lazyvcs").setup({
	source_control = {
		ui = "native",
		show_clean = true,
		remote_refresh = "manual",
		confirm_mutations = false,
	},
})

assert(vim.fn.exists(":LazyVcsSourceControlToggle") == 2, "native source-control command was not created")
assert(vim.fn.exists(":LazyVcsBlame") == 2, "SVN blame command was not created")
assert(vim.fn.exists(":LazyVcsBlameSplit") == 2, "SVN blame split command was not created")
assert(vim.fn.exists(":LazyVcsBlameClear") == 2, "SVN blame clear command was not created")
assert(vim.fn.exists(":SvnBlame") == 2, "svnsigns compatibility command was not created")

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/team-a/service/.git", "p")
vim.fn.mkdir(root .. "/team-b/service/.git", "p")

require("lazyvcs").source_control_open({ path = root })
local state = assert(require("lazyvcs.source_control.native")._state(), "missing native source-control state")
assert(vim.api.nvim_buf_is_valid(state.bufnr), "native sidebar buffer is invalid")

local text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
assert(text:match("Repositories %(2%)"), text)
assert(text:match("team%-a/service"), text)
assert(text:match("team%-b/service"), text)

local sidebar_bufnr = state.bufnr
local sidebar_winid = state.winid
local opened_file = root .. "/target.txt"
vim.fn.writefile({ "target" }, opened_file)
vim.api.nvim_set_current_win(sidebar_winid)
state.lazyvcs_open_file(state, opened_file)
assert(vim.api.nvim_buf_get_name(0) == opened_file, "native file open should target an editor window")
assert(
	vim.api.nvim_win_get_buf(sidebar_winid) == sidebar_bufnr,
	"native file open should not replace the sidebar buffer"
)

require("lazyvcs").source_control_close()
vim.cmd("qa!")
