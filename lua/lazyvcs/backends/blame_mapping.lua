local M = {}

function M.map(entries, base, current, uncommitted)
	local out, b, c = {}, 1, 1
	for _, hunk in ipairs(require("lazyvcs.diff").compute_hunks(base, current)) do
		local first = hunk.current_count == 0 and hunk.current_start + 1 or hunk.current_start
		while c < first do
			out[c], b, c = entries[b], b + 1, c + 1
		end
		for _ = 1, hunk.current_count do
			out[c], c = uncommitted, c + 1
		end
		b = hunk.base_start + hunk.base_count + (hunk.base_count == 0 and 1 or 0)
	end
	while c <= #current do
		out[c], b, c = entries[b] or uncommitted, b + 1, c + 1
	end
	return out
end
return M
