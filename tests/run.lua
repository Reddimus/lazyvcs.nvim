local run_file = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo_root = vim.fn.fnamemodify(run_file, ":h:h")
local lazy_root = vim.env.LAZYVCS_TEST_LAZY_ROOT or (vim.fn.stdpath("data") .. "/lazy")

local function add_dependency(name)
	local path = lazy_root .. "/" .. name
	if vim.fn.isdirectory(path) == 0 then
		error("missing test dependency: " .. path .. "\nSet LAZYVCS_TEST_LAZY_ROOT to your lazy.nvim plugin directory.")
	end
	vim.opt.runtimepath:append(path)
	package.path = table.concat({
		path .. "/lua/?.lua",
		path .. "/lua/?/init.lua",
		package.path,
	}, ";")
end

vim.opt.runtimepath:prepend(repo_root)
package.path = table.concat({
	repo_root .. "/lua/?.lua",
	repo_root .. "/lua/?/init.lua",
	repo_root .. "/tests/?.lua",
	package.path,
}, ";")

for _, dependency in ipairs({
	"plenary.nvim",
	"nui.nvim",
	"neo-tree.nvim",
	"gitsigns.nvim",
}) do
	add_dependency(dependency)
end

require("spec")
vim.cmd("qa!")
