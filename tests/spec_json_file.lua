return function(ctx)
	local h = ctx.helpers
	-- Child editors load the plugin from this checkout, whatever the suite's working directory.
	local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
	return {
		{
			"test_source_control_json_write_preserves_previous_on_sync_or_close_failure",
			function()
				local json = require("lazyvcs.json_file")
				for _, seam in ipairs({ "sync", "sync_throw", "close", "close_throw" }) do
					local path = h.tempdir() .. "/state.json"
					assert(json.write(path, { changes_sort = "path" }))
					local sync, close = vim.uv.fs_fsync, vim.uv.fs_close
					local injected = false
					---@diagnostic disable-next-line: duplicate-set-field
					vim.uv.fs_fsync = function(fd)
						if seam:find("sync", 1, true) then
							injected = true
							if seam == "sync_throw" then
								error("EIO sync")
							end
							return nil, "ENOSPC sync"
						end
						return sync(fd)
					end
					---@diagnostic disable-next-line: duplicate-set-field
					vim.uv.fs_close = function(fd)
						local result = close(fd)
						if seam:find("close", 1, true) then
							injected = true
							if seam == "close_throw" then
								error("EIO close")
							end
							return nil, "EIO close"
						end
						return result
					end
					local ok, saved, err = pcall(json.write, path, { changes_sort = "name" })
					vim.uv.fs_fsync, vim.uv.fs_close = sync, close
					assert(injected)
					assert(ok and not saved and err, seam .. " must return a save error")
					assert(json.read(path).changes_sort == "path", seam .. " replaced previous preferences")
					assert(#vim.fn.glob(path .. ".tmp.*", false, true) == 0, "temporary file leaked")
				end
			end,
		},
		{
			"test_source_control_json_read_follows_regular_symlink",
			function()
				local dir = h.tempdir()
				local data = { show_clean = true, changes_sort = "path" }
				h.write_file(dir .. "/target", vim.json.encode({ version = 1, data = data }))
				assert(vim.uv.fs_symlink(dir .. "/target", dir .. "/state.json"))
				assert(
					vim.deep_equal(require("lazyvcs.json_file").read(dir .. "/state.json"), data),
					"symlinked preferences loaded defaults"
				)
			end,
		},
		{
			"test_source_control_json_read_rejects_fifo_swapped_before_open",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX FIFO fixture requires mkfifo" })
				end
				local dir = h.tempdir()
				local path = dir .. "/state.json"
				h.write_file(path, '{"version":1,"data":{"show_clean":true}}')
				-- A child bounds the actual open: a regression must not hang this suite.
				local script = dir .. "/read.lua"
				h.write_file(
					script,
					string.format(
						[[
vim.opt.runtimepath:prepend(%q)
local open = vim.uv.fs_open
local opened, closed, flags_seen = 0, 0, false
local close = vim.uv.fs_close
vim.uv.fs_open = function(name, flags, ...)
	if name == %q then
		assert(vim.uv.fs_unlink(name))
		assert(vim.system({"mkfifo", name}):wait().code == 0)
		flags_seen = type(flags) == "number" and bit.band(flags, vim.uv.constants.O_NONBLOCK) ~= 0
	end
	local fd, err = open(name, flags, ...)
	if fd then opened = opened + 1 end
	return fd, err
end
vim.uv.fs_close = function(fd)
	closed = closed + 1
	return close(fd)
end
assert(vim.deep_equal(require("lazyvcs.json_file").read(%q), {}), "FIFO did not load defaults")
assert(flags_seen, "FIFO open was not nonblocking")
assert(opened == 1 and closed == 1, "FIFO descriptor leaked")
]],
						root,
						path,
						path
					)
				)
				local result = vim.system(
					{ vim.v.progpath, "--headless", "-u", "NONE", "-l", script },
					{ text = true, timeout = 3000 }
				):wait()
				assert(result.code == 0, "FIFO preference read blocked or failed: " .. (result.stderr or ""))
			end,
		},
		{
			"test_source_control_json_read_rejects_fifo_before_open",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX FIFO fixture requires mkfifo; Windows has no POSIX FIFOs" })
				end
				local path = h.tempdir() .. "/state.json"
				h.exec({ "mkfifo", path })
				local open, attempted = vim.uv.fs_open, false
				vim.uv.fs_open = function(name, ...)
					if name == path then
						attempted = true
						return nil, "FIFO open intercepted"
					end
					return open(name, ...)
				end
				local ok, result = pcall(require("lazyvcs.json_file").read, path)
				vim.uv.fs_open = open
				assert(ok, result)
				assert(not attempted, "JSON reader attempted a blocking open on a FIFO")
				assert(vim.deep_equal(require("lazyvcs.json_file").read(path), {}), "real FIFO read did not return")
				assert(vim.deep_equal(result, {}))
			end,
		},
		{
			"test_source_control_json_read_uses_open_descriptor",
			function()
				local json = require("lazyvcs.json_file")
				local path = h.tempdir() .. "/state.json"
				local first, second =
					{ changes_sort = "path" }, { changes_sort = "status", show_clean = true, hidden = { "repository" } }
				local open, fstat, read, close = vim.uv.fs_open, vim.uv.fs_fstat, vim.uv.fs_read, vim.uv.fs_close
				local opened, closed = 0, 0
				local function replace(value, target_open)
					local temp = path .. ".next"
					h.write_file(temp, vim.json.encode({ version = 1, data = value }))
					local renamed, rename_err = vim.uv.fs_rename(temp, path)
					local refusal = tostring(rename_err):match("^%u+")
					if
						not renamed
						and target_open
						and vim.fn.has("win32") == 1
						and (refusal == "EPERM" or refusal == "EACCES" or refusal == "EBUSY")
					then
						-- Windows refuses to rename over a file with an open handle, so the
						-- reader keeps the document it opened either way.
						assert(vim.uv.fs_unlink(temp))
						return
					end
					assert(renamed, rename_err)
				end
				local ok, err = xpcall(function()
					for _, seam in ipairs({ "before", "after", "partial", "eof", "fstat", "read", "throw", "malformed" }) do
						replace(first)
						-- The reader protects fs_open with pcall; keep fixture failures visible.
						local seam_err
						local function during(fn, ...)
							local done, failure = pcall(fn, ...)
							seam_err = seam_err or (not done and failure or nil)
						end
						vim.uv.fs_open = function(name, ...)
							if name == path and seam == "before" then
								during(replace, second)
							end
							local fd, failure = open(name, ...)
							if fd then
								opened = opened + 1
							end
							if name == path and seam == "after" then
								during(replace, second, true)
							end
							return fd, failure
						end
						vim.uv.fs_close = function(fd)
							closed = closed + 1
							return close(fd)
						end
						vim.uv.fs_fstat = function(fd)
							if seam == "fstat" then
								return nil, "EIO"
							end
							return fstat(fd)
						end
						vim.uv.fs_read = function(fd, size, offset)
							if seam == "eof" then
								return ""
							end
							if seam == "read" then
								return nil, "EIO"
							end
							if seam == "throw" then
								error("read failed")
							end
							return read(fd, seam == "partial" and math.min(3, size) or size, offset)
						end
						if seam == "malformed" then
							h.write_file(path, "{bad")
						end
						local value = json.read(path)
						assert(not seam_err, seam .. ": " .. tostring(seam_err))
						local expected = seam == "before" and second
							or ((seam == "after" or seam == "partial") and first or {})
						assert(vim.deep_equal(value, expected), seam .. ": complete opened JSON document lost")
						assert(opened == closed, seam .. ": descriptor leaked")
						vim.uv.fs_open, vim.uv.fs_fstat, vim.uv.fs_read, vim.uv.fs_close = open, fstat, read, close
					end
				end, debug.traceback)
				vim.uv.fs_open, vim.uv.fs_fstat, vim.uv.fs_read, vim.uv.fs_close = open, fstat, read, close
				assert(ok, err)
			end,
		},
	}
end
