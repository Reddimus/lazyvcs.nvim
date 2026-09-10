local util = require("lazyvcs.util")
local process = require("lazyvcs.backends.process")
local Task = require("lazyvcs.backends.task")
local svn_xml = require("lazyvcs.backends.xml")

local M = {
	name = "svn",
}

local ASYNC_TIMEOUT_MS = 30000

local literal_target = util.svn_target

-- Cache the `svn` executable lookup so a machine without Subversion (the common
-- case — lazyvcs is Git-first) does not spawn a process that throws ENOENT on
-- every session open. backends/init.lua probes every backend for each path, so
-- an unguarded svn call here breaks Git workflows too.
--
-- Keyed on PATH, not cached once for the session -- see the matching note in
-- backends/git.lua. Subversion is the more likely of the two to arrive from a
-- Homebrew prefix that a GUI-launched Neovim cannot see, since macOS has not
-- shipped `svn` since Xcode 10.
local svn_cached_path, svn_present = nil, false
local function svn_available()
	local path = vim.env.PATH or ""
	if svn_cached_path ~= path then
		svn_cached_path = path
		svn_present = vim.fn.executable("svn") == 1
	end
	return svn_present
end

local function get_root(path)
	if not svn_available() then
		return nil, "svn executable not found"
	end
	local cwd = util.dir_of(path)
	local result, err = util.system({ "svn", "info", "--show-item", "wc-root", literal_target(cwd) }, { cwd = cwd })
	if not result then
		return nil, err
	end
	-- Canonicalize: the sidebar canonicalizes its roots, and identity is
	-- compared with `==`. Git already resolves symlinks here, but a Windows
	-- 8.3 short path or a case difference would still not match, and the
	-- non-existent-path fallback keeps this total.
	return util.canonical_path(util.trim(result.stdout))
end

local function is_versioned(path)
	if not svn_available() then
		return false
	end
	local _, err = util.system({ "svn", "info", literal_target(path) }, { cwd = util.dir_of(path) })
	return err == nil
end

local function status_code(path)
	local lines, err = util.system_lines(
		{ "svn", "status", "--depth", "empty", literal_target(path) },
		{ cwd = util.dir_of(path) }
	)
	if not lines then
		return nil, err
	end
	for _, line in ipairs(lines) do
		if line ~= "" then
			return line:sub(1, 1)
		end
	end
	return " "
end

local function is_added_base_error(err)
	return type(err) == "string" and (err:match("no committed revision") or err:match("no pristine version"))
end

local function is_unversioned_error(err, raw)
	if raw and raw.code ~= 1 then
		return false
	end
	err = tostring(err or "")
	return err:match("not under version control") ~= nil
		or err:match("was not found") ~= nil
		or err:match("E200009") ~= nil
		or err:match("W155010") ~= nil
end

