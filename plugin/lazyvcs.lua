if vim.g.loaded_lazyvcs then
	return
end

vim.g.loaded_lazyvcs = 1

require("lazyvcs.commands").setup()
