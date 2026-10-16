local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "--cmd", "set lines=40 columns=220" })
			child.cmd("let $LAZYVCS_REPO_ROOT = " .. vim.fn.string(root))
			child.cmd("luafile " .. vim.fn.fnameescape(root .. "/tests/minitest_child_init.lua"))
			child.lua([[
package.path=vim.env.LAZYVCS_REPO_ROOT..'/tests/?.lua;'..package.path
local h=require('helpers')
fixture=h.make_git_transfer_fixture()
local lines={};for i=1,240 do lines[i]='line '..i end
h.write_file(fixture.file1,table.concat(lines,'\n')..'\n')
h.exec({'git','add','alpha.txt'},fixture.root);h.exec({'git','commit','-m','long diff'},fixture.root)
lines[80]='changed eighty';h.write_file(fixture.file1,table.concat(lines,'\n')..'\n')
vim.g.mapleader=' '
vim.keymap.set('n','<leader>vo','<cmd>LazyVCS diff open<cr>')
require('lazyvcs').setup({signs={enabled=false},blame={persist=false},base_window={width=.45},debounce_ms=10})
vim.cmd.edit(vim.fn.fnameescape(fixture.file1))
vim.o.mouse='a'
]])
			child.api.nvim_ui_attach(220, 40, {})
		end,
		post_case = function()
			child.lua("require('helpers').cleanup()")
		end,
		post_once = function()
			child.stop()
		end,
	},
})
local function open()
	child.type_keys("<Space>vo")
	child.lua([[
assert(vim.wait(15000,function() session=require('lazyvcs.state').current();return session~=nil end,10))
]])
end
local function bound()
	eq(
		child.lua_get([[(function()
local s=session
return vim.wo[s.editable_win].diff and vim.wo[s.base_win].diff and vim.wo[s.editable_win].scrollbind and vim.wo[s.base_win].scrollbind
end)()]]),
		true
	)
	eq(child.lua_get("vim.fn.mode()"), "n")
	eq(child.is_blocked(), false)
end
local function wheel(win)
	local before = child.lua_get("vim.api.nvim_win_call(session." .. win .. ",vim.fn.winsaveview).topline")
	local pos = child.lua_get("vim.api.nvim_win_get_position(session." .. win .. ")")
	child.api.nvim_input_mouse("wheel", "down", "", 0, pos[1] + 8, pos[2] + 8)
	child.lua("vim.wait(100)")
	assert(
		child.lua_get("vim.api.nvim_win_call(session." .. win .. ",vim.fn.winsaveview).topline") > before,
		"wheel did not scroll the targeted pane"
	)
	bound()
	eq(
		child.lua_get([[(function()
local a=vim.api.nvim_win_call(session.editable_win,vim.fn.winsaveview)
local b=vim.api.nvim_win_call(session.base_win,vim.fn.winsaveview)
return math.abs(a.topline-b.topline)<=1
end)()]]),
		true
	)
end
T["keys, mouse, unfocused wheels, and folds preserve the live pair"] = function()
	open()
	child.type_keys("80G", "zz", "zR")
	local before = child.lua_get("vim.api.nvim_win_call(session.editable_win,vim.fn.winsaveview)")
	child.type_keys("<C-w>h")
	bound()
	child.type_keys("<C-w>l")
	bound()
	eq(child.lua_get("vim.api.nvim_win_call(session.editable_win,vim.fn.winsaveview)"), before)
	eq(child.lua_get("vim.api.nvim_win_call(session.editable_win,function() return vim.fn.foldclosed(1) end)"), -1)
	local pos = child.lua_get("vim.api.nvim_win_get_position(session.base_win)")
	child.api.nvim_input_mouse("left", "press", "", 0, pos[1] + 8, pos[2] + 8)
	child.api.nvim_input_mouse("left", "release", "", 0, pos[1] + 8, pos[2] + 8)
	eq(child.lua_get("vim.api.nvim_get_current_win()==session.base_win"), true)
	wheel("base_win")
	wheel("editable_win")
	child.type_keys("<C-w>l")
	wheel("editable_win")
	wheel("base_win")
end
T["picker selection commits in place and natural resize keeps configured width"] = function()
	open()
	local ids = child.lua_get("{session.editable_win,session.base_win,session.base_bufnr}")
	child.lua([[
picker=vim.api.nvim_open_win(vim.api.nvim_create_buf(false,true),true,{relative='editor',row=4,col=10,width=50,height=8,border='single',style='minimal'})
vim.keymap.set('n','<CR>',function()
 vim.api.nvim_win_close(picker,true)
 vim.api.nvim_set_current_win(session.editable_win)
 vim.cmd.edit(vim.fn.fnameescape(fixture.file2))
end,{buffer=true})
]])
	bound()
	child.type_keys("<CR>")
	child.lua([[
assert(vim.wait(15000,function()
 local s=require('lazyvcs.state').current()
 if s and s.source_path==fixture.file2 then session=s;return true end
end,10))
]])
	eq(child.lua_get("{session.editable_win,session.base_win,session.base_bufnr}"), ids)
	child.api.nvim_ui_try_resize(180, 40)
	child.lua([[
assert(vim.wait(2000,function()
 local total=vim.api.nvim_win_get_width(session.editable_win)+vim.api.nvim_win_get_width(session.base_win)
 return math.abs(vim.api.nvim_win_get_width(session.base_win)-math.floor(total*.45))<=1
end,10),'natural resize lost width')
]])
	bound()
end
T["cursor sync false survives keys and selection"] = function()
	child.lua("require('lazyvcs').setup({signs={enabled=false},base_window={cursor_sync=false}})")
	open()
	child.type_keys("<C-w>h", "<C-w>l")
	bound()
	eq(child.lua_get("{vim.wo[session.editable_win].cursorbind,vim.wo[session.base_win].cursorbind}"), { false, false })
	child.lua([[
vim.cmd.edit(vim.fn.fnameescape(fixture.file2))
assert(vim.wait(15000,function() local s=require('lazyvcs.state').current();if s and s.source_path==fixture.file2 then session=s;return true end end,10))
]])
	eq(child.lua_get("{vim.wo[session.editable_win].cursorbind,vim.wo[session.base_win].cursorbind}"), { false, false })
	bound()
end
return T
