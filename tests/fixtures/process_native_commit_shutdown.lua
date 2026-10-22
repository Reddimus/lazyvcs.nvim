local root, dir = arg[1], arg[2]
vim.env.XDG_CACHE_HOME = dir .. "/cache"
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
local p, util = require("process_helpers"), require("lazyvcs.util")
require("lazyvcs.config").setup({ source_control = { confirm_mutations = false } })
local state = {
	lazyvcs_repo_cache = {
		[dir] = { root = dir, vcs = "git", name = "fixture", counts = { staged = 1, local_changes = 1 } },
	},
	lazyvcs_commit_drafts = { [dir] = table.concat(vim.fn.readfile(dir .. "/message", "b"), "\n") },
}
local start = util.system_start
---@diagnostic disable-next-line: duplicate-set-field
util.system_start = function(args, opts, done)
	if vim.tbl_contains(args, "commit") then
		assert(opts.preserve_on_shutdown)
		vim.fn.writefile({ args[vim.fn.index(args, "-F") + 2] }, dir .. "/message-path")
	end
	return start(args, opts, done)
end
require("lazyvcs.source_control.ops").commit_repo(state, { path = dir })
assert(
	vim.wait(15000, function()
		return p.pid(dir .. "/leaf.pid") ~= nil
	end, 10),
	"commit hook did not start"
)
vim.cmd("qa!")
