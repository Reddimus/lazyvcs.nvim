local root, dir, mode = arg[1], arg[2], arg[3]
vim.opt.runtimepath:prepend(root)
local util = require("lazyvcs.util")
local args, cwd, ready
if mode == "push" then
	args, cwd, ready = { "git", "push", "--set-upstream", "origin", "feature" }, dir .. "/work", dir .. "/work/ready"
else
	args, cwd, ready = { vim.v.progpath, "-ll", dir .. "/writer.lua", dir }, dir, dir .. "/ready"
end
local exited
local handle = util.system_start(args, {
	cwd = cwd,
	scope = "mutation",
	preserve_on_shutdown = true,
	on_exit_during_shutdown = true,
}, function(_, err, raw)
	exited = tostring(err) .. "\n" .. vim.inspect(raw)
end)
assert(
	vim.wait(10000, function()
		return exited ~= nil or vim.fn.filereadable(ready) == 1
	end, 10),
	"preserved command did not become ready"
)
assert(not exited, "preserved command exited before editor exit: " .. tostring(exited))
-- On Windows this is the helper, which exits after the command.
vim.fn.writefile({ tostring(handle.process.pid) }, dir .. "/command.pid")
local started = vim.uv.hrtime()
vim.api.nvim_create_autocmd("VimLeave", {
	once = true,
	callback = function()
		vim.fn.writefile({ tostring(math.floor((vim.uv.hrtime() - started) / 1e6)) }, dir .. "/exit-ms")
	end,
})
vim.cmd("qa!")
