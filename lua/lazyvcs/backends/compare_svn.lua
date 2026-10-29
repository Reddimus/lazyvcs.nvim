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
	if item.kind == "dir" or item.status == "R" or item.status == "D" then
		return require("lazyvcs.backends.svn_properties").load_directory_patch(task, snapshot, item, done)
	end
	local path = snapshot.root .. "/" .. item.relpath
	local url = require("lazyvcs.backends.svn_url").append_path(snapshot.url, item.relpath)
	command(task, snapshot, {
		"diff",
		"--properties-only",
		"--depth",
		"files",
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

-- SVN status omits node kinds, and a missing node cannot be inspected on disk.
-- Ask svn info for each topmost missing path; depth infinity covers its children.
local function missing_kinds(task, snapshot, paths, callback)
	local util = require("lazyvcs.util")
	local root, targets = local_path(snapshot.root), {}
	for path in pairs(paths) do
		local parent, topmost = path, true
		while topmost do
			parent = parent:match("^(.+)/[^/]+$")
			if not parent then
				break
			end
			topmost = not paths[parent]
		end
		if topmost then
			targets[#targets + 1] = path
		end
	end
	table.sort(targets)
	local kinds, index = {}, 1
	local function batch()
		if index > #targets then
			return callback(kinds)
		end
		-- Bound each command line for Windows.
		local args, length = { "info", "--xml", "--depth", "infinity", "--" }, 0
		while index <= #targets and length < 8192 do
			local target = snapshot.root .. "/" .. targets[index] .. "@"
			args[#args + 1], length, index = target, length + #target + 1, index + 1
		end
		command(task, snapshot, args, function(raw, err)
			if not raw then
				return callback(nil, err)
			end
			for _, entry in ipairs(xml.parse_info_entries(raw)) do
				local path = local_path(entry.path)
				local relpath = common.relative(path) and path or util.relative_literal_path(root, path)
				if relpath then
					kinds[relpath] = entry.kind
				end
			end
			batch()
		end, { output_limit_bytes = 16 * common.max_file_bytes })
	end
	batch()
end

function M.list(snapshot, include_untracked, callback)
	local task = common.task(callback)
	local root = local_path(snapshot.root)
	local function summarize(args, done)
		command(task, snapshot, args, function(raw, err)
			if not raw and type(err) == "string" and err:find("E145001", 1, true) then
				return require("lazyvcs.backends.svn_summary").load(task, snapshot, command, done, local_path)
			end
			done(raw, err)
		end)
	end
	summarize({
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
		local items, seen, missing, obstructed = {}, {}, {}, {}
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
				if previous and previous.status == item.status and previous.kind == item.kind then
					previous.properties = previous.properties or item.properties
				elseif previous then
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
			-- Relabel after pairing, so a missing kind change keeps one row.
			for _, item in ipairs(merged) do
				if missing[item.relpath] then
					-- An added row has no base side to read.
					item.base_absent = item.status == "A" or nil
					item.status = "!"
					item.obstructed = obstructed[item.relpath]
				end
			end
			local cursor, retained = 0, {}
			local file_budget = { paths = 128, bytes = 8 * common.max_file_bytes }
			local deadline = vim.uv.hrtime() / 1e6 + 30000
			file_budget.deadline = deadline
			local function bounded_command(owner, repo, args, cb, opts)
				local remaining = math.floor(deadline - vim.uv.hrtime() / 1e6)
				if remaining <= 0 then
					return cb(nil, "File reconciliation timed out")
				end
				command(owner, repo, args, cb, vim.tbl_extend("force", opts or {}, { timeout_ms = remaining }))
			end
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
					if item.status == "M" and item.kind == "file" and vim.uv.hrtime() / 1e6 < deadline then
						return require("lazyvcs.backends.svn_summary").file_equal(
							task,
							snapshot,
							item,
							bounded_command,
							function(equal)
								if not equal then
									retained[#retained + 1] = item
								end
								schedule(task, reconcile)
							end,
							file_budget
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
		command(
			task,
			snapshot,
			{ "status", "--xml", "--ignore-externals", snapshot.root .. "@" },
			function(status, status_err)
				if not status then
					return task:finish(nil, status_err)
				end
				local entries, externals = xml.parse_status(status), {}
				local util = require("lazyvcs.util")
				for _, entry in ipairs(entries) do
					local path = local_path(entry.path)
					local relpath = common.relative(path) and path or util.relative_literal_path(root, path)
					if not relpath or not common.relative(relpath) then
						return task:finish(nil, "SVN returned a status path outside the comparison")
					end
					if entry.file_external then
						externals[relpath] = true
					elseif entry.wc_item == "missing" or entry.wc_item == "obstructed" then
						missing[relpath] = true
						obstructed[relpath] = entry.wc_item == "obstructed" or nil
						if obstructed[relpath] then
							local stat = vim.uv.fs_lstat(snapshot.root .. "/" .. relpath)
							if stat and stat.type == "directory" then
								entry.wc_item = "unversioned"
							end
						end
					end
				end
				local retained, unseen = {}, {}
				for _, item in ipairs(items) do
					-- The pinned parent may delete a path now owned by an external.
					if not externals[item.relpath] or item.status == "D" then
						retained[#retained + 1] = item
					end
				end
				items = retained
				for relpath in pairs(missing) do
					if not seen[relpath] then
						unseen[relpath] = true
					end
				end
				local function untracked()
					if not include_untracked then
						return finish()
					end
					require("lazyvcs.backends.svn_untracked").expand(
						task,
						snapshot,
						entries,
						function(paths, expand_err)
							if not paths then
								return task:finish(nil, expand_err)
							end
							for _, relpath in ipairs(paths) do
								if not seen[relpath] then
									items[#items + 1] = { relpath = relpath, status = "?", untracked = true }
									seen[relpath] = true
								end
							end
							finish()
						end
					)
				end
				if next(unseen) == nil then
					return untracked()
				end
				missing_kinds(task, snapshot, unseen, function(kinds, kind_err)
					if not kinds then
						return task:finish(nil, kind_err)
					end
					for relpath in pairs(unseen) do
						local kind = kinds[relpath]
						if not kind then
							return task:finish(nil, "SVN returned no node kind for a missing path")
						end
						-- Directories take the property path, like other SVN directory rows.
						items[#items + 1] = {
							relpath = relpath,
							status = "!",
							kind = kind,
							property_only = kind == "dir",
							obstructed = obstructed[relpath],
						}
						seen[relpath] = true
					end
					untracked()
				end)
			end
		)
	end)
	return task
end

function M.preview(snapshot, item, callback, opts)
	local task = common.task(callback)
	local path = snapshot.root .. "/" .. item.relpath
	local url = require("lazyvcs.backends.svn_url").append_path(snapshot.url, item.relpath)
	local result = {
		presence = require("lazyvcs.diff_labels").snapshot(item),
		left_label = snapshot.url .. " @ r" .. snapshot.revision,
		right_label = "SAVED WORKTREE",
		loaded = { text = not (opts and opts.mode == "metadata"), metadata = true },
	}
	if item.status == "!" then
		result.right_label = item.obstructed and "OBSTRUCTED WORKTREE" or "MISSING FROM WORKTREE"
		result.details = {
			item.obstructed and "Versioned path is obstructed by a different node kind; no SVN change is scheduled."
				or "Versioned path is missing from disk; no SVN deletion is scheduled.",
		}
	end
	if item.property_check_error then
		result.details = { "Property validation failed: " .. tostring(item.property_check_error):gsub("%s+", " ") }
	end
	local function finish()
		if
			not (
				item.properties
				or item.property_only
				or item.load_properties
				or ((item.status == "A" or item.status == "D") and not item.untracked)
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
		if item.obstructed then
			local stat = vim.uv.fs_lstat(path)
			result.right =
				{ "Obstructing " .. (stat and stat.type or "missing path") .. ": " .. vim.fn.strtrans(item.relpath) }
			return finish()
		end
		if item.kind_after == "dir" then
			result.right = { "Directory: " .. vim.fn.strtrans(item.relpath) }
			return finish()
		end
		if item.status == "D" or item.status == "!" then
			common.decode_side(result, "right", "", { encoding = "utf-8" })
			return finish()
		end
		common.read_file(task, path, function(data, err, kind)
			if not data then
				return task:finish(nil, "Saved preview: " .. tostring(err))
			end
			local stat = kind == "link"
			if stat then
				data = "link " .. data
				right_options.hint = nil
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
	elseif result.presence.left == "absent" then
		result.left_kind = "missing"
		common.decode_side(result, "left", "", { encoding = "utf-8" })
		right()
	else
		local function read_base()
			command(
				task,
				snapshot,
				{ "cat", "-r", snapshot.revision, url .. "@" .. snapshot.revision },
				function(raw, err, output)
					if output and output.stdout_truncated then
						return task:finish(nil, "Base preview: File exceeds the 1 MiB preview limit")
					end
					if not raw then
						return task:finish(nil, err)
					end
					local decoded, line_err = common.decode_side(result, "left", raw, left_options)
					if not decoded then
						return task:finish(nil, line_err)
					end
					right()
				end,
				{ output_limit_bytes = 2 * common.max_file_bytes }
			)
		end
		if opts and opts.editable then
			command(
				task,
				snapshot,
				{ "proplist", "--xml", "-r", snapshot.revision, url .. "@" .. snapshot.revision },
				function(raw, err)
					if not raw then
						return task:finish(nil, err)
					end
					result.left_kind = raw:match('name="svn:special"') and "symlink" or "regular"
					read_base()
				end
			)
		else
			read_base()
		end
	end
	return task
end

return M
