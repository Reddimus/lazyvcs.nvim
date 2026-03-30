local git = require("lazyvcs.backends.git")
local svn = require("lazyvcs.backends.svn")

local M = {}

local backends = { git, svn }

function M.load(path)
	local best

	for _, backend in ipairs(backends) do
		local info = backend.probe(path)
		if info and (not best or #info.root > #best.root) then
			best = { backend = backend, root = info.root }
		end
	end

	if not best then
		return nil, "No Git or SVN working copy found for " .. path
	end

	return best.backend.load(path)
end

return M
