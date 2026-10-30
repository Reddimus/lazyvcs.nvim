local M = {}

-- Attach a real grid before running screen-position assertions.
function M.run_case(group, name, inject)
	local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
	local channel = vim.fn.jobstart(
		{ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" },
		{ rpc = true }
	)
	assert(channel > 0, "UI child did not start")
	local ok, result = pcall(function()
		vim.rpcrequest(channel, "nvim_ui_attach", 220, 80, {})
		return vim.rpcrequest(
			channel,
			"nvim_exec_lua",
			[[
local root, group, name, inject = ...
vim.o.more = false
-- Test failures must return over RPC without opening a hit-enter prompt.
local messages = {}
print = function(...) messages[#messages+1] = table.concat({...}, ' ') end
vim.opt.runtimepath:prepend(root)
package.path = root .. '/tests/?.lua;' .. root .. '/lua/?.lua;' .. package.path
vim.env.LAZYVCS_TEST_GROUP, vim.env.LAZYVCS_TEST_CASE = group, name
if inject then assert(loadstring(inject))() end
require('spec')
return {passed=not _G.LAZYVCS_TEST_FAILED, output=table.concat(messages, '\n')}
]],
			{ root, group, name, inject }
		)
	end)
	-- Quit normally rather than with jobstop(). On Windows jobstop() terminates
	-- every process whose recorded parent ID matches one in the child's tree,
	-- and Windows reuses process IDs, so after a run of VCS commands it can end
	-- processes this test does not own.
	pcall(vim.rpcnotify, channel, "nvim_command", "qall!")
	if vim.fn.jobwait({ channel }, 5000)[1] == -1 then
		vim.fn.jobstop(channel)
		vim.fn.jobwait({ channel }, 5000)
	end
	assert(ok, result)
	assert(type(result) == "table", "UI child returned no test result")
	return result.passed, result.output
end

return M
