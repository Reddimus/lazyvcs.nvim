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

assert(vim.fn.exists(":LazyVCS") == 2, "LazyVCS command was not created")

-- The legacy surface (casing twins, svnsigns aliases, per-action commands) is gone.
for _, gone in ipairs({
	":LazyVcsSourceControlToggle",
	":LazyVCSSourceControlToggle",
	":LazyVCSBlame",
	":LazyVcsBlame",
	":SvnBlame",
	":VcsLiveDiffOpen",
}) do
	assert(vim.fn.exists(gone) == 0, "legacy command should be removed: " .. gone)
end

-- macOS puts temporary files under /var, a symlink to /private/var, so Neovim
-- reports buffer names resolved while this path stays unresolved. Resolve once
-- so the buffer-name comparison below matches on every platform.
local root = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(root .. "/team-a/service/.git", "p")
vim.fn.mkdir(root .. "/team-b/service/.git", "p")
root = vim.fs.normalize(vim.uv.fs_realpath(root) or root)

require("lazyvcs").source_control_open({ path = root })
local state = assert(require("lazyvcs.source_control.native")._state(), "missing native source-control state")
assert(vim.api.nvim_buf_is_valid(state.bufnr), "native sidebar buffer is invalid")

-- The sidebar paints immediately and discovers repositories asynchronously, so
-- the first frame legitimately shows "Discovering repositories...". Waiting
-- here is the point: asserting repository rows without it is what previously
-- made the synchronous discovery path look correct.
assert(
	vim.wait(15000, function()
		return state.lazyvcs_discovering ~= true and state.lazyvcs_repo_specs ~= nil
	end, 10),
	"repository discovery should complete"
)

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
-- nvim_buf_get_name returns the OS-native path, so normalize before comparing:
-- on Windows it comes back with backslashes.
assert(
	vim.fs.normalize(vim.api.nvim_buf_get_name(0)) == vim.fs.normalize(opened_file),
	"native file open should target an editor window"
)
assert(
	vim.api.nvim_win_get_buf(sidebar_winid) == sidebar_bufnr,
	"native file open should not replace the sidebar buffer"
)

require("lazyvcs").source_control_close()
vim.cmd("qa!")
