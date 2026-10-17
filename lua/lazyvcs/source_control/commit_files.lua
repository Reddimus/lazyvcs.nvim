local M = {}
local sequence = 0
local pruning = false
local fs = require("lazyvcs.fs")

local function directory()
	return vim.fn.stdpath("cache") .. "/lazyvcs/commit"
end

local function report(err)
	require("lazyvcs.util").notify(
		("Commit message cleanup failed: " .. tostring(err)):gsub("[\r\n]+", " "),
		vim.log.levels.WARN
	)
end

local function callback(fn)
	return function(...)
		local args = { n = select("#", ...), ... }
		vim.schedule(function()
			local ok, err = pcall(fn, unpack(args, 1, args.n))
			if not ok then
				pruning = false
				report(err)
			end
		end)
	end
end

local function boot_time()
	return os.time() - vim.uv.uptime()
end

local function read_small(path)
	local fd = vim.uv.fs_open(path, "r", 0)
	if not fd then
		return
	end
	local ok, data = pcall(vim.uv.fs_read, fd, 4096, 0)
	pcall(vim.uv.fs_close, fd)
	return ok and data or nil
end

local function scope()
	local value = { boot = boot_time(), platform = vim.uv.os_uname().sysname }
	if value.platform == "Linux" then
		value.boot_id = read_small("/proc/sys/kernel/random/boot_id")
		local stat = vim.uv.fs_stat("/proc/self/ns/pid")
		value.namespace = stat and { dev = stat.dev, ino = stat.ino } or nil
	end
	return value
end

local function write_record(path, value)
	local encoded = vim.json.encode(value)
	local temp = path .. ".tmp"
	local fd, err = vim.uv.fs_open(temp, "wx", 384)
	if not fd then
		return nil, err
	end
	local ok, written = pcall(fs.write_all, fd, encoded)
	local closed = vim.uv.fs_close(fd)
	if not ok or not written or not closed then
		pcall(vim.uv.fs_unlink, temp)
		return nil, "Could not write ownership record"
	end
	local renamed, rename_err = vim.uv.fs_rename(temp, path)
	if not renamed then
		pcall(vim.uv.fs_unlink, temp)
	end
	return renamed, rename_err
end

function M.create(message)
	local dir = directory()
	local ok = pcall(vim.fn.mkdir, dir, "p", 448)
	local persistent = false
	if ok then
		local protected, private = pcall(vim.uv.fs_chmod, dir, 448)
		local stat = protected and private and vim.uv.fs_stat(dir)
		persistent = stat and stat.type == "directory" and (vim.fn.has("win32") == 1 or bit.band(stat.mode, 511) == 448)
			or false
	end
	sequence = sequence + 1
	local token = string.format("%d-%.0f-%d", vim.fn.getpid(), vim.uv.hrtime(), sequence)
	local path = persistent and (dir .. "/" .. token .. ".txt") or vim.fn.tempname()
	local fd, open_err = vim.uv.fs_open(path, "wx", 384)
	if not fd then
		return nil, "Could not create private commit message: " .. tostring(open_err)
	end
	local written_ok, written, write_err = pcall(fs.write_all, fd, message, 0)
	local closed, close_err = vim.uv.fs_close(fd)
	if not written_ok or not written or not closed then
		pcall(vim.uv.fs_unlink, path)
		return nil, "Could not write commit message: " .. tostring(written_ok and (write_err or close_err) or written)
	end
	local file = { path = path, persistent = persistent, token = token }
	if persistent then
		local record = scope()
		record.version, record.token, record.pending = 1, token, true
		file.record = record
		local saved, err = write_record(path .. ".owner", record)
		if not saved then
			pcall(vim.uv.fs_unlink, path)
			return nil, "Could not record commit message ownership: " .. tostring(err)
		end
	end
	return file
end

-- Ownership follows the consuming PID, including a command preserved at editor exit.
function M.attach(file, handle)
	if file.released or not file.record then
		return
	end
	local pid = handle and handle.process and handle.process.pid
	if not pid or pid <= 0 then
		return
	end
	file.record.pid, file.record.pending = pid, false
	local ok, err = write_record(file.path .. ".owner", file.record)
	if not ok then
		report(err)
	end
end

function M.release(file)
	if file.released then
		return
	end
	file.released = true
	local removed, _, code = vim.uv.fs_unlink(file.path)
	if removed or code == "ENOENT" then
		pcall(vim.uv.fs_unlink, file.path .. ".owner")
		pcall(vim.uv.fs_unlink, file.path .. ".settled")
	elseif file.persistent then
		local saved, err = write_record(file.path .. ".settled", { token = file.token })
		if not saved then
			report(err)
		end
	end
