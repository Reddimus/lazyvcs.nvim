local common = require("lazyvcs.backends.comparison")
local xml = require("lazyvcs.backends.xml")
local M = {}

local function command(task, repo, args, callback, opts)
	common.command(task, repo, vim.list_extend({ "svn", "--non-interactive" }, args), callback, opts)
end

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
		schedule(task, function()
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

local function local_path(path)
	path = xml.local_path(path)
	if vim.fn.has("win32") == 1 then
		path = path:gsub("^%a:", string.lower)
	end
	return path
end

-- SVN uses native endings for its syntax, but value lines retain their own bytes.
local function property_lines(raw)
	local lines = require("lazyvcs.util").split_lines(raw)
	local in_hunk = false
	for index, line in ipairs(lines) do
		local text = line:gsub("\r$", "")
		local section = text:match("^Index: ") or text:match("^Property changes on: ")
		if section then
			in_hunk = false
		end
		local hunk = text:match("^## %-%d+,?%d* %+%d+,?%d* ##$")
		local marker = text == "\\ No newline at end of property"
		if
			section
			or text == ""
			or text:match("^=+$")
			or text:match("^_+$")
			or text:match("^Added: ")
			or text:match("^Modified: ")
			or text:match("^Deleted: ")
			or hunk
			or marker
			or (not in_hunk and (text:match("^%-%-%- ") or text:match("^%+%+%+ ")))
		then
			lines[index] = text
		end
		if marker and line ~= text and index > 1 then
			-- An unterminated value gets SVN's native newline before the marker.
			lines[index - 1] = lines[index - 1]:gsub("\r$", "")
		end
		if hunk then
			in_hunk = true
		end
	end
	return lines
end

local function load_property_patch(task, snapshot, item, done)
	if item.kind == "dir" or item.status == "R" then
		return require("lazyvcs.backends.svn_properties").load_directory_patch(task, snapshot, item, done)
	end
	local path = snapshot.root .. "/" .. item.relpath
	local url = require("lazyvcs.backends.svn_url").append_path(snapshot.url, item.relpath)
	command(task, snapshot, {
		"diff",
		"--properties-only",
		"--depth",
		item.kind == "dir" and "empty" or "files",
		"--old",
		url .. "@" .. snapshot.revision,
		"--new",
		path .. "@",
	}, function(raw, err, result)
		if (result and result.stdout_truncated) or (raw and #raw > common.max_file_bytes) then
			err = "Property patch exceeds the 1 MiB preview limit"
		end
		done(raw and raw ~= "" and property_lines(raw) or nil, err)
	end, { output_limit_bytes = 2 * common.max_file_bytes })
end

function M.list(snapshot, include_untracked, callback)
	local task = common.task(callback)
	local root = local_path(snapshot.root)
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
			if not path:match("^%a[%w+.-]*://") then
				path = local_path(path)
			end
			local relpath
			if path == snapshot.url or path == root then
				relpath = "."
			elseif path:sub(1, #snapshot.url + 1) == snapshot.url .. "/" then
				relpath = decode_url(path:sub(#snapshot.url + 2))
			elseif path:sub(1, #root + 1) == root .. "/" then
				relpath = path:sub(#root + 2)
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
			local merged, paths = {}, {}
			for _, item in ipairs(items) do
				local previous = paths[item.relpath]
				if previous then
					if
						not (
							(previous.status == "D" and item.status == "A")
							or (previous.status == "A" and item.status == "D")
						)
					then
						return task:finish(nil, "Duplicate SVN comparison path: " .. item.relpath)
					end
					local before = previous.status == "D" and previous or item
					local after = previous.status == "A" and previous or item
					previous.kind_before, previous.kind_after = before.kind, after.kind
					previous.status, previous.kind = "R", after.kind
					previous.properties = before.properties or after.properties
					previous.load_properties, previous.property_only = true, false
				else
					paths[item.relpath] = item
					merged[#merged + 1] = item
				end
			end
			local cursor, retained = 0, {}
			local function reconcile()
				if not task:is_active() then
					return
				end
				while cursor < #merged do
					cursor = cursor + 1
					local item = merged[cursor]
					if item.status == "M" and item.kind == "dir" and item.property_only then
						return require("lazyvcs.backends.svn_properties").load_directory_maps(
							task,
							snapshot,
							item,
							function(before, after, check_err)
								if not before or not after or not vim.deep_equal(before, after) then
									item.property_check_error = check_err
										or ((not before or not after) and "Property values unavailable" or nil)
									retained[#retained + 1] = item
								end
								schedule(task, reconcile)
							end
						)
					end
					retained[#retained + 1] = item
				end
				table.sort(retained, function(a, b)
					return a.relpath < b.relpath
				end)
				task:finish(retained)
			end
			reconcile()
		end
		if not include_untracked then
			return finish()
		end
		command(task, snapshot, { "status", "--xml", snapshot.root .. "@" }, function(status, status_err)
			if not status then
				return task:finish(nil, status_err)
			end
			local pending, switched = {}, {}
			for _, entry in ipairs(xml.parse_status(status)) do
				if entry.switched then
					switched[#switched + 1] = entry.path
				end
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
					schedule(task, function()
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
									schedule(task, consume)
								end
								schedule(task, consume)
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
			end, switched)
		end)
	end)
	return task
end

function M.preview(snapshot, item, callback, opts)
	local task = common.task(callback)
	local path = snapshot.root .. "/" .. item.relpath
	local url = require("lazyvcs.backends.svn_url").append_path(snapshot.url, item.relpath)
	local result = {
		left_label = snapshot.url .. " @ r" .. snapshot.revision,
		right_label = "SAVED WORKTREE",
		loaded = { text = not (opts and opts.mode == "metadata"), metadata = true },
	}
	if item.property_check_error then
		result.details = { "Property validation failed: " .. tostring(item.property_check_error):gsub("%s+", " ") }
	end
	local function finish()
		if
			not (
				item.properties
				or item.property_only
				or item.load_properties
				or (item.status == "A" and not item.untracked)
			)
		then
			return task:finish(result)
		end
		load_property_patch(task, snapshot, item, function(lines, err)
			result.properties = lines
			if err then
				result.details = vim.list_extend(
					result.details or {},
					require("lazyvcs.util").split_text_lines("Properties unavailable: " .. tostring(err))
				)
			end
			task:finish(result)
		end)
	end
	if opts and opts.mode == "metadata" then
		schedule(task, finish)
		return task
	end
	if item.property_only then
		load_property_patch(task, snapshot, item, function(lines, err)
			if err then
				return task:finish(nil, err)
			end
			result.left, result.right = {}, lines or {}
			result.properties = lines
			result.right_label = "PROPERTY PATCH"
			task:finish(result)
		end)
		return task
	end
	local left_options = common.decode_options(path)
	local right_options = vim.deepcopy(left_options)
	left_options.hint = nil
	local function right()
		if item.kind_after == "dir" then
			result.right = { "Directory: " .. vim.fn.strtrans(item.relpath) }
			return finish()
		end
		if item.status == "D" then
			common.decode_side(result, "right", "", { encoding = "utf-8" })
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
			local decoded, line_err = common.decode_side(result, "right", data, right_options)
			if not decoded then
				return task:finish(nil, line_err)
			end
			finish()
		end)
	end
	if item.kind_before == "dir" then
		result.left = { "Directory: " .. vim.fn.strtrans(item.relpath) }
		right()
	elseif item.status == "A" or item.untracked then
		common.decode_side(result, "left", "", { encoding = "utf-8" })
		right()
	else
		command(task, snapshot, { "cat", "-r", snapshot.revision, url .. "@" .. snapshot.revision }, function(raw, err)
			if not raw then
				return task:finish(nil, err)
			end
			local decoded, line_err = common.decode_side(result, "left", raw, left_options)
			if not decoded then
				return task:finish(nil, line_err)
			end
			right()
		end)
	end
	return task
end

return M
