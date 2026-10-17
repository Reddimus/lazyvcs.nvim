return function(ctx)
	local h = ctx.helpers
	return {
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
				local function replace(value)
					local temp = path .. ".next"
					h.write_file(temp, vim.json.encode({ version = 1, data = value }))
					assert(vim.uv.fs_rename(temp, path))
				end
				local ok, err = xpcall(function()
					for _, seam in ipairs({ "before", "after", "partial", "eof", "fstat", "read", "throw", "malformed" }) do
						replace(first)
						vim.uv.fs_open = function(name, ...)
							if name == path and seam == "before" then
								replace(second)
							end
							local fd, failure = open(name, ...)
							if fd then
								opened = opened + 1
							end
							if name == path and seam == "after" then
								replace(second)
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
