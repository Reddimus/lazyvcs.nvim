-- Metadata checks shared by native Git additions and SVN's descriptor reader.
local uv = vim.uv
local util = require("lazyvcs.util")
local fs = require("lazyvcs.file_io")
local M = {}

M.identity = fs.identity

function M.identified(entry, allow_link)
	return M.identity(entry)
		and (entry.type == "file" or allow_link and entry.type == "link" and not entry.directory_reparse)
end

M.same = fs.same

function M.parent(task, parent, guard, done)
	if not task:is_active() then
		return
	end
	uv.fs_realpath(parent, function(err, physical)
		vim.schedule(guard(function()
			if not physical then
				return task:finish(nil, err)
			end
			physical = util.normalize_literal_path(physical)
			if physical == parent then
				return done()
			end
			local function fail(reason)
				return task:finish(nil, reason or "Patch file parent changed; retry or narrow the patch path")
			end
			local function prefixes(path)
				if path:sub(1, 1) ~= "/" and not path:match("^%a:/") then
					return nil
				end
				local result = {}
				while true do
					result[#result + 1] = path
					local next_parent = vim.fs.dirname(path)
					if next_parent == path then
						return result
					end
					path = next_parent
				end
			end
			local lexical, canonical = prefixes(parent), prefixes(physical)
			if not lexical or not canonical or #lexical ~= #canonical or lexical[#lexical] ~= canonical[#canonical] then
				return fail()
			end
			local component = #lexical
			while component > 0 and lexical[component] == canonical[component] do
				component = component - 1
			end
			local function directory(entry)
				return entry and entry.type == "directory" and M.identity(entry)
			end
			-- A native spelling alias is valid only when every differing prefix
			-- names the same directory without traversing a link or junction.
			local next_component
			next_component = function()
				if not task:is_active() then
					return
				end
				if component == 0 then
					return done()
				end
				fs.fs_lstat(lexical[component], function(left_err, left)
					vim.schedule(guard(function()
						if left_err or not directory(left) then
							return fail(left_err)
						end
						fs.fs_lstat(canonical[component], function(right_err, right)
							vim.schedule(guard(function()
								if right_err or not directory(right) or not M.same(left, right) then
									return fail(right_err)
								end
								component = component - 1
								next_component()
							end))
						end)
					end))
				end)
			end
			next_component()
		end))
	end)
end

function M.check(task, file, expected, guard, done)
	if not task:is_active() then
		return
	end
	local parent = vim.fs.dirname(file)
	fs.fs_lstat(file, function(err, entry)
		if not task:is_active() then
			return
		end
		if not M.identified(entry, true) or expected and not M.same(entry, expected) then
			return vim.schedule(guard(function()
				task:finish(nil, err or "Patch file changed; retry or narrow the patch path")
			end))
		end
		M.parent(task, parent, guard, function()
			done({
				type = entry.type,
				dev = entry.dev,
				ino = entry.ino,
				identity = entry.identity,
				directory_reparse = entry.directory_reparse,
			})
		end)
	end)
end

return M
