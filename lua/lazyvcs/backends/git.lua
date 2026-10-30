local util = require("lazyvcs.util")
local process = require("lazyvcs.backends.process")
local entry = require("lazyvcs.backends.entry")
local Task = require("lazyvcs.backends.task")

local M = {
	name = "git",
}

local ASYNC_TIMEOUT_MS = 30000

-- Cache executable availability by PATH. Recheck after PATH changes, including Homebrew
-- fixes in GUI-launched Neovim.
local git_cached_path, git_present = nil, false
local function git_available()
	local path = vim.env.PATH or ""
	if git_cached_path ~= path then
		git_cached_path = path
		git_present = vim.fn.executable("git") == 1
	end
	return git_present
end

local function get_root(path)
	if not git_available() then
		return nil, "git executable not found"
	end
	local cwd = util.dir_of(path)
	local result, err = util.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd, text = false })
	if not result then
		return nil, err
	end
	-- Canonicalize roots to match sidebar identities, including Windows short paths.
	return process.root_output(result.stdout)
end

local function is_tracked(root, relpath)
	local _, err = util.system({ "git", "ls-files", "--error-unmatch", "--", relpath }, { cwd = root })
	return err == nil
end

local function index_entry(bytes, relpath)
	local found
	for record in (bytes or ""):gmatch("([^%z]+)%z") do
		local mode, oid, stage, path = record:match("^(%d+) (%x+) (%d+)\t(.*)$")
		if not mode or path ~= relpath or stage ~= "0" or found then
			return nil, "Unmerged index; open this file from the sidebar's Merge Changes section"
		end
		if mode ~= "100644" and mode ~= "100755" then
			return nil, "Editable hunks require a regular index entry; symlink bases are unsupported"
		end
		found = { mode = mode, oid = oid }
	end
	return found
end

local function editable_sync(root, relpath, path)
	local valid, err = entry.editable(entry.classify(path))
	if not valid then
		return nil, err
	end
	local result, load_err = util.system(
		{ "git", "ls-files", "--stage", "-z", "--", relpath },
		{ cwd = root, text = false }
	)
	if not result then
		return nil, load_err
	end
	local item, parse_err = index_entry(result.stdout, relpath)
	return item or (not parse_err and { untracked = true } or nil), parse_err
end

-- `git status --porcelain` reports two status columns (index, worktree). Collapse
-- them to the single most meaningful code so the sidebar and picker can share the
-- svn presentation.
local function status_label(code)
	return ({
		M = "modified",
		A = "added",
		D = "deleted",
		R = "renamed",
		C = "copied",
		U = "conflicted",
		["?"] = "untracked",
		["!"] = "ignored",
	})[code] or "changed"
end

local function short_revision(revision)
	if not revision or revision == "" then
		return "-"
	end
	return revision:sub(1, 8)
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
	if not git_available() then
		vim.schedule(function()
			task:finish(nil, "git executable not found")
		end)
		return task
	end
	local cwd = util.dir_of(path)
	task:add(process.root({ "git", "rev-parse", "--show-toplevel" }, {
		cwd = cwd,
		root = opts.root,
		timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
	}, function(result, err)
		if not result then
			return task:finish(nil, err)
		end
		local root = result
		if root == "" then
			return task:finish(nil, "Git returned an empty working-tree root")
		end
		task:finish({ root = root })
	end))
	return task
end

-- Only built-in ident expansion is safe for background checkout-form reads.
local function index_encoding(records)
	local attributes = require("lazyvcs.backends.git_attributes")
	local attrs = attributes.parse(records) or {}
	local attribute = attributes.encoding(attrs)
	local filter = attrs.filter
	local checkout = attrs.ident == "set" and (filter == "unspecified" or filter == "unset")
	return { encoding = not checkout and attribute and "utf-8" or nil, attribute = attribute, checkout = checkout }
end

local function index_command(relpath, oid, encoding)
	if encoding.checkout then
		return { "git", "cat-file", "--filters", "--path=" .. relpath, oid }
	end
	return { "git", "show", oid }
