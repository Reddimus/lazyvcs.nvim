-- Metadata checks shared by native Git additions and SVN's descriptor reader.
local uv = vim.uv
local util = require("lazyvcs.util")
local M = {}

function M.identified(entry, allow_link)
	return entry
		and (entry.type == "file" or allow_link and entry.type == "link")
		and type(entry.dev) == "number"
		and entry.dev >= 0
		and type(entry.ino) == "number"
		and entry.ino > 0
end

function M.parent(task, parent, ignorecase, guard, done)
	if not task:is_active() then
		return
	end
	uv.fs_realpath(parent, function(err, physical)
		vim.schedule(guard(function()
			if not physical then
				return task:finish(nil, err)
			end
			physical = util.normalize_literal_path(physical)
			if ignorecase then
				physical, parent = physical:lower(), parent:lower()
			end
			if physical ~= parent then
				return task:finish(nil, "Patch file parent changed; retry or narrow the patch path")
			end
			done()
		end))
	end)
end

function M.check(task, file, expected, ignorecase, guard, done)
	if not task:is_active() then
		return
	end
	local parent = vim.fs.dirname(file)
	uv.fs_lstat(file, function(err, entry)
		if not task:is_active() then
			return
		end
		if
			not M.identified(entry, true)
			or expected and (entry.type ~= expected.type or entry.dev ~= expected.dev or entry.ino ~= expected.ino)
		then
			return vim.schedule(guard(function()
				task:finish(nil, err or "Patch file changed; retry or narrow the patch path")
			end))
		end
		M.parent(task, parent, ignorecase, guard, function()
			done({ type = entry.type, dev = entry.dev, ino = entry.ino })
		end)
	end)
end

return M
