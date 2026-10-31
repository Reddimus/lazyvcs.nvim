return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local reader = require("lazyvcs.backends.patch_svn")
	local seams = { "fs_lstat", "fs_open", "fs_fstat", "fs_read", "fs_close" }
	local function protected(fn)
		return function()
			local saved = {}
			for _, name in ipairs(seams) do
				saved[name] = uv[name]
			end
			local original = reader.read
			local ok, err = xpcall(fn, function(value)
				return type(value) == "table" and value or debug.traceback(value, 2)
			end)
			for name, value in pairs(saved) do
				uv[name] = value
			end
			reader.read = original
			h.cleanup()
			if not ok then
				error(err, 0)
			end
		end
	end
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		assert(fd:close())
	end
	local function wait(fn, message)
		ctx.wait_for(fn, message, 5000)
	end
	local function start(path, limit)
		local result = {}
		local task = require("lazyvcs.backends.task").new(function(bytes, err)
			result.bytes, result.err, result.done = bytes, err, true
		end)
		local function guard(fn)
			return function(...)
				if task:is_active() then
					return fn(...)
				end
			end
		end
		reader.read(task, path, limit or 1024, guard, function(bytes, clipped)
			result.clipped = clipped
			task:finish(bytes)
		end)
		return task, result
	end
	local function link(target, path)
		local ok, err = uv.fs_symlink(target, path)
		if not ok and vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "fixture symlink unavailable: " .. tostring(err) }, 0)
		end
		assert(ok, err)
	end
	local cases = {}
	for _, stage in ipairs({ "before_read", "before_open" }) do
		for _, kind in ipairs({ "symlink", "fifo", "replacement" }) do
			if kind ~= "replacement" or stage == "before_open" then
				cases[#cases + 1] = {
					"test_patch_read_" .. kind .. "_swapped_" .. stage,
					protected(function()
						if kind == "fifo" and vim.fn.has("win32") == 1 then
							error({ lazyvcs_skip = "POSIX FIFO fixture requires mkfifo" }, 0)
						end
						local f = h.make_svn_fixture()
						local path, foreign = f.root .. "/loose.txt", h.tempdir() .. "/foreign.txt"
						local nonce = "foreign real file " .. vim.fn.sha256(foreign .. uv.hrtime()) .. "\n"
						write(path, "owned regular leaf\n")
						write(foreign, nonce)
						local replacement = foreign
						if kind == "symlink" then
							replacement = foreign .. ".link"
							link(foreign, replacement)
						elseif kind == "fifo" then
							replacement = foreign .. ".fifo"
							h.exec({ "mkfifo", replacement }, f.root)
						end
						local read, open = reader.read, uv.fs_open
						local held, swap, opened, closed = nil, false, 0, 0
						local close, owned = uv.fs_close, {}
						uv.fs_close = function(fd, cb)
							if owned[fd] then
								closed = closed + 1
							end
							return close(fd, cb)
						end
						---@diagnostic disable-next-line: duplicate-set-field
						reader.read = function(task, file, limit, guard, done, identity)
							if file == path then
								held = function()
									read(task, file, limit, guard, done, identity)
								end
							else
								return read(task, file, limit, guard, done, identity)
							end
						end
						local result = {}
						local request = require("lazyvcs").patch({
							path = f.root,
							on_done = function(bytes, err)
								result.bytes, result.err, result.done = bytes, err, true
							end,
						})
						wait(function()
							return held
						end, "walker did not classify regular leaf")
						assert(uv.fs_lstat(path).type == "file")
						reader.read = read
						local function replace()
							assert(not swap)
							swap = true
							-- Keep the old inode allocated so a regular replacement cannot reuse it.
							assert(uv.fs_rename(path, path .. ".old"))
							assert(uv.fs_rename(replacement, path))
						end
						uv.fs_open = function(file, flags, mode, cb)
							if file == path and cb then
								if stage == "before_open" then
									replace()
								end
								return open(file, flags, mode, function(err, fd)
									if fd then
										opened = opened + 1
										owned[fd] = true
									end
									cb(err, fd)
								end)
							end
							return open(file, flags, mode, cb)
						end
						if stage == "before_read" then
							replace()
						end
						assert(held)()
						local settled = vim.wait(500, function()
							return result.done
						end, 10)
						if not settled and kind == "fifo" then
							-- Release an old blocking implementation before failing; never strand a worker.
							request:cancel()
							local writer = vim.system(
								{ "sh", "-c", 'printf release > "$1"', "sh", path },
								{ cwd = f.root }
							)
							wait(function()
								return opened > 0
							end, "FIFO fixture release failed")
							assert(writer:wait(5000).code == 0)
							wait(function()
								return closed == opened
							end, "cancelled FIFO descriptor leaked")
						end
						assert(settled, "actual FIFO open blocked without a writer")
						assert(not result.bytes and result.err, "replacement was accepted: " .. tostring(result.bytes))
						assert(not (result.bytes or ""):find(nonce, 1, true), "foreign bytes leaked")
						assert(opened == closed, "rejected descriptor leaked or closed twice")
					end),
				}
			end
		end
	end
	cases[#cases + 1] = {
		"test_patch_read_regular_empty_binary_and_boundaries",
		protected(function()
			local path = h.tempdir() .. "/leaf"
			for _, bytes in ipairs({ "", "ordinary\r\nraw\n", "binary\0payload", string.rep("x", 70000) }) do
				write(path, bytes)
				local _, result = start(path, 100000)
				wait(function()
					return result.done
				end, "ordinary read did not finish")
				assert(result.bytes == bytes and not result.err and not result.clipped)
			end
			write(path, "123456789")
			for _, limit in ipairs({ 0, 1, 9 }) do
				local _, result = start(path, limit)
				wait(function()
					return result.done
				end, "bounded read did not finish")
				assert(result.bytes == ("123456789"):sub(1, limit) and result.clipped)
			end
		end),
	}
	cases[#cases + 1] = {
		"test_patch_read_binary_prefix_stops_without_truncation",
		protected(function()
			local path = h.tempdir() .. "/leaf"
			write(path, "binary\0" .. string.rep("x", 100000))
			local _, result = start(path, 200000)
			wait(function()
				return result.done
			end, "binary prefix did not finish")
			assert(#result.bytes == 65536 and not result.clipped and not result.err)
		end),
	}
	cases[#cases + 1] = {
		"test_patch_read_fallback_identity_rejects_actual_symlink",
		protected(function()
			local dir = h.tempdir()
			local path, foreign, replacement = dir .. "/leaf", dir .. "/foreign", dir .. "/link"
			local nonce = "foreign real file " .. vim.fn.sha256(dir .. uv.hrtime())
			write(path, "owned leaf")
			write(foreign, nonce)
			link(foreign, replacement)
			local open = uv.fs_open
			uv.fs_open = function(file, flags, mode, cb)
				assert(uv.fs_rename(path, path .. ".old"))
				assert(uv.fs_rename(replacement, path))
				if type(flags) == "number" and uv.constants.O_NOFOLLOW then
					flags = bit.band(flags, bit.bnot(uv.constants.O_NOFOLLOW))
				end
				return open(file, flags, mode, cb)
			end
			local _, result = start(path)
			wait(function()
				return result.done
			end, "fallback identity did not settle")
			assert(not result.bytes and result.err, "fallback followed a foreign symlink")
		end),
	}
	cases[#cases + 1] = {
		"test_patch_read_already_cancelled_never_opens",
		protected(function()
			local path = h.tempdir() .. "/leaf"
			write(path, "ordinary")
			local opened = false
			uv.fs_open = function()
				opened = true
				error("open after cancellation")
			end
			local task = require("lazyvcs.backends.task").new(function()
				error("cancelled read completed")
			end)
			task:cancel()
			reader.read(task, path, 100, function(fn)
				return fn
			end, function()
				error("cancelled read published")
			end)
			vim.wait(30)
			assert(not opened)
		end),
	}
	for _, seam in ipairs({ "fs_lstat", "fs_open", "fs_fstat", "fs_read", "fs_close" }) do
		cases[#cases + 1] = {
			"test_patch_read_" .. seam .. "_error_settles_and_closes",
			protected(function()
				local path = h.tempdir() .. "/leaf"
				write(path, "ordinary\n")
				local original, close = uv[seam], uv.fs_close
				local opened, closed, injected = 0, 0, false
				local open = uv.fs_open
				uv.fs_open = function(file, flags, mode, cb)
					return open(file, flags, mode, function(err, fd)
						if fd then
							opened = opened + 1
						end
						cb(err, fd)
					end)
				end
				uv.fs_close = function(fd, cb)
					closed = closed + 1
					return close(fd, cb)
				end
				uv[seam] = function(...)
					local args = { ... }
					local cb = args[#args]
					injected = true
					if seam == "fs_close" then
						closed = closed + 1
						return original(args[1], function()
							cb("EIO injected close")
						end)
					end
					return vim.schedule(function()
						cb("EIO injected " .. seam)
					end)
				end
				local _, result = start(path)
				wait(function()
					return result.done
				end, "read error did not finish")
				assert(injected and not result.bytes and tostring(result.err):find("EIO", 1, true))
				assert(opened == closed, "error descriptor leaked or closed twice")
			end),
		}
	end
	for _, seam in ipairs({ "fs_lstat", "fs_open", "fs_fstat", "fs_read" }) do
		cases[#cases + 1] = {
			"test_patch_read_cancel_held_" .. seam .. "_closes_without_reuse",
			protected(function()
				local path = h.tempdir() .. "/leaf"
				write(path, "ordinary\n")
				local original, close, open, fstat = uv[seam], uv.fs_close, uv.fs_open, uv.fs_fstat
				local held, descriptor, opens, closes = nil, nil, 0, 0
				uv.fs_open = function(file, flags, mode, cb)
					opens = opens + 1
					return open(file, flags, mode, function(err, fd)
						descriptor = fd
						cb(err, fd)
					end)
				end
				local target = uv[seam]
				uv[seam] = function(...)
					local args = { ... }
					local cb = args[#args]
					args[#args] = function(...)
						local values = { ... }
						held = function()
							cb(unpack(values))
						end
					end
					return target(unpack(args))
				end
				uv.fs_close = function(fd, cb)
					closes = closes + 1
					return close(fd, cb)
				end
				local task, result = start(path)
				wait(function()
					return held
				end, "callback was not held")
				task:cancel()
				assert(closes == 0, "descriptor closed before in-flight callback settled")
				assert(held)()
				if seam == "fs_lstat" then
					vim.wait(30)
					assert(opens == 0, "opened after cancellation")
				else
					wait(function()
						return closes == 1
					end, "cancelled descriptor leaked")
					wait(function()
						return fstat(assert(descriptor)) == nil
					end, "descriptor remained open")
				end
				vim.wait(30)
				assert(not result.done and closes <= 1, "late callback published or closed twice")
				uv[seam] = original
			end),
		}
	end
	cases[#cases + 1] = {
		"test_patch_read_missing_identity_fails_closed",
		protected(function()
			local path = h.tempdir() .. "/leaf"
			write(path, "ordinary\n")
			local original = uv.fs_lstat
			uv.fs_lstat = function(file, cb)
				return original(file, function(err, stat)
					if stat then
						stat.ino = nil
					end
					cb(err, stat)
				end)
			end
			local _, result = start(path)
			wait(function()
				return result.done
			end, "identity rejection did not settle")
			assert(not result.bytes and result.err, "unverifiable identity accepted")
		end),
	}
	return cases
end
