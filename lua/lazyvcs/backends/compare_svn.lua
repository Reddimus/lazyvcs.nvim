local common = require("lazyvcs.backends.comparison")
local xml = require("lazyvcs.backends.xml")
local M = {}

local function command(task, repo, args, callback)
	common.command(task, repo, vim.list_extend({ "svn", "--non-interactive" }, args), callback)
end

function M.context(repo, callback)
	local task = common.task(callback)
	command(task, repo, { "info", "--xml", repo.root .. "@" }, function(raw, err)
		local info = raw and xml.parse_info(raw)
		if not info or not info.url then
			return task:finish(nil, err or "SVN returned no working-copy URL")
		end
		task:finish({ branch = info.url, suggestion = info.url .. "@" .. info.revision, candidates = {} })
	end)
	return task
end

function M.resolve(repo, base, callback)
	local task = common.task(callback)
	local url, revision = base:match("^(.-)@([^@/]+)$")
	if not url then
		url, revision = base, "HEAD"
	end
	if not url:match("^%a[%w+.-]*://") or not (revision:match("^%d+$") or revision == "HEAD") then
		vim.schedule(function()
			task:finish(nil, "Use a repository URL@revision, with a numeric revision or HEAD")
		end)
		return task
	end
	command(task, repo, { "info", "--xml", "-r", revision, url .. "@" .. revision }, function(raw, err)
		local info = raw and xml.parse_info(raw)
		if not info or not info.url or not info.revision then
			return task:finish(nil, err or "SVN base could not be resolved")
		end
		task:finish({ root = repo.root, vcs = "svn", base = base, url = info.url, revision = info.revision })
	end)
	return task
end

