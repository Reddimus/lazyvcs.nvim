local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "--cmd", "set lines=40 columns=160" })
			child.cmd("let $LAZYVCS_REPO_ROOT = " .. vim.fn.string(root))
			child.cmd("luafile " .. vim.fn.fnameescape(root .. "/tests/minitest_child_init.lua"))
			child.lua([[
package.path = vim.env.LAZYVCS_REPO_ROOT .. '/tests/?.lua;' .. package.path
fixture = require('helpers').make_git_fixture()
vim.cmd.edit(vim.fn.fnameescape(fixture.file))
vim.keymap.set('x', '<leader>vb', '<Plug>(LazyVCSBlameSelection)')
]])
		end,
		post_once = function()
			child.stop()
		end,
	},
})
local function ready()
	child.lua([[
assert(vim.wait(15000, function()
 local s = require('lazyvcs.compare').current()
 return s and s.preview_result ~= nil
end, 10), 'preview did not load')
]])
end
T["comparison width, help, and return use real keys"] = function()
	child.cmd("lua require('lazyvcs').compare({path=fixture.root,base='HEAD'})")
	ready()
	child.type_keys("e")
	eq(child.lua_get("require('lazyvcs.compare').current().auto_width"), true)
	child.type_keys("?")
	eq(child.lua_get("vim.api.nvim_get_current_win() == require('lazyvcs.compare').current().helpwin"), true)
	child.type_keys("q", "e")
	eq(child.lua_get("require('lazyvcs.compare').current().auto_width"), false)
	child.type_keys("<Space>vs")
	eq(child.lua_get("vim.bo.filetype"), "lazyvcs-source-control")
	child.lua([[
local s = require('lazyvcs.source_control.native')._state()
assert(vim.wait(15000,function() return not s.lazyvcs_discovering and s.lazyvcs_line_nodes end,10))
for row,node in pairs(s.lazyvcs_line_nodes) do
 if node.extra and node.extra.repo_root == fixture.root then vim.api.nvim_win_set_cursor(s.winid,{row,0});break end
end
]])
	child.type_keys("C")
	ready()
	eq(child.lua_get("#vim.api.nvim_list_tabpages()"), 2)
	child.type_keys("o")
	eq(child.lua_get("vim.api.nvim_buf_get_name(0)"), child.lua_get("fixture.file"))
end
T["visual blame handles reversed line and block selections"] = function()
	for _, keys in ipairs({ { "3G", "V", "k" }, { "2G", "0", "<C-v>", "j", "l" }, { "2G", "0", "v", "j" } }) do
		child.type_keys(unpack(keys))
		child.type_keys("<Space>vb")
		child.lua([[
assert(vim.wait(15000,function()
 return table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),'\n'):find('Selected lines at request time',1,true)
end,10), 'selection blame did not load')
]])
		local text = child.lua_get([[table.concat(vim.api.nvim_buf_get_lines(0,0,-1,false),"\n")]])
		assert(text:find("2  Uncommitted", 1, true), text)
		assert(text:find("3  ", 1, true), text)
		assert(not text:find("\n1  ", 1, true), text)
		child.type_keys("q")
	end
end
return T