end

local function encoding_sync(root, relpath)
	local result, err = util.system(
		{ "git", "check-attr", "-z", "working-tree-encoding", "ident", "filter", "--", relpath },
		{ cwd = root, text = false }
	)
	if not result then
		return nil, err
	end
	return index_encoding(result.stdout)
end

---@param payload table
---@return table
local function finalize_payload(payload)
	payload.base_identity.content = vim.fn.sha256(vim.base64.encode(payload.base_bytes))
	payload.base_identity.base_encoding = payload.base_encoding
	return payload
end

local function finish_index_payload(task, root, relpath, payload, opts, oid)
	task:add(
		process.bytes(
			{ "git", "check-attr", "-z", "working-tree-encoding", "ident", "filter", "--", relpath },
			{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
			function(records, err)
				if not records then
					return task:finish(nil, err)
				end
				local encoding = index_encoding(records)
				payload.base_encoding = encoding.encoding
				payload.base_identity.working_tree_encoding = encoding.attribute
				if not encoding.checkout then
					return task:finish(finalize_payload(payload))
				end
				task:add(process.bytes(index_command(relpath, oid or payload.base_identity.oid, encoding), {
					cwd = root,
					timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
				}, function(bytes, filter_err)
					if bytes == nil then
						return task:finish(nil, filter_err)
					end
					payload.base_bytes = bytes
					task:finish(finalize_payload(payload))
				end))
			end
		)
	)
end

function M.load(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not a Git working tree"
	end

	local relpath, path_err = util.relpath(root, path)
	if not relpath then
		return nil, path_err
	end
	local item, eligibility_err = editable_sync(root, relpath, path)
	if not item then
		return nil, eligibility_err
	end
	local tracked = not item.untracked
	local encoding, encoding_err
	if tracked then
		encoding, encoding_err = encoding_sync(root, relpath)
		if not encoding then
			return nil, encoding_err
		end
	end
	local base_bytes = ""
	local base_label = "EMPTY"

	if tracked then
		local loaded, load_err = util.system(index_command(relpath, item.oid, encoding), { cwd = root, text = false })
		if not loaded then
			return nil, load_err or err
		end
		base_bytes = loaded.stdout
		base_label = "INDEX"
	end

	return finalize_payload({
		name = M.name,
		root = root,
		relpath = relpath,
		tracked = tracked,
		base_label = base_label,
		base_bytes = base_bytes,
		base_encoding = encoding and encoding.encoding,
		base_identity = {
			root = root,
			relpath = relpath,
			mode = item.mode,
			oid = item.oid,
			untracked = item.untracked,
			working_tree_encoding = encoding and encoding.attribute,
		},
		impl = M,
	})
end

function M.root(path)
	return get_root(path)
end

function M.is_versioned(path)
	local root = get_root(path)
	if not root then
		return false
	end
	local relpath, err = util.relpath(root, path)
	if not relpath then
		return false, err
	end
	return is_tracked(root, relpath)
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
		task:add(process.start({ "git", "ls-files", "--error-unmatch", "--", relpath }, {
			cwd = info.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(result, tracked_err, raw)
			if result then
				return task:finish(true)
			end
			if raw and raw.code == 1 then
				return task:finish(false)
			end
			task:finish(false, tracked_err)
		end))
	end, opts))
	return task
end

-- Base content for gutter signs and previews: the index, matching what the live
-- diff compares against. Untracked files have an empty base, the Git counterpart
-- of an SVN file scheduled for addition.
function M.load_base(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not a Git working tree"
	end

	local relpath, path_err = util.relpath(root, path)
	if not relpath then
		return nil, path_err
	end
	local item, eligibility_err = editable_sync(root, relpath, path)
	if not item then
		return nil, eligibility_err
	end
	if item.untracked then
		return finalize_payload({
			root = root,
			relpath = relpath,
			base_label = "EMPTY",
			base_bytes = "",
			base_identity = { root = root, relpath = relpath, untracked = true },
		})
	end

	local encoding, encoding_err = encoding_sync(root, relpath)
	if not encoding then
		return nil, encoding_err
	end
	local loaded, load_err = util.system(index_command(relpath, item.oid, encoding), { cwd = root, text = false })
	if not loaded then
		return nil, load_err
	end
	return finalize_payload({
		root = root,
		relpath = relpath,
		base_label = "INDEX",
		base_bytes = loaded.stdout,
		base_encoding = encoding.encoding,
		base_identity = {
			root = root,
			relpath = relpath,
			mode = item.mode,
			oid = item.oid,
			working_tree_encoding = encoding.attribute,
		},
	})
end

local function load_payload_async(path, on_done, opts, base_only)
	opts = opts or {}
	local task = Task.new(on_done)
	if not git_available() then
		vim.schedule(function()
			task:finish(nil, "git executable not found")
		end)
		return task
	end

	local cwd = util.dir_of(path)
	task:add(process.root({ "git", "rev-parse", "--show-toplevel" }, {
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
			task:add(
				process.start(
					{ "git", "ls-files", "--stage", "-z", "--error-unmatch", "--", relpath },
					{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
					function(_, tracked_err, raw)
						if not task:is_active() then
							return
						end
						if tracked_err then
							-- `--error-unmatch` uses exit 1 for an ordinary untracked path.
							-- Other exit codes indicate a real repository/process failure.
							if not raw or raw.code ~= 1 then
								return task:finish(nil, tracked_err)
							end
							local payload = {
								root = root,
								relpath = relpath,
								tracked = false,
								base_label = "EMPTY",
								base_bytes = "",
								base_identity = { root = root, relpath = relpath, untracked = true },
							}
							if not base_only then
								payload.name = M.name
								payload.impl = M
							end
							return task:finish(finalize_payload(payload))
						end

						if raw and (raw.stdout_truncated or raw.stderr_truncated) then
							return task:finish(nil, "Git index output was truncated")
						end
						local item, parse_err = index_entry(raw and raw.stdout, relpath)
						if not item then
							if base_only and parse_err and parse_err:match("^Unmerged") then
								return task:finish(nil)
							end
							return task:finish(nil, parse_err or "Missing exact index entry")
						end

						task:add(process.bytes({ "git", "show", item.oid }, {
							cwd = root,
							timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
						}, function(bytes, show_err)
							if bytes == nil then
								return task:finish(nil, show_err)
							end
							local payload = {
								root = root,
								relpath = relpath,
								tracked = true,
								base_label = "INDEX",
								base_bytes = bytes,
								base_identity = { root = root, relpath = relpath, mode = item.mode, oid = item.oid },
							}
							if not base_only then
								payload.name = M.name
								payload.impl = M
							end
							finish_index_payload(task, root, relpath, payload, opts)
						end))
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

local function conflict_base_async(path, root, relpath, callback, opts)
	opts = opts or {}
	local task = Task.new(callback)
	task:add(entry.classify_async(path, function(kind, err)
		local valid, why = entry.editable(kind, err)
		if not valid then
			return task:finish(nil, why)
		end
		if util.relpath(root, path) ~= relpath then
			return task:finish(nil, "Repository entry changed")
		end
		task:add(
			process.bytes(
				{ "git", "ls-files", "--stage", "-z", "--", relpath },
				{ cwd = root },
				function(records, load_err)
					if not records then
						return task:finish(nil, load_err)
					end
					local ours
					for record in records:gmatch("([^%z]+)%z") do
						local mode, oid, stage, name = record:match("^(%d+) (%x+) (%d+)\t(.*)$")
						if name ~= relpath or (mode ~= "100644" and mode ~= "100755") then
							return task:finish(nil, "Unsupported conflict index entry")
						end
						if stage == "2" then
							ours = oid
						end
					end
					local identity = { root = root, relpath = relpath, index_stages = records }
					if not ours then
						return task:finish(finalize_payload({ base_bytes = "", base_identity = identity }))
					end
					task:add(process.bytes({ "git", "show", ours }, { cwd = root }, function(bytes, show_err)
						if bytes == nil then
							return task:finish(nil, show_err)
						end
						finish_index_payload(
							task,
							root,
							relpath,
							{ base_bytes = bytes, base_identity = identity },
							opts,
							ours
						)
					end))
				end
			)
		)
	end))
	return task
end

function M.validate_editable_base_async(path, identity, callback, opts)
	local function loaded(result, err)
		local valid = result ~= nil and vim.deep_equal(result.base_identity, identity)
		callback(valid, err or (not valid and "Hunk base changed; retry the action" or nil))
	end
	if identity.index_stages then
		return conflict_base_async(path, identity.root, identity.relpath, loaded, opts)
	end
	return M.load_base_async(path, loaded, opts)
end

local function empty_side(label)
	return {
		label = label or "EMPTY",
		source = { kind = "empty" },
		lines = {},
		modifiable = false,
	}
end

local function git_side(label, object, allow_missing)
	return {
		label = label,
		source = {
			kind = "git_object",
			object = object,
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

---Resolve a source-control file item into an explicit comparison.
---@param target table
---@return table|nil comparison, string|nil err
function M.resolve_diff_target(target)
	target = target or {}
	local root = target.root or target.repo_root
	local relpath = target.relpath
	local path = target.path or (root and relpath and util.normalize_literal_path(root .. "/" .. relpath))
	if not root or not relpath then
		return nil, "Git diff target requires root and relpath"
	end

	local section = target.section
	if section == "unstaged" then
		section = "changes"
	end
	local change_kind = target.change_kind
	local status = target.status or ""
	local comparison = {
		backend = M.name,
		vcs = M.name,
		root = root,
		relpath = relpath,
		path = path,
		section = section,
		change_kind = change_kind,
		status = status,
	}

	if target.gitlink then
		comparison.kind = "git_submodule"
		comparison.left = empty_side()
		comparison.left.label = section == "staged" and "HEAD" or "INDEX"
		comparison.right = {
			label = section == "staged" and "INDEX PATCH" or "WORKTREE PATCH",
			modifiable = false,
			source = { kind = "git_submodule_patch", section = section },
		}
	elseif section == "merge" or change_kind == "conflict" then
		comparison.kind = "git_conflict"
		comparison.base = git_side("BASE", ":1:" .. relpath, true)
		comparison.ours = git_side("OURS", ":2:" .. relpath, true)
		comparison.theirs = git_side("THEIRS", ":3:" .. relpath, true)
		comparison.left = comparison.ours
		comparison.right = worktree_side(path)
		comparison.editable_side = "right"
	elseif section == "untracked" or change_kind == "untracked" or status == "??" then
		comparison.kind = "git_untracked"
		comparison.left = empty_side()
		comparison.right = worktree_side(path)
		comparison.editable_side = "right"
	elseif section == "staged" then
		comparison.kind = "git_staged"
		local old_path = target.renamed_from or relpath
		if change_kind == "added" or status:sub(1, 1) == "A" then
			comparison.left = empty_side()
		else
			comparison.left = git_side("HEAD", "HEAD:" .. old_path, false)
		end
		if change_kind == "deleted" or status:sub(1, 1) == "D" then
			comparison.right = empty_side()
		else
			comparison.right = git_side("INDEX", ":0:" .. relpath, false)
		end
	elseif section == "changes" then
		comparison.kind = "git_unstaged"
		comparison.left = git_side("INDEX", ":0:" .. relpath, false)
		if change_kind == "deleted" or status:sub(2, 2) == "D" then
			comparison.right = empty_side()
		else
			comparison.right = worktree_side(path)
			comparison.editable_side = "right"
		end
	else
		return nil, "Unsupported Git diff section: " .. tostring(section)
	end

	comparison.title = string.format("%s ↔ %s", comparison.left.label, comparison.right.label)
	return comparison
end

---Load immutable Git-object sides of a typed comparison. Worktree sides retain
---their path so the UI can use the user's real buffer rather than a stale read.
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
	local seen = {}
	for _, key in ipairs({ "left", "right", "base", "ours", "theirs" }) do
		local side = comparison[key]
		if side and not seen[side] then
			seen[side] = true
			sides[#sides + 1] = side
		end
	end

	local pending = 0
	local failed = false
	local function complete()
		if failed or pending ~= 0 or not task:is_active() then
			return
		end
		if comparison.editable_side == "right" then
			pending = 1
			local function loaded(payload, err)
				if not payload then
					return task:finish(nil, err)
				end
				comparison.base_identity = payload.base_identity
				comparison.left.base_encoding = payload.base_encoding
				comparison.left.bytes, comparison.left.lines = payload.base_bytes, nil
				task:finish(comparison)
			end
			if comparison.kind == "git_conflict" then
				task:add(conflict_base_async(comparison.path, comparison.root, comparison.relpath, loaded, opts))
			else
				task:add(
					M.load_base_async(comparison.path, loaded, { root = comparison.root, timeout_ms = opts.timeout_ms })
				)
			end
		else
			task:finish(comparison)
		end
	end
	for _, side in ipairs(sides) do
		local source = side.source or {}
		if source.kind == "empty" then
			side.lines = {}
		elseif source.kind == "git_submodule_patch" then
			pending = pending + 1
			local args = { "git", "diff", "--no-ext-diff", "--no-color", "--submodule=short", "--full-index" }
			if source.section == "staged" then
				args[#args + 1] = "--cached"
			end
			vim.list_extend(args, { "--", comparison.relpath })
			task:add(process.lines(args, {
				cwd = comparison.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
			}, function(lines, err)
				pending = pending - 1
				if not lines then
					failed = true
					return task:finish(nil, err)
				end
				side.lines = lines
				complete()
			end))
		elseif source.kind == "git_object" then
			pending = pending + 1
			local raw_side = comparison.editable_side == "right" and side == comparison.left
			local loader = process.bytes
			task:add(loader({ "git", "show", "--no-ext-diff", source.object }, {
				cwd = comparison.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
			}, function(lines, err, raw)
				pending = pending - 1
				if failed then
					return
				end
				if not lines then
					if
						source.allow_missing
						and raw
						and raw.code == 128
						and not raw.timed_out
						and not raw.cancelled
						and not raw.stderr_truncated
						and type(err) == "string"
						and (
							err:match("does not exist in")
							or err:match("exists on disk, but not in")
							or err:match("is in the index, but not at stage")
							or err:match("does not exist %(neither")
						)
					then
						side.lines = {}
						return complete()
					end
					failed = true
					return task:finish(nil, err)
				end
				if raw_side then
					side.bytes, side.lines = lines, nil
				else
					side.lines = util.split_lines(lines)
				end
				complete()
			end))
		end
	end
	complete()
	return task
end

-- Porcelain NUL records retain literal destination and source path bytes.
function M.parse_status(raw, root)
	local records, err = require("lazyvcs.backends.git_status").parse(raw)
	if not records then
		return nil, err
	end
	local items = {}
	for _, item in ipairs(records) do
		local index, worktree = item.status:sub(1, 1), item.status:sub(2, 2)
		local code = require("lazyvcs.backends.git_status").is_unmerged(item.status) and "U"
			or (worktree ~= " " and worktree or index)
		items[#items + 1] = {
			status = code,
			label = status_label(code),
			path = item.path,
			absolute_path = root and util.normalize_literal_path(root .. "/" .. item.path) or item.path,
		}
	end
	return items
end

function M.changed_files(root)
	if not git_available() then
		return nil, "git executable not found"
	end
	local result, err = util.system(
		{ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" },
		{ cwd = root, text = false }
	)
	if not result then
		return nil, err
	end
	return M.parse_status(result.stdout, root)
end

function M.changed_files_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.probe_async(path, function(info, err)
		if not info then
			return task:finish(nil, err or "Not a Git working tree")
		end
		task:add(process.bytes({ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" }, {
			cwd = info.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(raw, status_err)
			if not raw then
				return task:finish(nil, status_err)
			end
			task:finish(M.parse_status(raw, info.root))
		end))
	end, opts))
	return task
end

function M.revert_file(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not a Git working tree"
	end

	local relpath, path_err = util.relpath(root, path)
	if not relpath then
		return nil, path_err
	end
	if not is_tracked(root, relpath) then
		return nil, "File is untracked; nothing to revert"
	end
	local current, current_err = util.relpath(root, path)
	if current ~= relpath or util.canonical_path(root) ~= root then
		return nil, current_err or "Repository entry changed before discard; retry the action"
	end
	return util.system({ "git", "checkout", "--", relpath }, { cwd = root })
end

function M.revert_file_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.probe_async(path, function(info, err)
		if not task:is_active() then
			return
		end
		if not info then
			return task:finish(nil, err or "Not a Git working tree")
		end
		local relpath, path_err = util.relpath(info.root, path)
		if not relpath then
			return task:finish(nil, path_err)
		end
		task:add(process.start({ "git", "ls-files", "--error-unmatch", "--", relpath }, {
			cwd = info.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(_, tracked_err, raw)
			if not task:is_active() then
				return
			end
			if tracked_err then
				if raw and raw.code == 1 then
					return task:finish(nil, "File is untracked; nothing to revert")
				end
				return task:finish(nil, tracked_err)
			end
			local current, current_err = util.relpath(info.root, path)
			if current ~= relpath or util.canonical_path(info.root) ~= info.root then
				return task:finish(nil, current_err or "Repository entry changed before discard; retry the action")
			end
			local start = opts.start or util.system_start
			task:add(start({ "git", "restore", "--worktree", "--", relpath }, {
				cwd = info.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
				preserve_on_shutdown = true,
				scope = "mutation",
			}, function(result, restore_err)
				if not result then
					return task:finish(nil, restore_err)
				end
				task:finish(result)
			end))
		end))
	end, opts))
	return task
end

function M.revert_hunk(session, hunk, winid)
	if not session.tracked or session.base_label ~= "INDEX" or not session.opts.use_gitsigns then
		return false
	end

	local ok, gitsigns = pcall(require, "gitsigns")
	if not ok or vim.b[session.editable_bufnr].gitsigns_status_dict == nil then
		return false
	end

	-- Gitsigns has an independent, mutable base. Unknown cache layouts fall back
	-- to the validated native replacement rather than guessing the revision.
	local cache = package.loaded["gitsigns.cache"]
	local entry = type(cache) == "table" and type(cache.cache) == "table" and cache.cache[session.editable_bufnr]
	if
		type(entry) ~= "table"
		or entry.file_mode
		or type(entry.git_obj) ~= "table"
		or (entry.git_obj.revision ~= nil and entry.git_obj.revision ~= ":0")
		or type(gitsigns.get_hunks) ~= "function"
		or type(gitsigns.reset_hunk) ~= "function"
	then
		return false
	end
	local read_ok, hunks = pcall(gitsigns.get_hunks, session.editable_bufnr)
	if not read_ok or type(hunks) ~= "table" or not session.base_text or not session.current_text then
		return false
	end
	local matches = 0
	for _, candidate in ipairs(hunks) do
		if type(candidate) ~= "table" then
			return false
		end
		local added, removed = candidate.added, candidate.removed
		if
			type(added) == "table"
			and type(removed) == "table"
			and added.start == hunk.current_start
			and added.count == hunk.current_count
			and removed.start == hunk.base_start
			and removed.count == hunk.base_count
			and vim.deep_equal(
				added.lines,
				util.slice(session.current_text.lines, hunk.current_start, hunk.current_count)
			)
			and vim.deep_equal(removed.lines, util.slice(session.base_text.lines, hunk.base_start, hunk.base_count))
			and (added.no_nl_at_eof or false) == (hunk.covers_eof and not session.current_text.eol or false)
			and (removed.no_nl_at_eof or false) == (hunk.covers_eof and not session.base_text.eol or false)
		then
			matches = matches + 1
		end
	end
	if matches ~= 1 then
		return false
	end
	winid = winid or session.editable_win
	if not util.win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= session.editable_bufnr then
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	local anchor = math.max(hunk.current_start, 1)
	local reset_ok = pcall(function()
		vim.api.nvim_win_call(winid, function()
			vim.api.nvim_win_set_cursor(winid, { anchor, 0 })
			gitsigns.reset_hunk()
		end)
	end)

	pcall(vim.api.nvim_win_set_cursor, winid, cursor)
	return reset_ok
end

function M.blame_lines(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not a Git working tree"
	end

	local relpath, path_err = util.relpath(root, path)
	if not relpath then
		return nil, path_err
	end
	if not is_tracked(root, relpath) then
		return nil, "File is not tracked by Git"
	end

	return util.system_lines({ "git", "blame", "--encoding=UTF-8", "--line-porcelain", "--", relpath }, { cwd = root })
end

function M.blame_lines_async(path, on_done, opts)
	opts = vim.tbl_extend("force", {}, opts or {})
	local cwd = util.dir_of(path)
	local task = Task.new(on_done)
	if not git_available() then
		vim.schedule(function()
			task:finish(nil, "git executable not found")
		end)
		return task
	end

	task:add(process.root({ "git", "rev-parse", "--show-toplevel" }, {
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

		local root = result
		local relpath, path_err = util.relpath(root, path)
		if not relpath then
			return task:finish(nil, path_err)
		end
		task:add(
			process.start(
				{ "git", "ls-files", "--error-unmatch", "--", relpath },
				{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
				function(_, tracked_err, raw)
					if not task:is_active() then
						return
					end
					if tracked_err then
						if raw and raw.code == 1 then
							return task:finish(nil, nil, root)
						end
						return task:finish(nil, tracked_err)
					end
					task:add(
						require("lazyvcs.backends.git_blame_policy").load(
							root,
							relpath,
							opts,
							function(policy, policy_err)
								if not task:is_active() then
									return
								end
								if not policy then
									return task:finish(nil, policy_err)
								end
								local function blame()
									local blame_args = { "git", "blame", "--encoding=UTF-8", "--line-porcelain" }
									local format = require("lazyvcs.backends.blame_format")
									if
										opts.line_start
										and opts.line_end
										and not format.full_file(opts)
										and not policy.validate
									then
										vim.list_extend(blame_args, { "-L", opts.line_start .. "," .. opts.line_end })
									end
									local blame_opts = {
										cwd = root,
										timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
									}
									if opts.contents ~= nil then
										vim.list_extend(blame_args, { "--contents", "-" })
										blame_opts.stdin = type(opts.contents) == "table"
												and util.join_lines(opts.contents)
											or tostring(opts.contents)
									end
									vim.list_extend(blame_args, { "--", relpath })
									task:add(process.lines(blame_args, blame_opts, function(lines, blame_err)
										if not lines then
											if
												type(blame_err) == "string"
												and (
													blame_err:match("no such path .- in HEAD")
													or blame_err:match("no such ref: HEAD")
												)
											then
												local function uncommitted(data, read_err)
													if not data then
														return task:finish(nil, read_err)
													end
													local rows = {}
													for number, line in
														ipairs(opts.text and opts.text.lines or util.split_lines(data))
													do
														if
															not (opts.line_start and opts.line_end)
															or (number >= opts.line_start and number <= opts.line_end)
														then
															rows[#rows + 1] = string.rep("0", 40)
																.. " "
																.. number
																.. " "
																.. number
																.. " 1"
															rows[#rows + 1] = "author Not Committed Yet"
															rows[#rows + 1] = "\t" .. line
														end
													end
													task:finish(rows, nil, root)
												end
												if opts.contents ~= nil then
													return uncommitted(blame_opts.stdin)
												end
												return require("lazyvcs.backends.comparison").read_file(
													task,
													path,
													uncommitted
												)
											end
											return task:finish(nil, blame_err)
										end
										local selected, format_err = format.select(lines, opts, policy)
										task:finish(selected, format_err, root)
									end))
								end
								if policy.validate and not opts.text then
									local function captured(bytes, read_err)
										if not task:is_active() then
											return
										end
										if not bytes then
											return task:finish(nil, read_err)
										end
										local profile = opts.profile or { fileencoding = "utf-8", fileformat = "unix" }
										local decoded, decode_err =
											require("lazyvcs.compare_text").decode(bytes, profile, 1024 * 1024)
										if not decoded then
											return task:finish(nil, decode_err)
										end
										opts.text, opts.contents = decoded, bytes
										blame()
									end
									if opts.contents ~= nil then
										captured(
											type(opts.contents) == "table" and util.join_lines(opts.contents)
												or opts.contents
										)
									else
										require("lazyvcs.backends.comparison").read_file(task, path, captured)
									end
								else
									blame()
								end
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
	local current
	for _, line in ipairs(lines or {}) do
		local revision = line:match("^(%x+)%s+%d+%s+%d+")
		if revision and #revision ~= 40 and #revision ~= 64 then
			revision = nil
		end
		if revision then
			current = {
				revision = short_revision(revision),
				full_revision = revision,
				author = "-",
				date = "-",
				summary = "",
				backend = M.name,
				uncommitted = revision:match("^0+$") and true or nil,
			}
		elseif current and line:sub(1, 1) == "\t" then
			if current.uncommitted then
				current.revision = "-"
				current.full_revision = nil
			end
			out[#out + 1] = current
			current = nil
		elseif current then
			local key, value = line:match("^(%S+)%s+(.+)$")
			if key == "author" then
				current.author = value
			elseif key == "author-time" then
				local timestamp = tonumber(value)
				current.date = timestamp and os.date("%Y-%m-%d", timestamp) or "-"
			elseif key == "summary" then
				current.summary = value
			end
		end
	end
	return out
end

function M.parse_blame_metadata(lines, uncommitted_text)
	local out = {}
	for _, entry in ipairs(M.parse_blame_entries(lines)) do
		if entry.uncommitted then
			out[#out + 1] = uncommitted_text or "Uncommitted line"
		else
			out[#out + 1] = string.format("%8s %15s %s", entry.revision, entry.author, entry.date)
		end
	end
	return out
end

function M.line_revision(path, line_number)
	local lines, err = M.blame_lines(path)
	if not lines then
		return nil, err
	end
	local entry = M.parse_blame_entries(lines)[line_number]
	if not entry then
		return nil, "No blame information for this line"
	end
	if entry.uncommitted then
		return nil, "No committed Git revision for this line"
	end
	return entry.full_revision or entry.revision
end

function M.line_revision_async(path, line_number, on_done, opts)
	opts = vim.tbl_extend("force", {}, opts or {}, { line_start = line_number, line_end = line_number })
	local task = Task.new(on_done)
	task:add(M.blame_lines_async(path, function(lines, err)
		if not lines then
			return task:finish(nil, err)
		end
		local entry = M.parse_blame_entries(lines)[1]
		if not entry then
			return task:finish(nil, "No blame information for this line")
		end
		if entry.uncommitted then
			return task:finish(nil, "No committed Git revision for this line")
		end
		task:finish(entry.full_revision or entry.revision)
	end, opts))
	return task
end

function M.revision_log(path, revision)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not a Git working tree"
	end
	local relpath, path_err = util.relpath(root, path)
	if not relpath then
		return nil, path_err
	end
	local lines, log_err = util.system_lines(
		{ "git", "show", "--no-ext-diff", "--no-color", "--stat", "--format=medium", tostring(revision), "--", relpath },
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
			return task:finish(nil, err or "Not a Git working tree")
		end
		local relpath, path_err = util.relpath(info.root, path)
		if not relpath then
			return task:finish(nil, path_err)
		end
		task:add(process.lines({
			"git",
			"show",
			"--no-ext-diff",
			"--no-color",
			"--stat",
			"--format=medium",
			tostring(revision),
			"--",
			relpath,
		}, {
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
