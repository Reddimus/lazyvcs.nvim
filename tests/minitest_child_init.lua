local repo_root = assert(vim.env.LAZYVCS_REPO_ROOT, "missing LAZYVCS_REPO_ROOT")

vim.opt.runtimepath:prepend(repo_root)
package.path = table.concat({
	repo_root .. "/lua/?.lua",
	repo_root .. "/lua/?/init.lua",
	package.path,
}, ";")

vim.g.mapleader = " "
vim.cmd.runtime("plugin/lazyvcs.lua")
vim.keymap.set("n", "<leader>vs", "<cmd>LazyVCSSourceControlToggle<cr>", { desc = "Toggle VCS sidebar" })

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
