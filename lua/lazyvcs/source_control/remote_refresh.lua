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

local snapshots, pending = {}, setmetatable({}, { __mode = "v" })
local serial, clock, retained_bytes = 0, 0, 0
local listener

local function remove(root)
	local old = snapshots[root]
	if old then
		retained_bytes = retained_bytes - old.bytes
		snapshots[root] = nil
	end
end

function M.read(root)
	local snapshot = snapshots[root]
	if snapshot then
		clock = clock + 1
		snapshot.used = clock
		return { items = vim.deepcopy(snapshot.items), version = snapshot.version }
	end
end

function M.begin(root)
	serial = serial + 1
	local token = { root = root, version = serial }
	pending[root] = token
	return token
end

function M.publish(token, items)
	if pending[token.root] ~= token then
		return false
	end
	pending[token.root] = nil
	remove(token.root)
	local bytes = #vim.json.encode(items)
	if bytes <= 4 * 1024 * 1024 then
		clock = clock + 1
		snapshots[token.root] = { items = vim.deepcopy(items), version = token.version, bytes = bytes, used = clock }
		retained_bytes = retained_bytes + bytes
	end
	local count = vim.tbl_count(snapshots)
	while count > 512 or retained_bytes > 4 * 1024 * 1024 do
		local oldest, used
		for root, snapshot in pairs(snapshots) do
			if not used or snapshot.used < used then
				oldest, used = root, snapshot.used
			end
		end
		remove(oldest)
		count = count - 1
	end
	if listener then
		listener(token.root)
	end
	return true
end

function M.invalidate(root)
	pending[root] = nil
	remove(root)
	if listener then
		listener(root)
	end
end

function M.set_listener(callback)
	listener = callback
end

return M
