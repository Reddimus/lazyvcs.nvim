local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- Poll from the parent so the child processes typed keys between requests.
local function poll(expr, message)
	for _ = 1, 1500 do
		if child.lua_get(expr) then
			return
		end
		vim.uv.sleep(10)
	end
	error(message)
end

local T = MiniTest.new_set({
	hooks = {
		pre_case = function()
			child.restart({ "--cmd", "set lines=30 columns=120" })
			child.cmd("let $LAZYVCS_REPO_ROOT = " .. vim.fn.string(root))
			child.cmd("luafile " .. vim.fn.fnameescape(root .. "/tests/minitest_child_init.lua"))
			child.lua([[
package.path = vim.env.LAZYVCS_REPO_ROOT .. '/tests/?.lua;' .. package.path
fixture = require('helpers').make_git_fixture()
require('lazyvcs').setup({ use_gitsigns = false, blame = { mode = 'off', persist = false } })
vim.o.swapfile = false
vim.cmd.edit(vim.fn.fnameescape(fixture.file))
source = vim.api.nvim_get_current_win()
-- Record the delivered choice so cancelled cases need no timing window.
choices = {}
local confirm = require('lazyvcs.source_control.confirm')
local mutation = confirm.mutation
confirm.mutation = function(opts, on_confirm, on_cancel)
	return mutation(opts, function(...)
		choices[#choices + 1] = 'confirm'
		if on_confirm then return on_confirm(...) end
	end, function(...)
		choices[#choices + 1] = 'cancel'
		if on_cancel then return on_cancel(...) end
	end)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'one', 'changed', 'three' })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local ready = false
require('lazyvcs.signs').refresh(vim.api.nvim_get_current_buf(), true, function() ready = true end)
assert(vim.wait(15000, function() return ready end, 10), 'signs did not load')
]])
		end,
		post_case = function()
			child.lua("require('helpers').cleanup()")
		end,
		post_once = function()
			child.stop()
		end,
	},
})

local function revert(insert, key, confirmed)
	if insert then
		child.type_keys("i")
		poll("vim.api.nvim_get_mode().mode == 'i'", "did not enter Insert mode")
	end
	child.type_keys(insert and "<C-o>" or "", ":LazyVCS hunk revert<CR>")
	poll("vim.bo.buftype == 'nofile'", "confirmation did not open")
	eq(child.lua_get("vim.api.nvim_get_mode().mode"), "n")
	local popup = child.lua_get("vim.api.nvim_get_current_win()")
	child.type_keys(key)
	poll("not vim.api.nvim_win_is_valid(" .. popup .. ")", "first confirmation key did not close popup")
	eq(child.lua_get("vim.api.nvim_get_current_win() == source"), true)
	local choice = confirmed and "confirm" or "cancel"
	poll("choices[1] ~= nil", "confirmation delivered no choice")
	eq(child.lua_get("choices"), { choice })
	local expected = { "one", confirmed and "two" or "changed", "three" }
	if confirmed then
		-- A confirmed revert applies after the base identity is checked again.
		poll(
			"vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), " .. vim.inspect(expected) .. ")",
			"confirmed hunk revert was not applied"
		)
	end
	eq(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"), expected)
	eq(child.lua_get("vim.api.nvim_exec2('messages', { output = true }).output"):find("E21", 1, true), nil)
end

T["Normal-mode confirmation cancels with Escape"] = function()
	revert(false, "<Esc>", false)
end

T["Insert-mode <C-o> confirmation confirms with 1"] = function()
	revert(true, "1", true)
end

T["Insert-mode <C-o> confirmation cancels with Escape"] = function()
	revert(true, "<Esc>", false)
end

return T
