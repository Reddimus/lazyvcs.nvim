local util = require("lazyvcs.util")
local M = {}
local active = {}

function M.register(root, owner, cancel)
	local registration = { root = root, owner = owner, cancel = cancel }
	active[registration] = true
	return registration
end

function M.release(registration)
	if not registration or not active[registration] then
		return false
	end
	active[registration] = nil
	return true
end

function M.cancel(root, owner, reason)
	local matches = {}
	for registration in pairs(active) do
		if (not root or root == registration.root) and (not owner or owner == registration.owner) then
			active[registration] = nil
			matches[#matches + 1] = registration
		end
	end
	for _, registration in ipairs(matches) do
		util.safe_callback(registration.cancel)(reason or "user")
	end
	return #matches
end

require("lazyvcs.process_runtime").before_shutdown(function()
	M.cancel(nil, nil, "shutdown")
end)

return M
