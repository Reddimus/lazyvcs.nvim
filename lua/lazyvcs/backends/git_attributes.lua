local M = {}

function M.parse(raw, expected_path)
	local attrs, cursor = {}, 1
	while cursor <= #raw do
		local fields = {}
		for i = 1, 3 do
			local last = raw:find("\0", cursor, true)
			if not last then
				return nil, "Incomplete Git attribute record"
			end
			fields[i], cursor = raw:sub(cursor, last - 1), last + 1
		end
		if not expected_path or fields[1] == expected_path then
			attrs[fields[2]] = fields[3]
		end
	end
	return attrs
end

function M.encoding(attrs)
	local value = attrs["working-tree-encoding"]
	return value and value ~= "unspecified" and value ~= "unset" and value or nil
end

return M
