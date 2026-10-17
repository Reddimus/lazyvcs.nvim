local root, cache = arg[1], arg[2]
vim.env.XDG_CACHE_HOME = cache
vim.opt.runtimepath:prepend(root)
local dir = vim.fn.stdpath("cache") .. "/lazyvcs/commit"
vim.fn.mkdir(dir, "p")
local marker = dir .. "/zzzz-prune-barrier.txt"
vim.fn.writefile({ "abandoned" }, marker)
local old = os.time() - vim.uv.uptime() - 86400
vim.uv.fs_utime(marker, old, old)
require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
assert(
	vim.wait(5000, function()
		return not vim.uv.fs_stat(marker)
	end, 10),
	"prune did not finish"
)
vim.wait(50)
vim.cmd("qa!")
