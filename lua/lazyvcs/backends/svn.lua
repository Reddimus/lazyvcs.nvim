local util = require("lazyvcs.util")
local process = require("lazyvcs.backends.process")
local entry = require("lazyvcs.backends.entry")
local Task = require("lazyvcs.backends.task")
local svn_xml = require("lazyvcs.backends.xml")

local M = {
	name = "svn",
}

local ASYNC_TIMEOUT_MS = 30000

local literal_target = util.svn_target

-- Cache executable availability by PATH. Missing SVN must not break Git; recheck when a
-- GUI session adds Homebrew to PATH.
local svn_cached_path, svn_present = nil, false
local function svn_available()
	local path = vim.env.PATH or ""
	if svn_cached_path ~= path then
		svn_cached_path = path
		svn_present = vim.fn.executable("svn") == 1
	end
	return svn_present
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

local function get_root(path)
	if not svn_available() then
		return nil, "svn executable not found"
	end
	local cwd, cwd_err = util.existing_directory(path)
	if not cwd then
		return nil, cwd_err
	end
	while cwd do
		local result, err, raw = util.system(
			{ "svn", "info", "--show-item", "wc-root", literal_target(cwd) },
			{ cwd = cwd, text = false }
		)
		if result then
			return process.root_output(result.stdout)
		end
		local parent = vim.fs.dirname(cwd)
		if not is_unversioned_error(err, raw) or parent == cwd then
			return nil, err
		end
		cwd = parent
	end
end

local function discover_root_async(path, opts, callback)
	local task = Task.new(callback)
	local deadline = vim.uv.now() + (opts.timeout_ms or ASYNC_TIMEOUT_MS)
	local function probe(dir, dir_err)
		if not task:is_active() then
			return
		end
		if not dir then
			return task:finish(nil, dir_err)
		end
		local remaining = deadline - vim.uv.now()
		if remaining <= 0 then
			return task:finish(nil, "SVN root discovery timed out")
		end
		task:add(process.root({ "svn", "info", "--show-item", "wc-root", literal_target(dir) }, {
			cwd = dir,
			root = opts.root,
			timeout = remaining,
		}, function(root, err, raw)
			if root then
				return task:finish(root)
			end
			local parent = vim.fs.dirname(dir)
			if parent and parent ~= dir and is_unversioned_error(err, raw) then
				return probe(parent)
			end
			task:finish(nil, err)
		end))
	end
	if opts.root then
		vim.schedule(util.safe_callback(function()
			probe(opts.root)
		end))
	else
		task:add(util.existing_directory_async(path, probe))
	end
	return task
end

local function is_versioned(path, root)
	if not svn_available() then
		return false
	end
	root = root or util.existing_directory(path)
	if not root then
		return false
	end
	local _, err = util.system({ "svn", "info", literal_target(path) }, { cwd = root })
	return err == nil
end

local function status_code(path, root)
	local cwd, cwd_err = root, nil
	if not cwd then
		cwd, cwd_err = util.existing_directory(path)
	end
	if not cwd then
		return nil, cwd_err
	end
	local lines, err = util.system_lines({ "svn", "status", "--depth", "empty", literal_target(path) }, { cwd = cwd })
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

local function no_pristine(info)
	return info and info.schedule == "replace" and not info.copy_from_url
end

local function is_added_base_error(err)
	return type(err) == "string" and (err:match("no committed revision") or err:match("no pristine version"))
end

local function uncommitted_blame_lines(path, contents, text)
	local ok, lines = true, text and text.lines or contents and util.split_lines(contents)
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

