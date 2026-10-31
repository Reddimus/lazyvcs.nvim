local common = require("lazyvcs.backends.comparison")
local util = require("lazyvcs.util")
local M = {}

local function schedule(task, callback)
	vim.schedule(function()
		if not task:is_active() then
			return
		end
		local ok, err = pcall(callback)
		if not ok then
			task:kill()
			require("lazyvcs.util").notify("SVN comparison: " .. tostring(err):gsub("%s+", " "), vim.log.levels.ERROR)
		end
	end)
end

-- Expand only native unversioned rows. lstat keeps directory symlinks as entries.
function M.expand(task, repo, entries, callback, opts)
	opts = opts or {}
	local items, seen = {}, {}
	local identities = opts.capture_identity and {} or nil
	local pending, switched = {}, {}
	for _, entry in ipairs(entries) do
		if entry.switched or entry.wc_item == "external" then
			switched[#switched + 1] = { path = entry.path, recursive = entry.wc_item == "external" }
		end
		if entry.wc_item == "unversioned" then
			pending[#pending + 1] = util.normalize_literal_path(
				common.relative(entry.path) and (repo.root .. "/" .. entry.path) or entry.path
			)
		end
	end
	local cursor, scanned = 0, 0
	local ignored
	local function visit()
		cursor = cursor + 1
		local path = pending[cursor]
		if not path then
			return callback(items, nil, identities)
		end
		vim.uv.fs_lstat(path, function(stat_err, stat)
			schedule(task, function()
				if not task:is_active() then
					return
				end
				if stat_err then
					if not opts.missing_is_error and tostring(stat_err):match("ENOENT") then
						visit()
						return
					end
					callback(nil, stat_err)
					return
				end
				if stat.type == "directory" then
					local function scan()
						vim.uv.fs_scandir(path, function(scan_err, handle)
							local consume
							consume = function()
								if not task:is_active() then
									return
								end
								if not handle then
									if not opts.missing_is_error and tostring(scan_err):match("ENOENT") then
										visit()
										return
									end
									callback(nil, scan_err)
									return
								end
								for _ = 1, 128 do
									local name = vim.uv.fs_scandir_next(handle)
									if not name then
										visit()
										return
									end
									scanned = scanned + 1
									if name ~= ".svn" and name ~= ".git" and not ignored(path .. "/" .. name, name) then
										pending[#pending + 1] = path .. "/" .. name
									end
									if #pending > 10000 or scanned > 100000 then
										callback(
											nil,
											"Untracked discovery exceeded its path limit; exclude untracked files or narrow the working copy"
										)
										return
									end
								end
								schedule(task, consume)
							end
							schedule(task, consume)
						end)
					end
					-- Follow administrative markers only; directory entries above stay literal.
					vim.uv.fs_stat(path .. "/.svn", function(_, svn)
						vim.uv.fs_stat(path .. "/.git", function(_, git)
							schedule(task, function()
								if
									(svn and svn.type == "directory")
									or (git and (git.type == "file" or git.type == "directory"))
								then
									visit()
								else
									scan()
								end
							end)
						end)
					end)
					return
				end
				if opts.files_only and stat.type ~= "file" then
					return visit()
				end
				local relpath = path:sub(#repo.root + 2)
				if not seen[relpath] then
					items[#items + 1] = relpath
					seen[relpath] = true
					if identities then
						identities[relpath] = { type = stat.type, dev = stat.dev, ino = stat.ino }
					end
				end
				visit()
			end)
		end)
	end
	if #pending == 0 then
		return callback(items, nil, identities)
	end
	require("lazyvcs.backends.svn_ignore").load(task, repo, function(predicate, ignore_err)
		if not predicate then
			return callback(nil, ignore_err)
		end
		ignored = predicate
		visit()
	end, switched)
end

return M
