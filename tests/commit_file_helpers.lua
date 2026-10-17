local M = {}

-- Model the kernel scope independently of the machine running the suite.
-- Non-Linux platforms must not accidentally borrow the host's /proc evidence.
function M.scope(h, platform, opts)
	opts = opts or {}
	local uname, stat, open = vim.uv.os_uname, vim.uv.fs_stat, vim.uv.fs_open
	local boot = h.tempdir() .. "/boot_id"
	h.write_file(boot, "fixture-boot\n")
	if platform then
		rawset(vim.uv, "os_uname", function()
			return { sysname = platform }
		end)
	end
	local function missing(code, ...)
		local args = { ... }
		local cb = args[#args]
		if type(cb) == "function" then
			vim.schedule(function()
				cb(code .. ": simulated /proc unavailable")
			end)
			return {}
		end
		return nil, code .. ": simulated /proc unavailable", code
	end
	vim.uv.fs_stat = function(path, cb)
		if path:match("^/proc/") then
			if vim.uv.os_uname().sysname ~= "Linux" then
				return missing("ENOENT", cb)
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
				return missing("ENOENT", ...)
			end
			assert(path == "/proc/sys/kernel/random/boot_id", "unexpected /proc open")
			if opts.boot_id_error then
				return missing(opts.boot_id_error, ...)
			end
			path = boot
		end
		return open(path, ...)
	end
	return function()
		vim.uv.os_uname, vim.uv.fs_stat, vim.uv.fs_open = uname, stat, open
	end
end

-- Only a fresh commit-directory scan can satisfy this barrier. Fail clearly if
-- prune coalesces with an existing scan, even before its scandir has opened.
function M.scan(run, wait)
	local scandir, next_entry, stat = vim.uv.fs_scandir, vim.uv.fs_scandir_next, vim.uv.fs_stat
	local dir = vim.fn.stdpath("cache") .. "/lazyvcs/commit"
	local handles, opened, finished, started, running = {}, 0, false, false, false
	rawset(vim.uv, "fs_stat", function(path, ...)
		-- Linux gathers its namespace and boot ID asynchronously before scandir.
		if running and path == "/proc/self/ns/pid" then
			started = true
		end
		return stat(path, ...)
	end)
	rawset(vim.uv, "fs_scandir", function(path, cb)
		if path ~= dir then
			return scandir(path, cb)
		end
		if running then
			started = true
		end
		local function track(entries)
			if entries then
				handles[entries], opened = true, opened + 1
			end
		end
		if cb then
			return scandir(path, function(err, entries)
				track(entries)
				cb(err, entries)
			end)
		end
		local entries, err, code = scandir(path)
		track(entries)
		return entries, err, code
	end)
	rawset(vim.uv, "fs_scandir_next", function(entries)
		local name, kind = next_entry(entries)
		if not name and handles[entries] then
			finished = true
		end
		return name, kind
	end)
	local ok, err = xpcall(function()
		running = true
		run()
		running = false
		assert(started, "pruning did not start a fresh scan (another prune may be running)")
		assert(not finished, "pruning blocked")
		wait(function()
			return finished
		end, "pruning did not finish", 5000)
		assert(opened > 0, "pruning never opened the commit message directory")
	end, debug.traceback)
	vim.uv.fs_scandir, vim.uv.fs_scandir_next, vim.uv.fs_stat = scandir, next_entry, stat
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
		local ok, err = xpcall(function()
			return fn(notices)
		end, function(value)
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
