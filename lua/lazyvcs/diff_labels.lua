-- Presence is endpoint evidence, independent of whether its document is empty.
local M = {}

function M.snapshot(item)
	if item.old_path then
		return { left = "present", right = "present" }
	end
	local added = item.status == "A"
		or item.original_status == "A"
		or item.status == "?"
		or item.untracked
		or item.base_absent
		or item.status == "C"
	return { left = added and "absent" or "present", right = item.status == "D" and "absent" or "present" }
end

local function empty(document)
	return document and document.empty == true
end

function M.labels(left, right, base, presence, left_document, right_document)
	if not presence then
		return left, right
	end
	base = presence.base or base
	if presence.left == "absent" then
		left = "No file at " .. base
		if presence.right == "present" then
			right = right
				.. (
					presence.intent_to_add and " | Intent to add (no staged content)"
					or " | Added (no file at " .. base .. ")"
				)
		end
	end
	if presence.right == "absent" then
		right = presence.right_base and "No file at " .. presence.right_base or "No file in worktree"
		if presence.left == "present" then
			left = left .. " | Deleted from " .. (presence.right_base or "worktree")
		end
	end
	if presence.left == "present" and empty(left_document) then
		left = left .. " | Empty"
	end
	if presence.right == "present" and empty(right_document) then
		right = right .. " | Empty"
	end
	return left, right
end

return M
