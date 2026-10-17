local root, cache = arg[1], arg[2]
vim.env.XDG_CACHE_HOME = cache
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
require("commit_file_helpers").scan(function()
	require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
end, function(predicate, message, timeout)
	assert(vim.wait(timeout, predicate, 10), message)
end)
vim.cmd("qa!")
