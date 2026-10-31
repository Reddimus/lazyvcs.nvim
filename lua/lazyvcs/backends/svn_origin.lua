local util = require("lazyvcs.util")
local xml = require("lazyvcs.backends.xml")
local Task = require("lazyvcs.backends.task")
local M = {}

-- Children of an uncommitted directory copy have normal schedules and destination
-- URLs. Only the copied ancestor records the repository URL that owns their BASE.
function M.copy_async(root, path, info, start, callback, opts)
	local task = Task.new(callback)
	task:set_deadline(opts.timeout or opts.timeout_ms or 30000, "SVN copy ancestry lookup timed out")
	local visit
	visit = function(parent)
		if not parent or not util.relative_literal_path(root, parent) then
			return task:finish(nil, "SVN copied path has no repository origin metadata")
		end
		task:add(start({ "svn", "info", "--xml", util.svn_target(parent) }, opts, function(raw, err)
			if not task:is_active() then
				return
			end
			if not raw then
				return task:finish(nil, err)
			end
			local ancestor = xml.parse_info(raw)
			if not ancestor then
				return task:finish(nil, "SVN returned no copy ancestor metadata")
			end
			if ancestor.copy_from_url and ancestor.copy_from_revision then
				local suffix = util.relative_literal_path(parent, path)
				if not suffix then
					return task:finish(nil, "SVN copy entry moved during ancestry lookup")
				end
				return task:finish({
					url = require("lazyvcs.backends.svn_url").append_path(ancestor.copy_from_url, suffix),
					-- A copied directory may contain mixed-revision children.
					revision = info.revision and info.revision:match("^%d+$") and info.revision
						or ancestor.copy_from_revision,
				})
			end
			if parent == root then
				return task:finish(nil, "SVN copied path has no repository origin metadata")
			end
			visit(vim.fs.dirname(parent))
		end))
	end
	visit(vim.fs.dirname(path))
	return task
end

return M
