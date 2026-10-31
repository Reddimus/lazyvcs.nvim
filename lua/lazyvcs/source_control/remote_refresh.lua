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
local epochs = setmetatable({}, { __mode = "v" })
local serial, clock, retained_bytes = 0, 0, 0
-- Remember bounded-cache losses separately from roots that have never been checked.
local dropped = {}
local listener

local function remove(root)
	local old = snapshots[root]
	if old then
		retained_bytes = retained_bytes - old.bytes
		snapshots[root] = nil
	end
end

local function mark_dropped(root)
	clock = clock + 1
	dropped[root] = clock
	if vim.tbl_count(dropped) > 512 then
		local oldest, used
		for key, stamp in pairs(dropped) do
			if not used or stamp < used then
				oldest, used = key, stamp
			end
		end
		dropped[oldest] = nil
	end
end

function M.is_dropped(root)
	return dropped[root] ~= nil
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
	local epoch = epochs[root] or {}
	epochs[root] = epoch
	local token = { root = root, version = serial, epoch = epoch }
	pending[root] = token
	return token
end

function M.publish(token, items)
	if epochs[token.root] ~= token.epoch or (token.epoch.published and token.epoch.published > token.version) then
		return false
	end
	if pending[token.root] == token then
		pending[token.root] = nil
	end
	token.epoch.published = token.version
	remove(token.root)
	local bytes = #vim.json.encode(items)
	if bytes <= 4 * 1024 * 1024 then
		dropped[token.root] = nil
		clock = clock + 1
		snapshots[token.root] = { items = vim.deepcopy(items), version = token.version, bytes = bytes, used = clock }
		retained_bytes = retained_bytes + bytes
	else
		mark_dropped(token.root)
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
		mark_dropped(oldest)
		if listener then
			listener(oldest)
		end
		count = count - 1
	end
	if listener then
		listener(token.root)
	end
	return true
end

function M.invalidate(root)
	epochs[root] = nil
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
