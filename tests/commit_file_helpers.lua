local M = {}

-- Model the kernel scope independently of the machine running the suite.
-- Non-Linux platforms must not accidentally borrow the host's /proc evidence.
function M.scope(h, platform)
	local uname, stat, open = vim.uv.os_uname, vim.uv.fs_stat, vim.uv.fs_open
	local boot = h.tempdir() .. "/boot_id"
	h.write_file(boot, "fixture-boot\n")
	if platform then
		rawset(vim.uv, "os_uname", function()
			return { sysname = platform }
		end)
	end
	local function missing(...)
		local args = { ... }
		local cb = args[#args]
		if type(cb) == "function" then
			vim.schedule(function()
				cb("ENOENT: simulated platform has no /proc")
			end)
			return {}
		end
		return nil, "ENOENT: simulated platform has no /proc", "ENOENT"
	end
	vim.uv.fs_stat = function(path, cb)
		if path:match("^/proc/") then
			if vim.uv.os_uname().sysname ~= "Linux" then
				return missing(cb)
			end
			assert(path == "/proc/self/ns/pid", "unexpected /proc stat")
			local value = { dev = 12, ino = 34 }
			if cb then
				vim.schedule(function()
					cb(nil, value)
				end)
				return {}
			end
			return value
		end
		return stat(path, cb)
	end
	vim.uv.fs_open = function(path, ...)
		if path:match("^/proc/") then
			if vim.uv.os_uname().sysname ~= "Linux" then
				return missing(...)
			end
			assert(path == "/proc/sys/kernel/random/boot_id", "unexpected /proc open")
			path = boot
		end
		return open(path, ...)
	end
	return function()
		vim.uv.os_uname, vim.uv.fs_stat, vim.uv.fs_open = uname, stat, open
	end
end

-- Wait for the actual end of the scan, independent of entry ordering and speed.
function M.scan(run, wait)
	local next_entry, finished = vim.uv.fs_scandir_next, false
	rawset(vim.uv, "fs_scandir_next", function(entries)
		local name, kind = next_entry(entries)
		if not name then
			finished = true
		end
		return name, kind
	end)
	local ok, err = xpcall(function()
		run()
		assert(not finished, "pruning blocked")
		wait(function()
			return finished
		end, "pruning did not finish", 5000)
	end, debug.traceback)
	vim.uv.fs_scandir_next = next_entry
	assert(ok, err)
end

function M.notified(fn)
	return function()
		local util = require("lazyvcs.util")
		local notify, notices = util.notify, {}
		---@diagnostic disable-next-line: duplicate-set-field
		util.notify = function(message)
			notices[#notices + 1] = message
		end
		local ok, err = xpcall(fn, function(value)
			return type(value) == "table" and value or debug.traceback(tostring(value), 2)
		end)
		util.notify = notify
		if not ok then
			if type(err) == "table" then
				error(err)
			end
			error(err .. "\nNotifications: " .. vim.inspect(notices))
		end
	end
end

return M
