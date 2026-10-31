-- Raw repository patches. All children belong to the caller's cancellable task.
local util = require("lazyvcs.util")
local process = require("lazyvcs.backends.process")
local xml = require("lazyvcs.backends.xml")
local M = {}

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
				local index = 0
				local function next_file()
					index = index + 1
					local file = files[index]
					if not file then
						return finish()
					end
					-- Run at the repository root with a relative operand. Git then writes
					-- root-relative headers itself, including C quoting when necessary.
					git({
						"diff",
						"--no-ext-diff",
						"--no-color",
						"--no-textconv",
						"--src-prefix=a/",
						"--dst-prefix=b/",
						"--no-index",
						"--",
						"/dev/null",
						file,
					}, function(text, truncated)
						if not append(text, truncated) then
							return finish()
						end
						next_file()
					end, nil, true)
				end
				next_file()
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
		local target = util.svn_target(relative)
		local function untracked(raw, selected_path)
			if not opts.include_untracked then
				return finish()
			end
			local paths, switched = {}, {}
			for _, entry in ipairs(xml.parse_status(raw)) do
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
			command({ "svn", "diff", "--internal-diff", "--", relative }, function(text, truncated)
				if not append(text, truncated) then
					return finish()
				end
				untracked(raw)
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
					if #paths > 0 and bytes + #ancestor + 1 > 32768 then
						break
					end
					paths[#paths + 1] = ancestor
					args[#args + 1] = util.svn_target(ancestor)
					bytes = bytes + #ancestor + 1
					ancestor = ancestor ~= "." and vim.fs.dirname(ancestor) or nil
				end
				command(args, function(status)
					local entries = {}
					for _, entry in ipairs(xml.parse_status(status)) do
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
			local exact = false
			for _, entry in ipairs(xml.parse_status(raw)) do
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
