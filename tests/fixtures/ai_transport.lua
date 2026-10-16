if arg[2] == "ignore-term" and vim.fn.has("win32") == 0 then
	-- Override Neovim's own TERM handler before publishing readiness.
	local ffi = require("ffi")
	ffi.cdef("typedef void (*lazyvcs_signal_handler)(int); lazyvcs_signal_handler signal(int, lazyvcs_signal_handler);")
	ffi.C.signal(15, ffi.cast("lazyvcs_signal_handler", 1)) -- POSIX SIG_IGN
end
vim.fn.writefile({ tostring(vim.uv.os_getpid()) }, assert(arg[1]))
vim.wait(30000, function()
	return vim.uv.fs_stat(arg[1] .. ".finish") ~= nil
end, 10)
io.write("Generated subject\n")
vim.cmd("qa!")
