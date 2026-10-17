local util = require("lazyvcs.util")
local runtime = require("lazyvcs.process_runtime")

local M = {}

function M.new()
	local names, owned = {}, {}
	local registry = { shutdown = function() end, force = function() end, close_timers = function() end }
	function registry:record(path)
		if type(path) == "string" then
			names[path] = true
		end
		return path
	end
	function registry:adopt(opts)
		for _, key in ipairs({ "body", "in_file", "output" }) do
			local path = opts and opts[key]
			if type(path) == "string" and names[path] and not owned[path] then
				-- Capture identity before the leaf can return or another request can replace it.
				local stat = vim.uv.fs_lstat(path)
				if stat and stat.type == "file" then
					owned[path] = stat
				end
			end
		end
	end
	function registry:release(done)
		local paths = owned
		names, owned = {}, {}
		runtime.track(self)
		local pending = 1
		local function complete(err)
			if err and not tostring(err):match("^ENOENT:") then
				util.safe_callback(function()
					error("CopilotChat request file cleanup failed: " .. (tostring(err):gsub("[\r\n]+", " ")), 0)
				end)()
			end
			pending = pending - 1
			if pending == 0 then
				runtime.untrack(self)
				if done then
					done()
				end
			end
		end
		for path, identity in pairs(paths) do
			pending = pending + 1
			vim.uv.fs_lstat(
				path,
				util.safe_callback(function(err, stat)
					if err then
						complete(err)
					elseif stat.type == identity.type and stat.dev == identity.dev and stat.ino == identity.ino then
						vim.uv.fs_unlink(path, util.safe_callback(complete))
					else
						complete()
					end
				end)
			)
		end
		complete()
	end
	return registry
end

return M
