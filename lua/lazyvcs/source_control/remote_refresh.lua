local M = {}
local deadlines = {}

---Reserve an automatic attempt before submitting background work.
function M.claim(root, interval_ms, now_ms)
	local count = 0
	for key, deadline in pairs(deadlines) do
		if deadline <= now_ms then
			deadlines[key] = nil
		else
			count = count + 1
		end
	end
	if interval_ms <= 0 then
		deadlines[root] = nil
		return true
	end
	if deadlines[root] or count >= 512 then
		return false
	end
	deadlines[root] = now_ms + interval_ms
	return true
end

return M
