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

return M