local function decode_url(path)
	return (path:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

local function encode_path(path)
	return (path:gsub("[^%w%-%._~/]", function(char)
		return string.format("%%%02X", char:byte())
	end))
end

function M.list(snapshot, include_untracked, callback)
	local task = common.task(callback)
	command(task, snapshot, {
		"diff",
		"--summarize",
		"--xml",
		"--old",
		snapshot.url .. "@" .. snapshot.revision,
		"--new",
		snapshot.root .. "@",
	}, function(raw, err)
		if not raw then
			return task:finish(nil, err)
		end
		local items, seen = {}, {}
		for attributes, value in raw:gmatch("<path%s+([^>]+)>(.-)</path>") do
			local attrs = xml.attributes(attributes)
			local path = xml.decode(value)
			local relpath
			if path == snapshot.url or path == snapshot.root then
				relpath = "."
			elseif path:sub(1, #snapshot.url + 1) == snapshot.url .. "/" then
				relpath = decode_url(path:sub(#snapshot.url + 2))
			elseif path:sub(1, #snapshot.root + 1) == snapshot.root .. "/" then
				relpath = path:sub(#snapshot.root + 2)
			end
			if not common.relative(relpath) then
				return task:finish(nil, "SVN returned a path outside the comparison")
			end
			local code = ({ added = "A", deleted = "D", modified = "M", normal = "M", none = "M" })[attrs.item] or "M"
			items[#items + 1] = {
				relpath = relpath,
				status = code,
				property_only = attrs.kind == "dir" or attrs.item == "none",
				kind = attrs.kind,
				properties = attrs.props == "modified",
			}
			seen[relpath] = true
		end
		local function finish()
			table.sort(items, function(a, b)
				return a.relpath < b.relpath
			end)
			task:finish(items)
		end
		if not include_untracked then
			return finish()
		end
		command(task, snapshot, { "status", "--xml", snapshot.root .. "@" }, function(status, status_err)
			if not status then
				return task:finish(nil, status_err)
			end
			local pending = {}
			for _, entry in ipairs(xml.parse_status(status)) do
				if entry.wc_item == "unversioned" then
					pending[#pending + 1] = entry.path
				end
			end
			local cursor, scanned = 0, 0
			local ignored
			local function visit()
				cursor = cursor + 1
				local path = pending[cursor]
				if not path then
					return finish()
				end
				vim.uv.fs_lstat(path, function(stat_err, stat)
					vim.schedule(function()
						if not task:is_active() then
							return
						end
						if stat_err then
							if tostring(stat_err):match("ENOENT") then
								visit()
								return
							end
							task:finish(nil, stat_err)
							return
						end
						if stat.type == "directory" then
							vim.uv.fs_scandir(path, function(scan_err, handle)
								local consume
								consume = function()
									if not task:is_active() then
										return
									end
									if not handle then
										if tostring(scan_err):match("ENOENT") then
											visit()
											return
										end
										task:finish(nil, scan_err)
										return
									end
									for _ = 1, 128 do
										local name = vim.uv.fs_scandir_next(handle)
										if not name then
											visit()
											return
										end
										scanned = scanned + 1
										if
											name ~= ".svn"
											and name ~= ".git"
											and not ignored(path .. "/" .. name, name)
										then
											pending[#pending + 1] = path .. "/" .. name
										end
										if #pending > 10000 or scanned > 100000 then
											task:finish(
												nil,
												"Untracked discovery exceeded its path limit; exclude untracked files or narrow the working copy"
											)
											return
										end
									end
									vim.schedule(consume)
								end
								vim.schedule(consume)
							end)
							return
						end
						local relpath = path:sub(#snapshot.root + 2)
						if not seen[relpath] then
							items[#items + 1] = { relpath = relpath, status = "?", untracked = true }
							seen[relpath] = true
						end
						visit()
					end)
				end)
			end
			if #pending == 0 then
				return finish()
			end
			require("lazyvcs.backends.svn_ignore").load(task, snapshot, function(predicate, ignore_err)
				if not predicate then
					return task:finish(nil, ignore_err)
				end
				ignored = predicate
				visit()
			end)
		end)
	end)
	return task
end

function M.preview(snapshot, item, callback)
	local task = common.task(callback)
	local path = snapshot.root .. "/" .. item.relpath
	local url = snapshot.url .. (item.relpath == "." and "" or "/" .. encode_path(item.relpath))
	local result = { left_label = snapshot.url .. " @ r" .. snapshot.revision, right_label = "SAVED WORKTREE" }
	local function finish()
		if not item.properties then
			return task:finish(result)
		end
		command(task, snapshot, {
			"diff",
			"--properties-only",
			"--depth",
			item.kind == "dir" and "empty" or "files",
			"--old",
			url .. "@" .. snapshot.revision,
			"--new",
			path .. "@",
		}, function(raw, err)
			if not raw then
				return task:finish(nil, err)
			end
			result.properties = require("lazyvcs.util").split_lines(raw)
			task:finish(result)
		end)
	end
	if item.property_only then
		command(task, snapshot, {
			"diff",
			"--properties-only",
			"--depth",
			item.kind == "dir" and "empty" or "files",
			"--old",
			url .. "@" .. snapshot.revision,
			"--new",
			path .. "@",
		}, function(raw, err)
			if not raw then
				return task:finish(nil, err)
			end
			result.left, result.right = {}, require("lazyvcs.util").split_lines(raw)
			result.right_label = "PROPERTY PATCH"
			task:finish(result)
		end)
		return task
	end
	local function right()
		if item.status == "D" then
			result.right = {}
			return finish()
		end
		common.read_file(task, path, function(data, err)
			if not data then
				return task:finish(nil, err)
			end
			local stat = vim.uv.fs_lstat(path)
			if stat and stat.type == "link" then
				data = "link " .. data
			end
			local lines, line_err = common.lines(data)
			if not lines then
				return task:finish(nil, line_err)
			end
			result.right = lines
			finish()
		end)
	end
	if item.status == "A" or item.untracked then
		result.left = {}
		right()
	else
		command(task, snapshot, { "cat", "-r", snapshot.revision, url .. "@" .. snapshot.revision }, function(raw, err)
			if not raw then
				return task:finish(nil, err)
			end
			local lines, line_err = common.lines(raw)
			if not lines then
				return task:finish(nil, line_err)
			end
			result.left = lines
			right()
		end)
	end
	return task
end

return M
