local root, cache = arg[1], arg[2]
vim.env.XDG_CACHE_HOME = cache
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
-- An expired legacy file proves this editor's prune can delete messages.
local dir = vim.fn.stdpath("cache") .. "/lazyvcs/commit"
vim.fn.mkdir(dir, "p")
local marker = dir .. "/zzzz-prune-control.txt"
vim.fn.writefile({ "abandoned" }, marker)
local old = os.time() - vim.uv.uptime() - 86410
assert(vim.uv.fs_utime(marker, old, old))
require("commit_file_helpers").scan(function()
	require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
end, function(predicate, message, timeout)
	assert(vim.wait(timeout, predicate, 10), message)
end)
assert(not vim.uv.fs_stat(marker), "prune did not remove the expired control file")
vim.cmd("qa!")