end

-- Pruning reads one bounded record at a time and yields between directory entries.
local function read_async(path, done)
	vim.uv.fs_open(
		path,
		"r",
		0,
		callback(function(err, fd)
			if not fd then
				return done(nil, err)
			end
			local function finish(data, failure)
				vim.uv.fs_close(
					fd,
					callback(function()
						done(data, failure)
					end)
				)
			end
			vim.uv.fs_fstat(
				fd,
				callback(function(stat_err, stat)
					if not stat or stat.type ~= "file" or stat.size > 4096 then
						return finish(nil, stat_err or "Invalid ownership record")
					end
					local chunks, total = {}, 0
					local function read()
						vim.uv.fs_read(
							fd,
							4097 - total,
							total,
							callback(function(read_err, data)
								if not data then
									return finish(nil, read_err)
								end
								if #data == 0 then
									return finish(table.concat(chunks))
								end
								if total + #data > 4096 then
									return finish(nil, "Oversized ownership record")
								end
								chunks[#chunks + 1], total = data, total + #data
								read()
							end)
						)
					end
					read()
				end)
			)
		end)
	)
end

local function decode(data)
	local ok, value = pcall(vim.json.decode, data or "")
	return ok and type(value) == "table" and value or nil
end

local function gone(record, current)
	if
		record.version ~= 1
		or type(record.token) ~= "string"
		or type(record.boot) ~= "number"
		or type(record.platform) ~= "string"
	then
		return false
	end
	if record.boot_id ~= nil and type(record.boot_id) ~= "string" then
		return false
	end
	if record.platform ~= current.platform then
		return false
	end
	local changed = math.abs(record.boot - current.boot) > 5
	if record.boot_id and current.boot_id then
		changed = record.boot_id ~= current.boot_id
	end
	if changed then
		return true
	end
	if current.platform == "Linux" then
		if
			type(record.namespace) ~= "table"
			or not current.namespace
			or record.namespace.dev ~= current.namespace.dev
			or record.namespace.ino ~= current.namespace.ino
		then
			return false
		end
	end
	if type(record.pid) ~= "number" or record.pid <= 0 or record.pid % 1 ~= 0 then
		return false
	end
	local alive, _, code = vim.uv.kill(record.pid, 0)
	return not alive and code == "ESRCH"
end

function M.prune()
	if pruning then
		return
	end
	pruning = true
	local dir = directory()
	local current = { boot = boot_time(), platform = vim.uv.os_uname().sysname }
	local function scan()
		vim.uv.fs_scandir(
			dir,
			callback(function(err, entries)
				if err or not entries then
					pruning = false
					return
				end
				local next_entry
				local function remove(path)
					vim.uv.fs_unlink(
						path,
						callback(function(unlink_err)
							if unlink_err then
								return next_entry()
							end
							vim.uv.fs_unlink(
								path .. ".owner",
								callback(function()
									vim.uv.fs_unlink(path .. ".settled", callback(next_entry))
								end)
							)
						end)
					)
				end
				next_entry = function()
					local name = vim.uv.fs_scandir_next(entries)
					if not name then
						pruning = false
						return
					end
					if not name:match("%.txt$") then
						return callback(next_entry)()
					end
					local path = dir .. "/" .. name
					vim.uv.fs_lstat(
						path,
						callback(function(stat_err, stat)
							if stat_err or not stat or stat.type ~= "file" then
								return next_entry()
							end
							read_async(path .. ".owner", function(data, owner_err)
								local record = decode(data)
								if not record then
									if
										owner_err
										and owner_err:match("^ENOENT[: ]")
										and stat.mtime.sec < current.boot - 5
									then
										return remove(path)
									end
									return next_entry()
								end
								if record.token ~= name:sub(1, -5) then
									return next_entry()
								end
								read_async(path .. ".settled", function(receipt)
									local settled = decode(receipt)
									if
										(type(record.token) == "string" and settled and settled.token == record.token)
										or gone(record, current)
									then
										return remove(path)
									end
									next_entry()
								end)
							end)
						end)
					)
				end
				next_entry()
			end)
		)
	end
	if current.platform ~= "Linux" then
		return scan()
	end
	vim.uv.fs_stat(
		"/proc/self/ns/pid",
		callback(function(_, stat)
			current.namespace = stat and { dev = stat.dev, ino = stat.ino } or nil
			read_async("/proc/sys/kernel/random/boot_id", function(data)
				current.boot_id = data
				scan()
			end)
		end)
	)
end

return M
