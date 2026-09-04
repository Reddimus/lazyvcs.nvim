local run_file = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local repo_root = vim.fn.fnamemodify(run_file, ":h:h")
local mini_path = vim.env.MINI_TEST_PATH or (repo_root .. "/deps/mini.nvim")

vim.opt.runtimepath:prepend(mini_path)
package.path = table.concat({
	mini_path .. "/lua/?.lua",
	mini_path .. "/lua/?/init.lua",
	repo_root .. "/lua/?.lua",
	repo_root .. "/lua/?/init.lua",
	repo_root .. "/tests/?.lua",
	package.path,
}, ";")

local MiniTest = require("mini.test")

MiniTest.run_file(repo_root .. "/tests/minitest_native_sidebar.lua", {
	execute = {
		reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }),
	},
})
