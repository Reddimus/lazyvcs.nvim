local run_file = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo_root = vim.fn.fnamemodify(run_file, ":h:h")

vim.opt.runtimepath:prepend(repo_root)
vim.opt.runtimepath:append("/home/kevim/.local/share/nvim/lazy/plenary.nvim")
vim.opt.runtimepath:append("/home/kevim/.local/share/nvim/lazy/nui.nvim")
vim.opt.runtimepath:append("/home/kevim/.local/share/nvim/lazy/neo-tree.nvim")
vim.opt.runtimepath:append("/home/kevim/.local/share/nvim/lazy/gitsigns.nvim")
package.path = table.concat({
	repo_root .. "/lua/?.lua",
	repo_root .. "/lua/?/init.lua",
	repo_root .. "/tests/?.lua",
	"/home/kevim/.local/share/nvim/lazy/plenary.nvim/lua/?.lua",
	"/home/kevim/.local/share/nvim/lazy/plenary.nvim/lua/?/init.lua",
	"/home/kevim/.local/share/nvim/lazy/nui.nvim/lua/?.lua",
	"/home/kevim/.local/share/nvim/lazy/nui.nvim/lua/?/init.lua",
	"/home/kevim/.local/share/nvim/lazy/neo-tree.nvim/lua/?.lua",
	"/home/kevim/.local/share/nvim/lazy/neo-tree.nvim/lua/?/init.lua",
	package.path,
}, ";")

require("spec")
vim.cmd("qa!")
