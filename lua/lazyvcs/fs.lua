local M = {}

function M.write_all(fd, data, offset)
	offset = offset or 0
	local total = 0
	while total < #data do
		local remaining = data:sub(total + 1)
		local written, err = vim.uv.fs_write(fd, remaining, offset + total)
		if not written then
			return nil, err
		end
		if written <= 0 or written > #remaining then
			return nil, "File write made invalid progress"
		end
		total = total + written
	end
	return total
end

function M.read_exact(fd, size, offset)
	offset = offset or 0
	local chunks, total = {}, 0
	while total < size do
		local chunk, err = vim.uv.fs_read(fd, size - total, offset + total)
		if not chunk then
			return nil, err
		end
		if #chunk == 0 or #chunk > size - total then
			return nil, "File read made invalid progress"
		end
		chunks[#chunks + 1], total = chunk, total + #chunk
	end
	return table.concat(chunks)
end

-- Follow working-file links, cap allocation, and yield between read chunks.
function M.read_file_async(task, path, limit, done)
	local uv = vim.uv
	local fd, chunks, total = nil, {}, 0
	local function finish(bytes, err)
		local owned = fd
		fd = nil
		local function deliver(close_err)
			vim.schedule(function()
				if task:is_active() then
					done(bytes, err or close_err)
				end
			end)
		end
		if owned then
			uv.fs_close(owned, deliver)
		else
			deliver()
		end
	end
	local read_next
	read_next = function()
		if not task:is_active() then
			return finish()
		end
		local opened = fd
		if not opened then
			return finish(nil, "File closed before read")
		end
		uv.fs_read(opened, math.min(65536, limit + 1 - total), total, function(err, bytes)
			vim.schedule(function()
				if not task:is_active() then
					return finish()
				end
				if err then
					return finish(nil, err)
				end
				if #bytes == 0 then
					return finish(table.concat(chunks))
				end
				total = total + #bytes
				if total > limit then
					return finish(nil, "File exceeds the blame byte limit")
				end
				chunks[#chunks + 1] = bytes
				read_next()
			end)
		end)
	end
	uv.fs_open(path, "r", 0, function(err, opened)
		fd = opened
		vim.schedule(function()
			if not task:is_active() or not fd then
				return finish(nil, err)
			end
			uv.fs_fstat(fd, function(stat_err, stat)
				vim.schedule(function()
					if not task:is_active() then
						return finish()
					end
					if not stat then
						return finish(nil, stat_err)
					end
					if stat.type ~= "file" then
						return finish(nil, "Blame requires a regular file")
					end
					if stat.size > limit then
						return finish(nil, "File exceeds the blame byte limit")
					end
					read_next()
				end)
			end)
		end)
	end)
end

return M
