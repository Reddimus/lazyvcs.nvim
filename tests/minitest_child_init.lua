local repo_root = assert(vim.env.LAZYVCS_REPO_ROOT, "missing LAZYVCS_REPO_ROOT")

vim.opt.runtimepath:prepend(repo_root)
package.path = table.concat({
	repo_root .. "/lua/?.lua",
	repo_root .. "/lua/?/init.lua",
	package.path,
}, ";")

-- Each child, including restarts, owns storage until all exit persistence ends.
local test_storage = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(test_storage, "p")
test_storage = vim.fs.normalize(vim.uv.fs_realpath(test_storage) or test_storage)
vim.env.XDG_STATE_HOME = test_storage .. "/state"
vim.env.XDG_CACHE_HOME = test_storage .. "/cache"
vim.api.nvim_create_autocmd("VimLeave", {
	once = true,
	callback = function()
		pcall(vim.fn.delete, test_storage, "rf")
	end,
})

vim.g.mapleader = " "
vim.cmd.runtime("plugin/lazyvcs.lua")
vim.keymap.set("n", "<leader>vs", "<cmd>LazyVCS sidebar toggle<cr>", { desc = "Toggle VCS sidebar" })
vim.keymap.set("n", "<leader>vc", "<cmd>LazyVCS compare<cr>", { desc = "Compare against base" })
vim.keymap.set("n", "<leader>vC", "<cmd>LazyVCS compare base<cr>", { desc = "Choose comparison base" })

require("lazyvcs").setup({
	source_control = {
		ui = "native",
		show_clean = true,
		remote_refresh = "manual",
		confirm_mutations = false,
		width = 24,
		auto_expand_max_width_ratio = 0.5,
	},
})