local function uncommitted_blame_lines(path, contents)
	local ok, lines = true, contents and util.split_lines(contents)
	if not lines then
		ok, lines = pcall(vim.fn.readfile, path)
	end
	if not ok then
		return nil, tostring(lines)
	end
	local out = {}
	for _, line in ipairs(lines) do
		out[#out + 1] = "     - - - " .. line
	end
	return out
end

local function map_blame(lines, base, current)
	local out, b, c = {}, 1, 1
	for _, hunk in ipairs(require("lazyvcs.diff").compute_hunks(base, current)) do
		local first = hunk.current_count == 0 and hunk.current_start + 1 or hunk.current_start
		while c < first do
			out[c], b, c = lines[b], b + 1, c + 1
		end
		for _ = 1, hunk.current_count do
			out[c], c = "     - - -", c + 1
		end
		b = hunk.base_start + hunk.base_count + (hunk.base_count == 0 and 1 or 0)
	end
	while c <= #current do
		out[c], b, c = lines[b] or "     - - -", b + 1, c + 1
	end
	return out
end

local function load_base_lines(path, root)
	local code, status_err = status_code(path)
	if not code then
		return nil, nil, status_err
	end
	if code == "A" then
		return {}, "EMPTY"
	end

	local lines, load_err = util.system_lines({ "svn", "cat", "-r", "BASE", literal_target(path) }, { cwd = root })
	if not lines then
		if is_added_base_error(load_err) then
			return {}, "EMPTY"
		end
		return nil, nil, load_err
	end
	return lines, "BASE"
end

local function status_label(code)
	return ({
		M = "modified",
		A = "added",
		D = "deleted",
		R = "replaced",
		C = "conflicted",
		["?"] = "untracked",
		["!"] = "missing",
	})[code] or "changed"
end

function M.probe(path)
	local root = get_root(path)
	if not root then
		return nil
	end
	return { root = root }
end

function M.probe_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	if not svn_available() then
		vim.schedule(function()
			task:finish(nil, "svn executable not found")
		end)
		return task
	end
	local cwd = util.dir_of(path)
	task:add(process.root({ "svn", "info", "--show-item", "wc-root", literal_target(cwd) }, {
		cwd = cwd,
		root = opts.root,
		timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
	}, function(result, err)
		if not result then
			return task:finish(nil, err)
		end
		local root = util.canonical_path(util.trim(result.stdout))
		if root == "" then
			return task:finish(nil, "Subversion returned an empty working-copy root")
		end
		task:finish({ root = root })
	end))
	return task
end

function M.load(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not an SVN working copy"
	end

	local tracked = is_versioned(path)
	if not tracked then
		return nil, "File is not tracked by SVN"
	end
	---@type string[]
	local base_lines = {}
	local base_label = "EMPTY"

	local loaded_lines, loaded_label, load_err = load_base_lines(path, root)
	if not loaded_lines then
		return nil, load_err or err
	end
	base_lines = loaded_lines
	base_label = loaded_label or "EMPTY"

	return {
		name = M.name,
		root = root,
		relpath = util.relpath(root, path),
		tracked = tracked,
		base_label = base_label,
		base_lines = base_lines,
		impl = M,
	}
end

function M.revert_hunk()
	return false
end

function M.root(path)
	return get_root(path)
end

function M.is_versioned(path)
	return is_versioned(path)
end

function M.is_versioned_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.probe_async(path, function(info, err)
		if not task:is_active() then
			return
		end
		if not info then
			return task:finish(false, err)
		end
		task:add(process.start({ "svn", "info", literal_target(path) }, {
			cwd = info.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(result, tracked_err, raw)
			if result then
				return task:finish(true)
			end
			if is_unversioned_error(tracked_err, raw) then
				return task:finish(false)
			end
			task:finish(false, tracked_err)
		end))
	end, opts))
	return task
end

function M.load_base(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not an SVN working copy"
	end

	if not is_versioned(path) then
		return nil, "File is not tracked by SVN"
	end

	local lines, base_label, load_err = load_base_lines(path, root)
	if not lines then
		return nil, load_err
	end
	return {
		root = root,
		relpath = util.relpath(root, path),
		base_label = base_label,
		base_lines = lines,
	}
end

local function load_payload_async(path, on_done, opts, base_only)
	opts = opts or {}
	local task = Task.new(on_done)
	if not svn_available() then
		vim.schedule(function()
			task:finish(nil, "svn executable not found")
		end)
		return task
	end

	local cwd = util.dir_of(path)
	local function payload(root, tracked, base_label, base_lines)
		local value = {
			root = root,
			relpath = util.relpath(root, path),
			tracked = tracked,
			base_label = base_label,
			base_lines = base_lines,
		}
		if not base_only then
			value.name = M.name
			value.impl = M
		end
		return value
	end

	task:add(process.root({ "svn", "info", "--show-item", "wc-root", literal_target(cwd) }, {
		cwd = cwd,
		root = opts.root,
		timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
	}, function(result, err)
		if not task:is_active() then
			return
		end
		if err then
			return task:finish(nil, err)
		end
		local root = util.canonical_path(util.trim(result.stdout))
		task:add(process.start({ "svn", "info", literal_target(path) }, {
			cwd = cwd,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(_, tracked_err, tracked_raw)
			if not task:is_active() then
				return
			end
			if tracked_err then
				if is_unversioned_error(tracked_err, tracked_raw) then
					return task:finish(nil, "File is not tracked by SVN")
				end
				return task:finish(nil, tracked_err)
			end
			task:add(
				process.lines(
					{ "svn", "status", "--depth", "empty", literal_target(path) },
					{ cwd = cwd, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
					function(status_lines, status_err)
						if not task:is_active() then
							return
						end
						if not status_lines then
							return task:finish(nil, status_err)
						end

						local code = " "
						for _, line in ipairs(status_lines) do
							if line ~= "" then
								code = line:sub(1, 1)
								break
							end
						end

						if code == "A" then
							return task:finish(payload(root, true, "EMPTY", {}))
						end

						task:add(
							process.lines(
								{ "svn", "cat", "-r", "BASE", literal_target(path) },
								{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
								function(lines, cat_err)
									if not lines then
										if is_added_base_error(cat_err) then
											return task:finish(payload(root, true, "EMPTY", {}))
										end
										return task:finish(nil, cat_err)
									end
									task:finish(payload(root, true, "BASE", lines))
								end
							)
						)
					end
				)
			)
		end))
	end))
	return task
end

function M.load_async(path, on_done, opts)
	return load_payload_async(path, on_done, opts, false)
end

function M.load_base_async(path, on_done, opts)
	return load_payload_async(path, on_done, opts, true)
end

function M.revert_file(path)
	if not svn_available() then
		return nil, "svn executable not found"
	end
	return util.system({ "svn", "revert", literal_target(path) }, { cwd = util.dir_of(path) })
end

function M.revert_file_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.probe_async(path, function(info, err)
		if not task:is_active() then
			return
		end
		if not info then
			return task:finish(nil, err or "Not an SVN working copy")
		end
		task:add(process.start({ "svn", "info", literal_target(path) }, {
			cwd = info.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(_, tracked_err, raw)
			if not task:is_active() then
				return
			end
			if tracked_err then
				if is_unversioned_error(tracked_err, raw) then
					return task:finish(nil, "File is untracked; nothing to revert")
				end
				return task:finish(nil, tracked_err)
			end
			local start = opts.start or util.system_start
			task:add(start({ "svn", "revert", literal_target(path) }, {
				cwd = info.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
			}, function(result, revert_err)
				if not result then
					return task:finish(nil, revert_err)
				end
				task:finish(result)
			end))
		end))
	end, opts))
	return task
end

function M.parse_status_lines(lines, root)
	local items = {}
	for _, line in ipairs(lines or {}) do
		local code = line:sub(1, 1)
		if code ~= "" and code ~= " " then
			local path = util.trim(line:sub(9))
			if path ~= "" then
				items[#items + 1] = {
					status = code,
					label = status_label(code),
					path = path,
					absolute_path = root and vim.fs.normalize(root .. "/" .. path) or path,
				}
			end
		end
	end
	return items
end

function M.changed_files(root)
	if not svn_available() then
		return nil, "svn executable not found"
	end

	local lines, err = util.system_lines({ "svn", "status" }, { cwd = root })
	if not lines then
		return nil, err
	end
	return M.parse_status_lines(lines, root)
end

function M.changed_files_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.probe_async(path, function(info, err)
		if not task:is_active() then
			return
		end
		if not info then
			return task:finish(nil, err or "Not an SVN working copy")
		end
		task:add(process.lines({ "svn", "status" }, {
			cwd = info.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(lines, status_err)
			if not lines then
				return task:finish(nil, status_err)
			end
			task:finish(M.parse_status_lines(lines, info.root))
		end))
	end, opts))
	return task
end

local function empty_side(label)
	return {
		label = label or "EMPTY",
		source = { kind = "empty" },
		lines = {},
		modifiable = false,
	}
end

local function svn_side(label, revision, path, remote, allow_missing)
	return {
		label = label,
		source = {
			kind = "svn_object",
			revision = revision,
			path = path,
			remote = remote or false,
			allow_missing = allow_missing or false,
		},
		modifiable = false,
	}
end

local function worktree_side(path)
	return {
		label = "WORKTREE",
		source = { kind = "worktree", path = path },
		path = path,
		modifiable = true,
	}
end

function M.resolve_diff_target(target)
	target = target or {}
	local root = target.root or target.repo_root
	local relpath = target.relpath
	local path = target.path or (root and relpath and vim.fs.normalize(root .. "/" .. relpath))
	if not root or not relpath then
		return nil, "SVN diff target requires root and relpath"
	end

	local section = target.section == "incoming" and "remote" or target.section
	local change_kind = target.change_kind
	local local_item = target.wc_item or target.status
	local remote_item = target.repos_item or target.remote_status
	local property_only = target.property_only == true
	local comparison = {
		backend = M.name,
		vcs = M.name,
		root = root,
		relpath = relpath,
		path = path,
		section = section,
		change_kind = change_kind,
		status = target.status,
		wc_item = local_item,
		repos_item = remote_item,
		base_revision = target.base_revision,
		property_only = property_only,
	}

	if section == "untracked" or change_kind == "untracked" or local_item == "unversioned" then
		comparison.kind = "svn_untracked"
		comparison.left = empty_side()
		comparison.right = worktree_side(path)
		comparison.editable_side = "right"
	elseif section == "remote" then
		comparison.kind = "svn_remote"
		if remote_item == "added" then
			comparison.left = empty_side()
		else
			comparison.left = svn_side("BASE", "BASE", path, false, false)
		end
		if remote_item == "deleted" then
			comparison.right = empty_side()
		else
			comparison.right = svn_side("HEAD", "HEAD", path, true, false)
		end
	elseif section == "changes" or section == "local" then
		comparison.kind = "svn_local"
		if change_kind == "added" or local_item == "added" then
			comparison.left = empty_side()
		else
			comparison.left = svn_side("BASE", "BASE", path, false, false)
		end
		if change_kind == "deleted" or local_item == "deleted" or local_item == "missing" then
			comparison.right = empty_side()
		else
			comparison.right = worktree_side(path)
			comparison.editable_side = "right"
		end
	else
		return nil, "Unsupported SVN diff section: " .. tostring(section)
	end

	if property_only then
		comparison.property_patch = {
			label = section == "remote" and "REMOTE PROPERTIES" or "LOCAL PROPERTIES",
			source = {
				kind = "svn_property_patch",
				path = path,
				remote = section == "remote",
				base_revision = target.base_revision,
			},
			modifiable = false,
		}
	end
	comparison.title = string.format("%s ↔ %s", comparison.left.label, comparison.right.label)
	return comparison
end

function M.load_diff_target_async(target, on_done, opts)
	opts = opts or {}
	local comparison, resolve_err
	if target and target.left and target.right then
		comparison = vim.deepcopy(target)
	else
		comparison, resolve_err = M.resolve_diff_target(target)
	end
	local task = Task.new(on_done)
	if not comparison then
		vim.schedule(function()
			task:finish(nil, resolve_err)
		end)
		return task
	end

	local sides = {}
	for _, key in ipairs({ "left", "right", "property_patch" }) do
		if comparison[key] then
			sides[#sides + 1] = comparison[key]
		end
	end

	local needs_remote_url = false
	for _, side in ipairs(sides) do
		local source = side.source or {}
		if source.remote then
			needs_remote_url = true
			break
		end
	end

	local function load_sides(root_url)
		local pending = 0
		local failed = false
		local function complete()
			if not failed and pending == 0 then
				task:finish(comparison)
			end
		end
		for _, side in ipairs(sides) do
			local source = side.source or {}
			if source.kind == "empty" then
				side.lines = {}
			elseif source.kind == "svn_object" or source.kind == "svn_property_patch" then
				pending = pending + 1
				local command_path = source.path
				if source.remote then
					local suffix = comparison.relpath:gsub("\\", "/")
					command_path = (root_url or ""):gsub("/$", "") .. "/" .. suffix
				end
				local args
				if source.kind == "svn_property_patch" then
					args = { "svn", "diff", "--properties-only" }
					if source.remote then
						local base_revision = source.base_revision or comparison.base_revision
						if not base_revision or base_revision == "" then
							pending = pending - 1
							failed = true
							task:finish(nil, "SVN remote property diff requires a working-copy base revision")
							break
						end
						vim.list_extend(args, { "-r", tostring(base_revision) .. ":HEAD" })
					end
					vim.list_extend(args, { "--", literal_target(command_path) })
				else
					args = { "svn", "cat", "-r", source.revision, literal_target(command_path) }
				end
				task:add(process.lines(args, {
					cwd = comparison.root,
					timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
				}, function(lines, err)
					pending = pending - 1
					if failed then
						return
					end
					if not lines then
						if
							source.allow_missing
							and type(err) == "string"
							and (err:match("E160013") or err:match("W160013") or is_added_base_error(err))
						then
							side.lines = {}
							return complete()
						end
						failed = true
						return task:finish(nil, err)
					end
					side.lines = lines
					complete()
				end))
			end
		end
		complete()
	end

	if not needs_remote_url then
		load_sides(nil)
		return task
	end
	task:add(process.start({ "svn", "info", "--xml", literal_target(comparison.root) }, {
		cwd = comparison.root,
		timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
	}, function(result, err)
		if not task:is_active() then
			return
		end
		if not result then
			return task:finish(nil, err)
		end
		local info = svn_xml.parse_info(result.stdout)
		if not info or not info.url then
			return task:finish(nil, "Unable to parse SVN working-copy URL")
		end
		comparison.base_revision = comparison.base_revision or info.revision
		load_sides(info.url)
	end))
	return task
end

function M.blame_lines(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not an SVN working copy"
	end
	if status_code(path) == "A" then
		return uncommitted_blame_lines(path)
	end
	local lines, blame_err = util.system_lines({ "svn", "blame", "-v", literal_target(path) }, { cwd = root })
	if not lines and is_added_base_error(blame_err) then
		return uncommitted_blame_lines(path)
	end
	return lines, blame_err
end

function M.blame_lines_async(path, on_done, opts)
	opts = opts or {}
	if not svn_available() then
		local task = Task.new(on_done)
		vim.schedule(function()
			task:finish(nil, "svn executable not found")
		end)
		return task
	end

	local cwd = util.dir_of(path)
	local task = Task.new(on_done)
	task:add(
		process.root(
			{ "svn", "info", "--show-item", "wc-root", literal_target(cwd) },
			{ cwd = cwd, root = opts.root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
			function(result, err)
				if not task:is_active() then
					return
				end
				if err then
					return task:finish(nil, err)
				end
				local root = util.canonical_path(util.trim(result.stdout))
				task:add(
					process.lines(
						{ "svn", "status", "--no-ignore", "--depth", "empty", path .. "@" },
						{ cwd = cwd, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
						function(status_lines, status_err)
							if not task:is_active() then
								return
							end
							if not status_lines then
								return task:finish(nil, status_err)
							end

							for _, line in ipairs(status_lines) do
								local code = line:sub(1, 1)
								if code == "I" or code == "?" or code == "!" or code == "D" then
									return task:finish(nil, nil, root)
								end
								if line ~= "" and line:sub(1, 1) == "A" then
									local blame, read_err = uncommitted_blame_lines(path, opts.contents)
									return task:finish(blame, read_err, root)
								end
							end

							task:add(
								process.lines(
									{ "svn", "blame", "-v", literal_target(path) },
									{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
									function(lines, blame_err)
										if not lines then
											if is_added_base_error(blame_err) then
												local blame, read_err = uncommitted_blame_lines(path)
												return task:finish(blame, read_err, root)
											end
											return task:finish(nil, blame_err)
										end
										task:add(process.lines({ "svn", "cat", "-r", "BASE", literal_target(path) }, {
											cwd = root,
											timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
										}, function(base, base_err)
											if not base then
												return task:finish(nil, base_err)
											end
											local ok, current = true, opts.contents and util.split_lines(opts.contents)
											if not current then
												ok, current = pcall(vim.fn.readfile, path)
											end
											if not ok then
												return task:finish(nil, tostring(current))
											end
											task:finish(map_blame(lines, base, current), nil, root)
										end))
									end
								)
							)
						end
					)
				)
			end
		)
	)
	return task
end

function M.parse_blame_entries(lines)
	local out = {}
	for _, line in ipairs(lines or {}) do
		local revision, author, date = line:match("^%s*(%S+)%s+(%S+)%s+(%S+)")
		local uncommitted = revision == "-" and author == "-" and date == "-"
		out[#out + 1] = {
			revision = revision or "-",
			full_revision = revision or "-",
			author = author or "-",
			date = date or "-",
			backend = M.name,
			uncommitted = uncommitted or nil,
		}
	end
	return out
end

function M.parse_blame_metadata(lines, uncommitted_text)
	local out = {}
	for _, entry in ipairs(M.parse_blame_entries(lines)) do
		if entry.uncommitted then
			out[#out + 1] = uncommitted_text or "Uncommitted line"
		else
			out[#out + 1] = string.format("%6s %15s %s", entry.revision, entry.author, entry.date)
		end
	end
	return out
end

function M.line_revision(path, line_number)
	local lines, err = M.blame_lines(path)
	if not lines then
		return nil, err
	end
	local line = lines[line_number]
	if not line then
		return nil, "No blame information for this line"
	end
	local entry = M.parse_blame_entries({ line })[1]
	if not entry or entry.uncommitted then
		return nil, "No committed SVN revision for this line"
	end
	return entry.revision
end

function M.line_revision_async(path, line_number, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.blame_lines_async(path, function(lines, err)
		if not lines then
			return task:finish(nil, err)
		end
		local entry = M.parse_blame_entries({ lines[line_number] })[1]
		if not entry then
			return task:finish(nil, "No blame information for this line")
		end
		if entry.uncommitted then
			return task:finish(nil, "No committed SVN revision for this line")
		end
		task:finish(entry.revision)
	end, opts))
	return task
end

function M.revision_log(path, revision)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not an SVN working copy"
	end
	local lines, log_err = util.system_lines(
		{ "svn", "log", "-r", tostring(revision), literal_target(path) },
		{ cwd = root }
	)
	if not lines then
		return nil, log_err
	end
	return lines
end

function M.revision_log_async(path, revision, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.probe_async(path, function(info, err)
		if not task:is_active() then
			return
		end
		if not info then
			return task:finish(nil, err or "Not an SVN working copy")
		end
		task:add(process.lines({ "svn", "log", "-r", tostring(revision), literal_target(path) }, {
			cwd = info.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(lines, log_err)
			if not lines then
				return task:finish(nil, log_err)
			end
			task:finish(lines)
		end))
	end, opts))
	return task
end

return M
