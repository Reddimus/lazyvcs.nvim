local dir, role = arg[1], arg[2]
if vim.fn.has("win32") == 1 then
	local ffi = require("ffi")
	ffi.cdef([[
		void * __stdcall GetConsoleWindow(void);
		int __stdcall IsWindowVisible(void *window);
	]])
	local window = ffi.load("kernel32").GetConsoleWindow()
	local visible = window ~= nil and ffi.load("user32").IsWindowVisible(window) ~= 0
	vim.fn.writefile({ visible and "1" or "0" }, dir .. "/" .. role .. ".console")
	if role == "parent" then
		assert(not visible, "background command opened a console window")
	end
end
vim.fn.writefile({ tostring(vim.fn.getpid()) }, dir .. "/" .. role .. ".pid")
local child
if role == "parent" then
	if vim.fn.has("win32") == 1 then
		-- Exercise a native shell grandchild, rather than libuv's hide flags.
		local function quote(value)
			return '"' .. value .. '"'
		end
		local command = quote(vim.v.progpath)
			.. " --headless -u NONE -i NONE -l "
			.. quote(arg[0])
			.. " "
			.. quote(dir)
			.. " leaf"
		-- Capture native descendant startup errors independently of libuv pipes.
		local stdout, stderr = dir .. "/native-shell.out", dir .. "/native-shell.err"
		local code, why, status =
			os.execute('"' .. command .. " <NUL >" .. quote(stdout) .. " 2>" .. quote(stderr) .. '"')
		local function read(path)
			return vim.fn.filereadable(path) == 1 and table.concat(vim.fn.readfile(path), "\n") or ""
		end
		assert(code == 0 or code == true, "native shell leaf failed: " .. vim.inspect({
			code = code,
			why = why,
			status = status,
			command = command,
			stdout = read(stdout),
			stderr = read(stderr),
		}))
	else
		child = vim.system(
			{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", arg[0], dir, "leaf" },
			{ text = true }
		)
	end
end
assert(
	vim.wait(30000, function()
		return vim.fn.filereadable(dir .. "/release") == 1
	end, 20),
	"release timeout"
)
if child then
	assert(child:wait(5000).code == 0, "leaf failed")
end
vim.fn.writefile({ "complete" }, dir .. "/" .. role .. ".done")
vim.cmd("qa!")
