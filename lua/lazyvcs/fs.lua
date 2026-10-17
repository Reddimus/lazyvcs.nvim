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

return M
