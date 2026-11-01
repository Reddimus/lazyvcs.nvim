-- Raw repository patches. All children belong to the caller's cancellable task.
local util = require("lazyvcs.util")
local process = require("lazyvcs.backends.process")
local xml = require("lazyvcs.backends.xml")
local paths = require("lazyvcs.backends.patch_path")
local fs = require("lazyvcs.backends.patch_io")
local M = {}

-- Classify only Git's untracked additions. Tracked native diff output remains
-- authoritative even when Git explicitly tracks a file inside another repository.
local function git_untracked_files(task, root, files, guard, done)
	local cache, aliases, kept, index = {}, {}, {}, 0
	local next_file
	local function later(fn)
		vim.schedule(guard(fn))
	end
	local function administration_alias(candidate, done)
		local name = vim.fs.basename(candidate)
		local lower = name:lower()
		if name == lower or (lower ~= ".svn" and lower ~= ".git") then
			return done(false)
		end
		if aliases[candidate] ~= nil then
			return done(aliases[candidate])
		end
		local function resolved(path, callback)
			vim.uv.fs_realpath(path, function(err, physical)
				later(function()
					if not physical then
						return callback(nil, err)
					end
					fs.fs_lstat(util.normalize_literal_path(physical), function(stat_err, entry)
						later(function()
							callback(entry, stat_err)
						end)
					end)
				end)
			end)
		end
		local function finish(value)
			aliases[candidate] = value
			done(value)
		end
		-- Case alone does not identify administration on case-sensitive filesystems.
		-- Resolve only these marker names, then compare authoritative provider IDs.
		resolved(vim.fs.dirname(candidate) .. "/" .. lower, function(marker, err)
			if err and (marker or not tostring(err):match("^ENOENT:")) then
				return task:finish(nil, err)
			end
			if not marker then
				if tostring(err):match("^ENOENT:") then
					return finish(false)
				end
				return task:finish(nil, err or "Patch administration marker is unverifiable")
			end
			if marker.type ~= "directory" and not (lower == ".git" and marker.type == "file") then
				return finish(false)
			end
			if not paths.identity(marker) then
				return task:finish(nil, "Patch administration marker has no verifiable identity")
			end
			resolved(candidate, function(entry, entry_err)
				if entry_err or not paths.identity(entry) then
					return task:finish(nil, entry_err or "Patch administration alias has no verifiable identity")
				end
				finish(paths.same(marker, entry))
			end)
		end)
	end
	next_file = function()
		index = index + 1
		local file = files[index]
		if not file then
			return done(kept)
		end
		-- At the explicit Git root, keep ordinary files named .svn while
		-- excluding a linked administration directory listed as a leaf.
		if file == ".svn" then
			vim.uv.fs_stat(root .. "/.svn", function(err, entry)
				later(function()
					if err and not tostring(err):match("^ENOENT:") then
						return task:finish(nil, err)
					end
					if not entry or entry.type ~= "directory" then
						kept[#kept + 1] = file
					end
					later(next_file)
				end)
			end)
			return
		end
		local ancestors, current = {}, root
		local components = vim.split(file, "/", { plain = true })
		for i = 1, #components - 1 do
			local component = components[i]
			-- A leaf with this name can be an ordinary file. Administrative directory
			-- components, however, never belong to the outer untracked collection.
			if component == ".git" or component == ".svn" then
				return later(next_file)
			end
			current = current .. "/" .. component
			ancestors[#ancestors + 1] = current
		end
		local cursor = 0
		local visit
		visit = function()
			local directory
			repeat
				cursor = cursor + 1
				directory = ancestors[cursor]
				if not directory then
					return administration_alias(root .. "/" .. file, function(alias)
						if not alias then
							kept[#kept + 1] = file
						end
						later(next_file)
					end)
				end
				if cache[directory] then
					return later(next_file)
				end
			until cache[directory] == nil
			-- Match the shared SVN walker's marker kinds, following administrative
			-- marker links only. No recursive filesystem walk or per-file VCS spawn.
			administration_alias(directory, function(alias)
				if alias then
					cache[directory] = true
					return later(next_file)
				end
				vim.uv.fs_stat(directory .. "/.svn", function(svn_err, svn)
					later(function()
						if svn_err and not tostring(svn_err):match("^ENOENT:") then
							return task:finish(nil, svn_err)
						end
						vim.uv.fs_stat(directory .. "/.git", function(git_err, git)
							later(function()
								if git_err and not tostring(git_err):match("^ENOENT:") then
									return task:finish(nil, git_err)
								end
								local boundary = (svn and svn.type == "directory")
									or (git and (git.type == "file" or git.type == "directory"))
									or false
								cache[directory] = boundary
								if boundary then
									return later(next_file)
								end
								visit()
							end)
						end)
					end)
				end)
			end)
		end
		visit()
	end
	later(next_file)
end

function M.collect(repo, path, opts, callback)
	local task = require("lazyvcs.backends.comparison").task(callback)
	local ignorecase = vim.o.fileignorecase
	local function guard(fn)
		return function(...)
			if not task:is_active() then
				return
			end
			local ok, err = pcall(fn, ...)
			if not ok then
				task:finish(nil, tostring(err))
			end
		end
	end
	local function command(args, done, extra, difference, metadata)
		local limit = metadata and 16 * 1024 * 1024 or opts.remaining() + 4096
		task:add(process.start(
			args,
			vim.tbl_extend("force", {
				cwd = repo.root,
				text = false,
				-- The process layer divides its budget between stdout and stderr.
				output_limit_bytes = 2 * limit,
			}, extra or {}),
			guard(function(result, err, raw)
				local value = result or raw
				if
					difference
					and value
					and value.code == 1
					and not value.cancelled
					and not value.timed_out
					and (value.signal or 0) == 0
					-- Git also returns 1 for some no-index access failures. LC_MESSAGES=C
					-- makes native error diagnostics distinguishable from valid warnings.
					and not ("\n" .. (value.stderr or "")):find("\nerror:", 1, true)
					and not ("\n" .. (value.stderr or "")):find("\nfatal:", 1, true)
				then
					err = nil
				end
				if err or not value then
					return task:finish(nil, err or "Patch command failed")
				end
				if metadata and (value.stdout_truncated or value.stderr_truncated) then
					return task:finish(nil, "Patch file list was truncated; narrow the path")
				end
				done(value.stdout or "", value.stdout_truncated)
			end)
		))
	end
	local function append(text, truncated)
		return opts.append(text, truncated)
	end
	local function finish()
		task:finish(true)
	end
	local relative = util.relative_literal_path(repo.root, path)
	if not relative then
		task:finish(nil, "Patch path is outside the repository")
		return task
	end
	if repo.vcs == "git" then
		local prefix = {
			"git",
			"-c",
			"core.quotepath=false",
			"-c",
			"diff.suppressBlankEmpty=false",
			"-c",
			"diff.autoRefreshIndex=false",
		}
		local function git(args, done, extra, difference, metadata)
			command(vim.list_extend(vim.deepcopy(prefix), args), done, extra, difference, metadata)
		end
		local function untracked()
			if not opts.include_untracked then
				return finish()
			end
			-- The process wrapper passes each pathspec literally, including glob bytes.
			git({ "ls-files", "-z", "--others", "--exclude-standard", "--", relative }, function(raw)
				local files = {}
				for file in raw:gmatch("[^%z]+") do
					-- Git marks nested repository directories with a trailing slash.
					if file:sub(-1) ~= "/" then
						files[#files + 1] = file
						if #files > 10000 then
							return task:finish(nil, "More than 10000 untracked files; narrow the patch path")
						end
					end
				end
				table.sort(files)
				git_untracked_files(task, repo.root, files, guard, function(owned_files)
					files = owned_files
					local index = 0
					local function next_file()
						index = index + 1
						local file = files[index]
						if not file then
							return finish()
						end
						local absolute = util.normalize_literal_path(repo.root .. "/" .. file)
						paths.check(task, absolute, nil, guard, function(entry)
							-- Run at the repository root with a relative operand. Git then writes
							-- root-relative headers itself, including C quoting when necessary.
							local dash = file == "-"
							git({
								"diff",
								"--no-ext-diff",
								"--no-color",
								"--no-textconv",
								"--src-prefix=" .. (dash and "" or "a/"),
								"--dst-prefix=" .. (dash and "" or "b/"),
								"--no-index",
								"--",
								"/dev/null",
								-- A bare dash is stdin; empty prefixes keep ./- applicable.
								dash and "./-" or file,
							}, function(text, truncated)
								-- Validate before publication; the native child may have read
								-- a replacement, so this is not a filesystem read sandbox.
								paths.check(task, absolute, entry, guard, function()
									if not append(text, truncated) then
										return finish()
									end
									next_file()
								end)
							end, nil, true)
						end)
					end
					next_file()
				end)
			end, nil, false, true)
		end
		local function diff(base)
			git({
				"diff",
				"--no-ext-diff",
				"--no-color",
				"--no-textconv",
				"--src-prefix=a/",
				"--dst-prefix=b/",
				base,
				"--",
				relative,
			}, function(text, truncated)
				if not append(text, truncated) then
					return finish()
				end
				untracked()
			end)
		end
		-- Only a normal exit of 1 means HEAD is unborn; other failures are errors.
		task:add(process.start(
			{ "git", "rev-parse", "--verify", "--quiet", "HEAD" },
			{
				cwd = repo.root,
				text = false,
				output_limit_bytes = 8192,
			},
			guard(function(result, err, raw)
				if result then
					return diff("HEAD")
				end
				if raw and raw.code == 1 and not raw.cancelled and not raw.timed_out and (raw.signal or 0) == 0 then
					return git({ "hash-object", "-t", "tree", "--stdin" }, function(oid)
						diff((oid:gsub("\r?\n$", "")))
					end, { stdin = "" })
				end
				task:finish(nil, err)
			end)
		))
	else
		local filenames = vim.fn.has("win32") == 1 and require("lazyvcs.backends.patch_svn_filenames") or nil
		if filenames and not filenames.path(repo, relative) then
			task:finish(nil, filenames.error)
			return task
		end
		local function status_entries(raw)
			local entries = xml.parse_status(raw)
			if filenames then
				for _, entry in ipairs(entries) do
					local item, props = entry.wc_item, entry.wc_props
					local unused = item == "ignored"
						or item == "external"
						or (item == "unversioned" and not opts.include_untracked)
						or ((item == "normal" or item == "none") and (props == "normal" or props == "none"))
					if not unused and not filenames.path(repo, entry.path) then
						task:finish(nil, filenames.error)
						return nil
					end
				end
			end
			return entries
		end
		-- Keep local paths local even when their spelling starts with ^/.
		local operand = relative == "." and relative or ("./" .. relative)
		local target = util.svn_target(operand)
		local function untracked(raw, selected_path)
			if not opts.include_untracked then
				return finish()
			end
			local entries = status_entries(raw)
			if not entries then
				return
			end
			local paths, switched = {}, {}
			for _, entry in ipairs(entries) do
				if entry.switched or entry.wc_item == "external" then
					switched[#switched + 1] = entry
				end
				if entry.wc_item == "unversioned" then
					paths[#paths + 1] = util.normalize_literal_path(repo.root .. "/" .. entry.path)
				end
			end
			if #paths == 0 then
				return finish()
			end
			local svn = require("lazyvcs.backends.patch_svn")
			svn.files(task, repo, paths, guard, function(files, identities)
				if filenames then
					for _, file in ipairs(files) do
						if not filenames.path(repo, file) then
							return task:finish(nil, filenames.error)
						end
					end
				end
				local index = 0
				local next_file
				next_file = guard(function()
					index = index + 1
					local file = files[index]
					if not file then
						return finish()
					end
					svn.read(task, file, opts.remaining() + 8192, guard, function(text, truncated)
						local rel = util.relative_literal_path(repo.root, file)
						if not append(svn.section(rel, text), truncated) then
							return finish()
						end
						next_file()
					end, identities[file])
				end)
				next_file()
			end, { switched = switched, ignorecase = ignorecase, selected_path = selected_path })
		end
		local function diff(raw)
			-- Keep this no-revision working-copy path literal. Adding status's empty
			-- peg suffix changes the filename in this diff form.
			command({ "svn", "diff", "--internal-diff", "--", operand }, function(text, truncated)
				local function publish()
					if not append(text, truncated) then
						return finish()
					end
					untracked(raw)
				end
				if filenames then
					return filenames.headers(repo, task, text, guard, publish, truncated)
				end
				publish()
			end)
		end
		local function classify_selected(raw)
			---@type string?
			local ancestor = relative
			local next_batch
			next_batch = function()
				local args = {
					"svn",
					"status",
					"--xml",
					"--ignore-externals",
					"--no-ignore",
					"--verbose",
					"--depth",
					"empty",
					"--",
				}
				local paths, bytes = {}, 0
				while ancestor and #paths < 64 do
					local candidate = util.svn_target(ancestor == "." and ancestor or ("./" .. ancestor))
					if #paths > 0 and bytes + #candidate > 32768 then
						break
					end
					paths[#paths + 1] = ancestor
					args[#args + 1] = candidate
					bytes = bytes + #candidate
					ancestor = ancestor ~= "." and vim.fs.dirname(ancestor) or nil
				end
				command(args, function(status)
					local returned = status_entries(status)
					if not returned then
						return
					end
					local entries = {}
					for _, entry in ipairs(returned) do
						entries[util.normalize_literal_path(repo.root .. "/" .. entry.path)] = entry
					end
					-- A child of an unversioned directory has no native status row.
					-- Only an exact native ancestor row can authorize the scoped walk.
					for _, candidate in ipairs(paths) do
						local entry = entries[util.normalize_literal_path(repo.root .. "/" .. candidate)]
						if entry then
							if entry.wc_item == "unversioned" then
								return untracked(status, path)
							elseif entry.wc_item == "ignored" then
								return finish()
							end
							return diff(raw)
						end
					end
					if ancestor then
						return next_batch()
					end
					task:finish(nil, "Cannot classify selected SVN path; retry or select its parent")
				end, nil, false, true)
			end
			next_batch()
		end
		-- SVN rejects an unversioned operand to diff. Inspect status first so
		-- selected loose files and directories can use the addition collector.
		command({ "svn", "status", "--xml", "--ignore-externals", "--", target }, function(raw)
			local entries = status_entries(raw)
			if not entries then
				return
			end
			local exact = false
			for _, entry in ipairs(entries) do
				local entry_path = util.normalize_literal_path(repo.root .. "/" .. entry.path)
				if entry_path == path then
					exact = true
					if entry.wc_item == "unversioned" then
						return untracked(raw)
					end
				end
			end
			if not exact and relative ~= "." then
				return classify_selected(raw)
			end
			diff(raw)
		end, nil, false, true)
	end
	return task
end

return M
