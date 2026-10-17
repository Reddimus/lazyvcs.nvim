local M = {}

function M.is_unmerged(status)
	return ({ DD = true, AU = true, UA = true, UD = true, DU = true, AA = true, UU = true })[status] == true
end

function M.parse(raw)
	local entries, cursor = {}, 1
	raw = raw or ""
	while cursor <= #raw do
		local last = raw:find("\0", cursor, true)
		if not last then
			return nil, "Incomplete Git status record"
		end
		local record = raw:sub(cursor, last - 1)
		if #record < 4 or record:sub(3, 3) ~= " " then
			return nil, "Invalid Git status record"
		end
		local item = { status = record:sub(1, 2), path = record:sub(4) }
		cursor = last + 1
		if item.status:find("R", 1, true) or item.status:find("C", 1, true) then
			last = raw:find("\0", cursor, true)
			if not last or last == cursor then
				return nil, "Incomplete Git rename record"
			end
			item.renamed_from, cursor = raw:sub(cursor, last - 1), last + 1
		end
		entries[#entries + 1] = item
	end
	return entries
end

return M
