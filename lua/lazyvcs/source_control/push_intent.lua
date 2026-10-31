local M = {}

function M.policy_args()
	return { "git", "config", "--get", "--default", "simple", "push.default" }
end

function M.policy_error(branch, target, policy)
	if policy == "upstream" then
		return
	end
	if target == "refs/heads/" .. branch then
		return
	end
	return "Push refused: "
		.. branch
		.. " would update "
		.. target
		.. " with push.default="
		.. policy
		.. ". Fix the upstream, or explicitly set push.default=upstream if this destination is intentional."
end

function M.target_args(intent)
	return { "git", "rev-parse", "--verify", intent.full .. "^{commit}" }
end

function M.valid_oid(value)
	return type(value) == "string" and (#value == 40 or #value == 64) and value:match("^%x+$") ~= nil
end

function M.upstream_signature(intent)
	local fields = { "refs/heads/" .. intent.branch, "", "", "" }
	if not intent.missing then
		fields[2], fields[3], fields[4] = intent.full, intent.remote, intent.target
	end
	return table.concat(fields, "\0") .. "\n"
end

return M
