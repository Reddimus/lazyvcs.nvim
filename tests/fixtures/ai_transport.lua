vim.fn.writefile({ tostring(vim.uv.os_getpid()) }, assert(arg[1]))
vim.wait(30000, function()
	return vim.uv.fs_stat(arg[1] .. ".finish") ~= nil
end, 10)
io.write("Generated subject\n")
vim.cmd("qa!")
