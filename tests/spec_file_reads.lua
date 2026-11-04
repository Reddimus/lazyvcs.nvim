return function(ctx)
	local uv, fs, Task = vim.uv, require("lazyvcs.fs"), require("lazyvcs.backends.task")
	local function write(path, bytes)
		local file = assert(io.open(path, "wb"))
		assert(file:write(bytes))
		file:close()
	end
	local function wait(fn)
		ctx.wait_for(fn, "file read did not settle", 15000)
	end
	local function load(path, limit)
		local result = {}
		local task = Task.new(function(bytes, err)
			result.bytes, result.err, result.done = bytes, err, true
		end)
		fs.read_file_async(task, path, limit, function(...)
			task:finish(...)
		end)
		return result, task
	end
	local cases = {}
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_core_file_read_" .. name,
			function()
				local read, stat, close = uv.fs_read, uv.fs_fstat, uv.fs_close
				local ok, err = xpcall(fn, debug.traceback)
				uv.fs_read, uv.fs_fstat, uv.fs_close = read, stat, close
				assert(ok, err)
			end,
		}
	end
	case("preserves_bytes_across_short_async_reads", function()
		local path = ctx.helpers.tempdir() .. "/bytes"
		local bytes = string.rep("a\0b\n", 100)
		local read, calls = uv.fs_read, 0
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_read = function(fd, size, offset, done)
			assert(done, "read blocked the editor")
			calls = calls + 1
			return read(fd, math.min(size, 3), offset, done)
		end
		for _, content in ipairs({ "", bytes }) do
			write(path, content)
			local out = load(path, #content)
			wait(function()
				return out.done
			end)
			assert(out.bytes == content and not out.err, out.err)
		end
		assert(calls > 100)
	end)
	case("rejects_oversized_files_before_reading", function()
		local path = ctx.helpers.tempdir() .. "/large"
		write(path, string.rep("x", 65))
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_read = function()
			error("oversized file was read")
		end
		local out = load(path, 64)
		wait(function()
			return out.done
		end)
		assert(not out.bytes and out.err:find("limit", 1, true))
	end)
	case("detects_growth_with_a_bounded_read", function()
		local path = ctx.helpers.tempdir() .. "/growing"
		write(path, string.rep("x", 32))
		local stat, read = uv.fs_fstat, uv.fs_read
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_fstat = function(fd, done)
			return stat(fd, function(err, value)
				write(path, string.rep("x", 64))
				done(err, value)
			end)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_read = function(fd, size, offset, done)
			assert(size <= 33)
			return read(fd, size, offset, done)
		end
		local out = load(path, 32)
		wait(function()
			return out.done
		end)
		assert(not out.bytes and out.err:find("limit", 1, true))
	end)
	case("cancelled_read_closes_without_delivering", function()
		local path = ctx.helpers.tempdir() .. "/cancelled"
		write(path, "pending")
		local read, close, held, closed = uv.fs_read, uv.fs_close, nil, false
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_read = function(fd, size, offset, done)
			return read(fd, size, offset, function(err, bytes)
				held = function()
					done(err, bytes)
				end
			end)
		end
		uv.fs_close = function(fd, done)
			assert(done, "close blocked the editor")
			return close(fd, function(err)
				closed = true
				done(err)
			end)
		end
		local out, task = load(path, 64)
		wait(function()
			return held
		end)
		task:kill()
		assert(held)()
		wait(function()
			return closed
		end)
		assert(not out.done)
	end)
	case("rejects_fifos_without_waiting_for_a_writer", function()
		if vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "POSIX FIFO" }, 0)
		end
		local path = ctx.helpers.tempdir() .. "/pipe"
		ctx.helpers.exec({ "mkfifo", path })
		local out = load(path, 64)
		local settled = vim.wait(5000, function()
			return out.done
		end, 10)
		-- Release an old blocking reader before asserting, so failures cannot hang shutdown.
		local writer = uv.fs_open(path, uv.constants.O_WRONLY + uv.constants.O_NONBLOCK, 0)
		if writer then
			uv.fs_close(writer)
		end
		wait(function()
			return out.done
		end)
		assert(settled, "asynchronous open waited for a FIFO writer")
		assert(not out.bytes and out.err:find("regular file", 1, true), out.err)
	end)

	return cases
end