local function load_base_bytes(path, root)
	local valid, eligibility_err = entry.editable(entry.classify(path))
	if not valid then
		return nil, nil, eligibility_err
	end
	local code, status_err = status_code(path, root)
	if not code then
		return nil, nil, status_err
	end
	if code == "A" then
		return "", "EMPTY"
	end

	if code == "R" then
		local info, info_err = util.system({ "svn", "info", "--xml", literal_target(path) }, { cwd = root })
		if not info then
			return nil, nil, info_err
		end
		if no_pristine(svn_xml.parse_info(info.stdout)) then
			return "", "EMPTY"
		end
	end

	local props, props_err = util.system(
		{ "svn", "proplist", "--xml", "-r", "BASE", literal_target(path) },
		{ cwd = root }
	)
	if not props then
		if is_added_base_error(props_err) then
			return "", "EMPTY"
		end
		return nil, nil, props_err
	end
	if props.stdout:match('name="svn:special"') then
		return nil, nil, "Editable hunks do not support SVN special entries"
	end
	local loaded, load_err = util.system(
		{ "svn", "cat", "-r", "BASE", literal_target(path) },
		{ cwd = root, text = false }
	)
	if not loaded then
		if is_added_base_error(load_err) then
			return "", "EMPTY"
		end
		return nil, nil, load_err
	end
	return loaded.stdout, "BASE"
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
	task:add(discover_root_async(path, opts, function(result, err)
		if not result then
			return task:finish(nil, err)
		end
		local root = result
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

	local relpath, path_err = util.relpath(root, path)
	if not relpath then
		return nil, path_err
	end

	local tracked = is_versioned(path, root)
	if not tracked then
		return nil, "File is not tracked by SVN"
	end
	local base_bytes = ""
	local base_label = "EMPTY"

	local loaded_lines, loaded_label, load_err = load_base_bytes(path, root)
	if not loaded_lines then
		return nil, load_err or err
	end
	base_bytes = loaded_lines
	base_label = loaded_label or "EMPTY"

	return {
		name = M.name,
		root = root,
		relpath = relpath,
		tracked = tracked,
		base_label = base_label,
		base_bytes = base_bytes,
		base_identity = { root = root, relpath = relpath, content = vim.fn.sha256(vim.base64.encode(base_bytes)) },
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
		local relpath, path_err = util.relpath(info.root, path)
		if not relpath then
			return task:finish(false, path_err)
		end
		task:add(process.start({ "svn", "info", "--", literal_target(relpath) }, {
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

	local relpath, path_err = util.relpath(root, path)
	if not relpath then
		return nil, path_err
	end

	if not is_versioned(path, root) then
		return nil, "File is not tracked by SVN"
	end

	local lines, base_label, load_err = load_base_bytes(path, root)
	if not lines then
		return nil, load_err
	end
	return {
		root = root,
		relpath = relpath,
		base_label = base_label,
		base_bytes = lines,
		base_identity = { root = root, relpath = relpath, content = vim.fn.sha256(vim.base64.encode(lines)) },
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

	local function payload(root, relpath, tracked, base_label, base_bytes)
		local value = {
			root = root,
			relpath = relpath,
			tracked = tracked,
			base_label = base_label,
			base_bytes = base_bytes,
			base_identity = { root = root, relpath = relpath, content = vim.fn.sha256(vim.base64.encode(base_bytes)) },
		}
		if not base_only then
			value.name = M.name
			value.impl = M
		end
		return value
	end

	task:add(discover_root_async(path, opts, function(result, err)
		if not task:is_active() then
			return
		end
		if err then
			return task:finish(nil, err)
		end
		local root = result
		local relpath, path_err = util.relpath(root, path)
		if not relpath then
			return task:finish(nil, path_err)
		end
		task:add(entry.classify_async(path, function(kind, kind_err)
			local valid, eligibility_err, rejection = entry.editable(kind, kind_err)
			if not valid then
				return task:finish(nil, eligibility_err, rejection)
			end
			task:add(process.start({ "svn", "info", "--xml", literal_target(path) }, {
				cwd = root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
			}, function(info, tracked_err, tracked_raw)
				if not task:is_active() then
					return
				end
				if tracked_err then
					if is_unversioned_error(tracked_err, tracked_raw) then
						return task:finish(nil, "File is not tracked by SVN", { code = "untracked" })
					end
					return task:finish(nil, tracked_err)
				end
				task:add(
					process.lines(
						{ "svn", "status", "--depth", "empty", literal_target(path) },
						{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
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

							if code == "A" or (code == "R" and no_pristine(svn_xml.parse_info(info.stdout))) then
								return task:finish(payload(root, relpath, true, "EMPTY", ""))
							end

							task:add(
								process.start(
									{ "svn", "proplist", "--xml", "-r", "BASE", literal_target(path) },
									{ cwd = root },
									function(props, props_err)
										if not props then
											if is_added_base_error(props_err) then
												return task:finish(payload(root, relpath, true, "EMPTY", ""))
											end
											return task:finish(nil, props_err)
										end
										if props.stdout:match('name="svn:special"') then
											return task:finish(
												nil,
												"Editable hunks do not support SVN special entries",
												{ code = "unsupported_entry", kind = "symlink" }
											)
										end
										task:add(
											process.bytes(
												{ "svn", "cat", "-r", "BASE", literal_target(path) },
												{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
												function(lines, cat_err)
													if not lines then
														if is_added_base_error(cat_err) then
															return task:finish(
																payload(root, relpath, true, "EMPTY", "")
															)
														end
														return task:finish(nil, cat_err)
													end
													task:finish(payload(root, relpath, true, "BASE", lines))
												end
											)
										)
									end
								)
							)
						end
					)
				)
			end))
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

function M.validate_editable_base_async(path, identity, callback, opts)
	if identity.untracked then
		local task = Task.new(callback)
		task:add(entry.classify_async(path, function(kind, err)
			local valid, why = entry.editable(kind, err)
			if not valid then
				return task:finish(false, why)
			end
			if util.relpath(identity.root, path) ~= identity.relpath then
				return task:finish(false, "Repository entry changed")
			end
			task:add(M.is_versioned_async(path, function(versioned, version_err)
				task:finish(
					not versioned and not version_err,
					version_err or (versioned and "Repository entry is now tracked" or nil)
				)
			end, opts))
		end))
		return task
	end
	return M.load_base_async(path, function(result, err)
		local valid = result ~= nil and vim.deep_equal(result.base_identity, identity)
		callback(valid, err or (not valid and "Hunk base changed; retry the action" or nil))
	end, opts)
end

function M.revert_file(path)
	local root, err = get_root(path)
	if not root then
		return nil, err
	end
	local relpath, path_err = util.relpath(root, path)
	if not relpath then
		return nil, path_err
	end
	return util.system({ "svn", "revert", "--", literal_target(relpath) }, { cwd = root })
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
		local relpath, path_err = util.relpath(info.root, path)
		if not relpath then
			return task:finish(nil, path_err)
		end
		task:add(process.start({ "svn", "info", "--", literal_target(relpath) }, {
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
			local current, current_err = util.relpath(info.root, path)
			if current ~= relpath or util.canonical_path(info.root) ~= info.root then
				return task:finish(nil, current_err or "Repository entry changed before discard; retry the action")
			end
			local start = opts.start or util.system_start
			task:add(start({ "svn", "revert", "--", literal_target(relpath) }, {
				cwd = info.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
				preserve_on_shutdown = true,
				scope = "mutation",
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

function M.parse_status(raw, root)
	local items = {}
	local codes = {
		modified = "M",
		added = "A",
		deleted = "D",
		replaced = "R",
		conflicted = "C",
		unversioned = "?",
		missing = "!",
		obstructed = "~",
		incomplete = "!",
	}
	for _, item in ipairs(svn_xml.parse_status(raw)) do
		local code = codes[item.wc_item]
		if item.wc_item ~= "external" and item.wc_item ~= "ignored" then
			if item.tree_conflicted or item.wc_props == "conflicted" then
				code = "C"
			elseif not code and item.wc_props == "modified" then
				code = "M"
			end
			if code then
				local path = item.path
				items[#items + 1] = {
					status = code,
					label = status_label(code),
					path = path,
					absolute_path = root and util.normalize_literal_path(root .. "/" .. path) or path,
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

	local lines, err = util.system({ "svn", "status", "--xml" }, { cwd = root })
	if not lines then
		return nil, err
	end
	return M.parse_status(lines.stdout, root)
end

function M.changed_files_async(path, on_done, opts)
	opts = opts or {}
	local task = require("lazyvcs.backends.comparison").task(on_done)
	task:add(M.probe_async(path, function(info, err)
		if not task:is_active() then
			return
		end
		if not info then
			return task:finish(nil, err or "Not an SVN working copy")
		end
		task:add(process.bytes({ "svn", "status", "--xml" }, {
			cwd = info.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(lines, status_err)
			if not lines then
				return task:finish(nil, status_err)
			end
			require("lazyvcs.backends.svn_untracked").expand(
				task,
				{ root = info.root, vcs = "svn" },
				svn_xml.parse_status(lines),
				function(paths, expand_err)
					if not paths then
						return task:finish(nil, expand_err)
					end
					local items = vim.tbl_filter(function(item)
						return item.status ~= "?"
					end, M.parse_status(lines, info.root))
					for _, relpath in ipairs(paths) do
						items[#items + 1] = {
							status = "?",
							label = status_label("?"),
							path = relpath,
							absolute_path = util.normalize_literal_path(info.root .. "/" .. relpath),
						}
					end
					task:finish(items)
				end
			)
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
	local path = target.path or (root and relpath and util.normalize_literal_path(root .. "/" .. relpath))
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

	if section == "remote" then
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
	elseif section == "untracked" or change_kind == "untracked" or local_item == "unversioned" then
		comparison.kind = "svn_untracked"
		comparison.left = empty_side()
		comparison.right = worktree_side(path)
		comparison.editable_side = "right"
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

	local needs_remote_url = comparison.section == "remote"

	local function snapshot_side(side, bytes)
		if #bytes > 1024 * 1024 then
			return nil, "File exceeds the 1 MiB preview limit"
		end
		-- Retain the existing object line model, including CRLF and BOM bytes.
		side.bytes, side.lines = bytes, util.split_lines(bytes)
		side.document = {
			lines = side.lines,
			eol = bytes:sub(-1) == "\n",
			empty = bytes == "",
			encoding = "utf-8",
			bom = false,
			profile_key = "svn-object",
		}
		return true
	end

	local function load_sides(entry_url)
		local sides = {}
		for _, key in ipairs({ "left", "right", "property_patch" }) do
			if
				comparison[key]
				and (not comparison.property_only or (comparison[key].source or {}).kind == "svn_property_patch")
			then
				sides[#sides + 1] = comparison[key]
			end
		end
		local pending = 0
		local failed = false
		local function complete()
			if failed or pending ~= 0 or not task:is_active() then
				return
			end
			if comparison.editable_side == "right" and not comparison.property_only then
				pending = 1
				if comparison.kind == "svn_untracked" then
					task:add(entry.classify_async(comparison.path, function(kind, err)
						local valid, why = entry.editable(kind, err)
						if not valid then
							return task:finish(nil, why)
						end
						comparison.base_identity =
							{ root = comparison.root, relpath = comparison.relpath, untracked = true }
						task:finish(comparison)
					end))
				else
					task:add(M.load_base_async(comparison.path, function(payload, err)
						if not payload then
							return task:finish(nil, err)
						end
						comparison.base_identity = payload.base_identity
						task:finish(comparison)
					end, { root = comparison.root }))
				end
			else
				task:finish(comparison)
			end
		end
		for _, side in ipairs(sides) do
			local source = side.source or {}
			if source.kind == "empty" then
				snapshot_side(side, "")
			elseif source.kind == "worktree" and not comparison.editable_side then
				pending = pending + 1
				require("lazyvcs.backends.comparison").read_file(task, source.path, function(raw, err)
					pending = pending - 1
					if not raw then
						failed = true
						return task:finish(nil, err)
					end
					local decoded, decode_err = snapshot_side(side, raw)
					if not decoded then
						failed = true
						return task:finish(nil, decode_err)
					end
					complete()
				end)
			elseif source.kind == "svn_object" or source.kind == "svn_property_patch" then
				pending = pending + 1
				local command_path = source.path
				if source.remote then
					command_path = entry_url
				end
				local args
				if source.kind == "svn_property_patch" then
					args = { "svn", "diff", "--properties-only", "--depth", "empty" }
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
					vim.list_extend(args, { "--", source.remote and literal_target(command_path) or command_path })
				else
					args = { "svn", "cat", "-r", source.revision, literal_target(command_path, source.peg_revision) }
				end
				local raw_side = comparison.editable_side == "right"
					and side == comparison.left
					and source.kind == "svn_object"
				local loader = source.kind == "svn_object" and process.bytes or process.lines
				task:add(loader(args, {
					cwd = comparison.root,
					timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
				}, function(lines, err)
					pending = pending - 1
					if failed then
						return
					end
					if not lines then
						if
							comparison.kind == "svn_local"
							and comparison.wc_item == "replaced"
							and side == comparison.left
							and is_added_base_error(err)
						then
							side.label, side.source, side.bytes, side.lines = "EMPTY", { kind = "empty" }, "", {}
							comparison.title = "EMPTY ↔ " .. comparison.right.label
							return complete()
						end
						if
							source.allow_missing
							and type(err) == "string"
							and (err:match("E160013") or err:match("W160013") or is_added_base_error(err))
						then
							snapshot_side(side, "")
							return complete()
						end
						failed = true
						return task:finish(nil, err)
					end
					if raw_side then
						side.bytes, side.lines = lines, nil
					else
						if source.kind == "svn_object" then
							local decoded, decode_err = snapshot_side(side, lines)
							if not decoded then
								failed = true
								return task:finish(nil, decode_err)
							end
						else
							side.lines = lines
						end
					end
					complete()
				end))
			end
		end
		complete()
	end

	local function classify_sides(entry_url)
		if comparison.property_only then
			return load_sides(entry_url)
		end
		local keys, cursor, kinds = { "left", "right" }, 0, {}
		local base_source
		local next_side
		next_side = function()
			if not task:is_active() then
				return
			end
			cursor = cursor + 1
			local key = keys[cursor]
			if not key then
				local directory = kinds.left == "dir" or kinds.right == "dir"
				if directory then
					local text_side = kinds.left == "file" or kinds.right == "file"
					comparison.editable_side = nil
					if not text_side then
						comparison.property_only = true
						comparison.property_patch = {
							label = needs_remote_url and "REMOTE PROPERTIES" or "LOCAL PROPERTIES",
							source = {
								kind = "svn_property_patch",
								path = comparison.path,
								remote = needs_remote_url,
								base_revision = comparison.base_revision,
							},
							modifiable = false,
						}
					else
						if kinds.left == "file" and base_source then
							comparison.left.source = base_source
						end
						for _, name in ipairs(keys) do
							if kinds[name] == "dir" then
								comparison[name] = empty_side(comparison[name].label .. " (DIRECTORY)")
							end
						end
					end
				end
				return load_sides(entry_url)
			end
			local side = comparison[key]
			local source = side.source or {}
			if source.kind == "empty" then
				return next_side()
			end
			if source.kind == "worktree" then
				return task:add(entry.classify_async(source.path, function(kind, err)
					if not kind then
						return task:finish(nil, err)
					end
					kinds[key] = kind == "directory" and "dir" or kind == "missing" and "missing" or "file"
					next_side()
				end))
			end
			if
				key == "left"
				and not source.remote
				and comparison.wc_item == "replaced"
				and comparison.base_revision
				and entry_url
			then
				base_source = vim.tbl_extend("force", source, {
					path = entry_url,
					revision = tostring(comparison.base_revision),
					peg_revision = tostring(comparison.base_revision),
				})
				source = base_source
			end
			local path = source.remote and entry_url or source.path
			local args = { "svn", "info", "--xml" }
			-- A revision makes info contact the server, even for BASE. Ordinary
			-- local sides use the kind retained in working-copy metadata.
			local historical = source.remote or source == base_source or source.revision ~= "BASE"
			if historical then
				vim.list_extend(args, { "-r", source.revision })
			end
			args[#args + 1] = literal_target(path, historical and source.peg_revision or nil)
			task:add(process.bytes(args, {
				cwd = comparison.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
			}, function(raw, err)
				local info = raw and svn_xml.parse_info(raw)
				if not info then
					if comparison.wc_item == "replaced" and is_added_base_error(err) then
						return next_side()
					end
					return task:finish(nil, err or "Unable to determine SVN entry kind")
				end
				if key == "left" and not historical and no_pristine(info) then
					comparison.left = empty_side()
					comparison.title = "EMPTY ↔ " .. comparison.right.label
				else
					kinds[key] = info.kind
				end
				next_side()
			end))
		end
		next_side()
	end

	if not needs_remote_url and not (comparison.wc_item == "replaced" and comparison.base_revision) then
		classify_sides(nil)
		return task
	end
	local deadline = vim.uv.now() + (opts.timeout_ms or ASYNC_TIMEOUT_MS)
	local function resolve_url(path, suffix)
		local remaining = deadline - vim.uv.now()
		if remaining <= 0 then
			return task:finish(nil, "SVN URL discovery timed out")
		end
		task:add(process.start({ "svn", "info", "--xml", literal_target(path) }, {
			cwd = comparison.root,
			timeout = remaining,
		}, function(result, err, raw)
			if not result then
				local parent = vim.fs.dirname(path)
				if
					parent
					and parent ~= path
					and util.relative_literal_path(comparison.root, parent)
					and is_unversioned_error(err, raw)
				then
					return resolve_url(parent, vim.fs.basename(path) .. (suffix == "" and "" or "/" .. suffix))
				end
				return task:finish(nil, err)
			end
			local info = svn_xml.parse_info(result.stdout)
			if not info or not info.url then
				return task:finish(nil, "Unable to parse SVN entry URL")
			end
			comparison.base_revision = comparison.base_revision or info.revision
			classify_sides(require("lazyvcs.backends.svn_url").append_path(info.url, suffix))
		end))
	end
	resolve_url(comparison.path, "")
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

	local stat, stat_err, stat_code = vim.uv.fs_stat(path)
	if not stat then
		local task = Task.new(on_done)
		vim.schedule(function()
			local missing = stat_code == "ENOENT" or stat_code == "ENOTDIR"
			task:finish(nil, not missing and stat_err or nil)
		end)
		return task
	end

	local cwd = util.dir_of(path)
	local task = Task.new(on_done)
	task:add(discover_root_async(path, opts, function(result, err)
		if not task:is_active() then
			return
		end
		if err then
			return task:finish(nil, err)
		end
		local root = result
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
							local blame, read_err = uncommitted_blame_lines(path, opts.contents, opts.text)
							return task:finish(blame, read_err, root)
						end
					end

					-- Map BASE attribution onto captured or saved contents exactly once.
					-- SVN's default WORKING blame already includes saved local edits.
					local blame_args = { "svn", "blame", "-v", "-r", "BASE", literal_target(path) }
					task:add(
						process.lines(
							blame_args,
							{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
							function(lines, blame_err, raw)
								if not lines then
									if is_unversioned_error(blame_err, raw) then
										return task:finish(nil, nil, root)
									end
									if is_added_base_error(blame_err) then
										local blame, read_err = uncommitted_blame_lines(path, opts.contents, opts.text)
										return task:finish(blame, read_err, root)
									end
									return task:finish(nil, blame_err)
								end
								task:add(process.bytes({ "svn", "cat", "-r", "BASE", literal_target(path) }, {
									cwd = root,
									timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
								}, function(base, base_err)
									if not base then
										return task:finish(nil, base_err)
									end
									local format = require("lazyvcs.backends.blame_format")
									local common = require("lazyvcs.backends.comparison")
									local function decode(bytes)
										if opts.profile then
											return require("lazyvcs.compare_text").decode(
												bytes,
												opts.profile,
												format.decode_limit()
											)
										end
										local options = common.decode_options(path)
										options.hint = nil
										return require("lazyvcs.compare_text").decode_preview(
											bytes,
											options,
											format.decode_limit()
										)
									end
									local document, decode_err = decode(base)
									if not document then
										return task:finish(
											nil,
											opts.preview and "SVN BASE for blame: " .. tostring(decode_err)
												or decode_err
										)
									end
									local valid, format_err = format.svn_document(
										document,
										lines,
										opts.profile and opts.profile.fileformat or "dos"
									)
									if not valid then
										return task:finish(nil, format_err)
									end
									local current = opts.text
									if not current or current.eol == nil then
										local bytes = opts.contents or current and util.join_lines(current.lines)
										if not bytes then
											local ok, rows = pcall(vim.fn.readfile, path, "b")
											if not ok then
												return task:finish(nil, tostring(rows))
											end
											bytes = table.concat(rows, "\n")
										elseif type(bytes) == "table" then
											bytes = util.join_lines(bytes)
										end
										current, decode_err = decode(bytes)
										if not current then
											return task:finish(nil, decode_err)
										end
									end
									task:finish(
										require("lazyvcs.backends.blame_mapping").map(
											lines,
											document,
											current,
											"     - - -"
										),
										nil,
										root
									)
								end))
							end
						)
					)
				end
			)
		)
	end))
	return task
end

function M.parse_blame_entries(lines)
	local out = {}
	for _, line in ipairs(lines or {}) do
		local uncommitted = line:match("^%s*%-%s+%-%s+%-") ~= nil
		local revision, author, date
		if not uncommitted then
			revision, author, date =
				line:match("^%s*(%d+)%s+(.-)%s+(%d%d%d%d%-%d%d%-%d%d)%s+%d%d:%d%d:%d%d%s+[+-]%d%d%d%d%s+%b()%s")
			author = author and util.trim(author)
		end
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
