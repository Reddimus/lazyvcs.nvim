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
	local cwd, cwd_err = util.existing_directory(path)
	if not cwd then
		return nil, cwd_err
	end
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
	if not item and not parse_err then
		local ignored = util.system_result({ "git", "check-ignore", "-q", "--", "./" .. relpath }, { cwd = root })
		if ignored.code == 0 then
			return nil, "File is ignored by Git"
		end
		if ignored.code ~= 1 then
			return nil, util.system_error(ignored)
		end
	end
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

local function discover_root_async(path, opts, callback)
	local task = Task.new(callback)
	local function probe(cwd, cwd_err)
		if not task:is_active() then
			return
		end
		if not cwd then
			return task:finish(nil, cwd_err)
		end
		task:add(process.root({ "git", "rev-parse", "--show-toplevel" }, {
			cwd = cwd,
			root = opts.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(root, err, extra)
			task:finish(root, err, extra)
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

function M.probe_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	if not git_available() then
		vim.schedule(function()
			task:finish(nil, "git executable not found")
		end)
		return task
	end
	task:add(discover_root_async(path, opts, function(root, err)
		if not root then
			return task:finish(nil, err)
		end
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
	payload.presence = payload.presence
		or {
			left = payload.base_identity.untracked and "absent" or "present",
			right = "present",
		}
	payload.base_identity.content = vim.fn.sha256(vim.base64.encode(payload.base_bytes))
	payload.base_identity.base_encoding = payload.base_encoding
	return payload
end

local function finish_index_payload(task, root, relpath, payload, opts, oid, presence_checked)
	-- Status can hide ITA entries. Inspect the index without trusting worktree flags.
	if not presence_checked and payload.base_bytes == "" then
		task:add(
			require("lazyvcs.backends.git_index").intent_to_add_async(root, relpath, process.start, function(intent)
				if not task:is_active() then
					return
				end
				payload.presence = {
					left = intent == nil and "unknown" or intent and "absent" or "present",
					right = "present",
					intent_to_add = intent == true or nil,
				}
				finish_index_payload(task, root, relpath, payload, opts, oid, true)
			end, opts)
		)
		return
	end
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

	task:add(discover_root_async(path, opts, function(result, err, extra)
		if not task:is_active() then
			return
		end
		if err then
			return task:finish(nil, err, extra)
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
							return task:add(
								process.start(
									{ "git", "check-ignore", "-q", "--", "./" .. relpath },
									{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
									function(ignored, ignore_err, ignore_raw)
										if ignored then
											return task:finish(nil, "File is ignored by Git", { code = "untracked" })
										end
										if not ignore_raw or ignore_raw.code ~= 1 then
											return task:finish(nil, ignore_err)
										end
										task:finish(finalize_payload(payload))
									end
								)
							)
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
					local ours, has_conflict, has_stage0
					for record in records:gmatch("([^%z]+)%z") do
						local mode, oid, stage, name = record:match("^(%d+) (%x+) (%d+)\t(.*)$")
						if name ~= relpath or (mode ~= "100644" and mode ~= "100755") then
							return task:finish(nil, "Unsupported conflict index entry")
						end
						has_stage0 = has_stage0 or stage == "0"
						has_conflict = has_conflict or stage == "1" or stage == "2" or stage == "3"
						if stage == "2" then
							ours = oid
						end
					end
					if has_stage0 or not has_conflict then
						return task:finish(nil, "Conflict is resolved; reopen this file from Changes")
					end
					local identity = { root = root, relpath = relpath, index_stages = records }
					if not ours then
						return task:finish(finalize_payload({
							base_bytes = "",
							base_identity = identity,
							presence = { left = "absent", right = "present" },
						}))
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
		renamed_from = target.renamed_from,
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
		comparison.presence = { left = "unknown", right = "unknown", base = "HEAD", right_base = "INDEX" }
		comparison.left = git_side("HEAD", "HEAD:" .. old_path, false)
		comparison.right = git_side("INDEX", ":0:" .. relpath, false)
	elseif section == "changes" then
		comparison.kind = "git_unstaged"
		comparison.presence = { left = "present", right = "unknown" }
		comparison.left = git_side("INDEX", ":0:" .. relpath, false)
		if change_kind == "deleted" or status:sub(2, 2) == "D" then
			comparison.right = empty_side()
			comparison.presence.right = "absent"
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

	if comparison.kind == "git_staged" and not comparison._staged_entries then
		require("lazyvcs.backends.git_staged").prepare(
			task,
			comparison,
			opts.timeout_ms or ASYNC_TIMEOUT_MS,
			function(entries, err)
				if not entries then
					return task:finish(nil, err)
				end
				comparison._staged_entries = true
				comparison.presence = { base = "HEAD", right_base = "INDEX" }
				for _, key in ipairs({ "left", "right" }) do
					local item = entries[key]
					comparison.presence[key] = item and "present" or "absent"
					comparison[key] = item and git_side(key == "left" and "HEAD" or "INDEX", item.object, false)
						or empty_side()
					comparison[key].label = key == "left" and "HEAD" or "INDEX"
					comparison[key].snapshot_oid = item and item.oid or nil
				end
				comparison.title = "HEAD ↔ INDEX"
				task:add(M.load_diff_target_async(comparison, function(value, why)
					task:finish(value, why)
				end, opts))
			end
		)
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

	local function snapshot_side(side, bytes, decode_opts)
		if #bytes > 1024 * 1024 then
			return nil, "File exceeds the 1 MiB preview limit"
		end
		side.bytes = bytes
		side.document =
			require("lazyvcs.backends.comparison").snapshot_document(bytes, comparison.path, "git-object", decode_opts)
		side.lines = side.document.lines
		return true
	end

	local function snapshot_options(side, bytes, done)
		local object = side.source and side.source.object or ""
		local revision, relpath = object:match("^([^:]*):(.*)$")
		if not relpath then
			return done({})
		end
		if revision == "" then
			relpath = relpath:match("^%d:(.*)$") or relpath
		end
		local command_opts = { cwd = comparison.root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS }
		local args = {
			"git",
			"check-attr",
			"-z",
			revision == "" and "--cached" or "--source=" .. revision,
			"working-tree-encoding",
			"--",
			relpath,
		}
		local function attributes_loaded(raw, err)
			if not task:is_active() then
				return
			end
			if not raw then
				return done(nil, "Git snapshot attributes: " .. tostring(err))
			end
			local attributes = require("lazyvcs.backends.git_attributes")
			local parsed, parse_err = attributes.parse(raw, relpath)
			if not parsed or parsed["working-tree-encoding"] == nil then
				return done(nil, parse_err or "Git returned no exact snapshot attribute record")
			end
			done(attributes.encoding(parsed) and { hint = false, encoding = "utf-8" } or {})
		end
		local function changed_attributes()
			local text = require("lazyvcs.compare_text")
			local prefix = bytes:sub(1, 4)
			if
				prefix:sub(1, 3) == "\239\187\191"
				or prefix:sub(1, 2) == "\255\254"
				or prefix:sub(1, 2) == "\254\255"
				or prefix == "\0\0\254\255"
			then
				return done({ hint = false, fileencodings = "ucs-bom," .. vim.o.fileencodings })
			end
			if not bytes:find("\0", 1, true) and text.valid_utf8(bytes) then
				local hint = require("lazyvcs.backends.comparison").decode_options(comparison.path).hint
				if hint and hint.fileencoding ~= "utf-8" then
					local profile = {
						fileencoding = hint.fileencoding,
						fileformat = "unix",
						key = "historical-fallback",
						binary = false,
						bomb = false,
					}
					local hinted = text.decode(bytes, profile, 1024 * 1024)
					profile.fileencoding = "utf-8"
					local utf8 = text.decode(bytes, profile, 1024 * 1024)
					if hinted and utf8 and not vim.deep_equal(hinted.lines, utf8.lines) then
						return done(
							nil,
							"Git snapshot encoding is ambiguous: historical attributes changed and this Git lacks --source support"
						)
					end
				end
				return done({ hint = false, encoding = "utf-8" })
			end
			return done({})
		end
		local function older_git_attributes()
			-- Git 2.34 cannot inspect attributes from a tree. If the relevant
			-- attribute files match INDEX, --cached proves the same source policy.
			local paths, parent = { ".gitattributes" }, relpath:match("^(.*)/[^/]*$")
			while parent and parent ~= "" do
				paths[#paths + 1] = parent .. "/.gitattributes"
				parent = parent:match("^(.*)/[^/]*$")
			end
			local cursor = 1
			local batch
			batch = function()
				if not task:is_active() then
					return
				end
				if cursor > #paths then
					local cached = vim.deepcopy(args)
					cached[4] = "--cached"
					return task:add(process.bytes(cached, command_opts, attributes_loaded))
				end
				local argv = {
					"git",
					"diff",
					"--cached",
					"--name-only",
					"--no-ext-diff",
					"--no-textconv",
					"--no-renames",
					"-z",
					revision,
					"--",
				}
				local length = 0
				repeat
					argv[#argv + 1] = paths[cursor]
					length, cursor = length + #paths[cursor] + 32, cursor + 1
				until cursor > #paths or length + #paths[cursor] + 32 > 8192
				task:add(
					process.bytes(
						argv,
						vim.tbl_extend("force", command_opts, { output_limit_bytes = 2 * (length + 1024) }),
						function(changed, err)
							if not task:is_active() then
								return
							end
							if not changed then
								return done(nil, "Git snapshot attributes: " .. tostring(err))
							end
							if changed ~= "" then
								return changed_attributes()
							end
							batch()
						end
					)
				)
			end
			batch()
		end
		task:add(process.bytes(args, command_opts, function(raw, err)
			if not task:is_active() then
				return
			end
			if
				not raw
				and revision ~= ""
				and type(err) == "string"
				and (err:find("unknown option", 1, true) or err:find("unrecognized option", 1, true))
			then
				return older_git_attributes()
			end
			attributes_loaded(raw, err)
		end))
	end

	local pending = 0
	local failed = false
	local function complete()
		if failed or pending ~= 0 or not task:is_active() then
			return
		end
		comparison._staged_entries = nil
		if comparison.editable_side == "right" then
			pending = 1
			local function loaded(payload, err)
				if not payload then
					return task:finish(nil, err)
				end
				comparison.base_identity = payload.base_identity
				comparison.presence = payload.presence
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
		elseif
			comparison.kind == "git_staged"
			and comparison.right.bytes == ""
			and comparison.presence.right == "present"
		then
			pending = 1
			task:add(
				require("lazyvcs.backends.git_index").intent_to_add_async(
					comparison.root,
					comparison.relpath,
					util.system_start,
					function(intent, err)
						if intent == nil then
							return task:finish(nil, err)
						end
						if intent then
							comparison.presence.right = "absent"
						end
						task:finish(comparison)
					end,
					opts
				)
			)
		else
			task:finish(comparison)
		end
	end
	for _, side in ipairs(sides) do
		local source = side.source or {}
		if source.kind == "empty" then
			side.lines = {}
			if not comparison.editable_side then
				snapshot_side(side, "")
			end
		elseif source.kind == "git_submodule_patch" then
			pending = pending + 1
			local args = {
				"git",
				"-c",
				"diff.autoRefreshIndex=false",
				"diff",
				"--no-ext-diff",
				"--no-color",
				"--submodule=short",
				"--full-index",
			}
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
		elseif
			source.kind == "git_object" and not (comparison.editable_side == "right" and side == comparison.left)
		then
			pending = pending + 1
			local loader = process.bytes
			task:add(loader({ "git", "show", "--no-ext-diff", side.snapshot_oid or source.object }, {
				cwd = comparison.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
			}, function(lines, err, raw)
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
						snapshot_side(side, "")
						pending = pending - 1
						return complete()
					end
					failed = true
					return task:finish(nil, err)
				end
				if comparison.editable_side then
					side.lines = util.split_lines(lines)
					pending = pending - 1
					return complete()
				end
				snapshot_options(side, lines, function(decode_opts, attribute_err)
					if failed or not task:is_active() then
						return
					end
					pending = pending - 1
					if not decode_opts then
						failed = true
						return task:finish(nil, attribute_err)
					end
					local decoded, decode_err = snapshot_side(side, lines, decode_opts)
					if not decoded then
						failed = true
						return task:finish(nil, decode_err)
					end
					complete()
				end)
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

local function revert_index_error(result, relpath)
	local mode, stage, indexed = result.stdout:match("^(%d+) %x+ (%d)\t([^%z]+)%z$")
	if result.stdout == "" and not result.stdout_truncated then
		return "File is untracked; nothing to revert"
	end
	if
		result.stdout_truncated
		or result.stderr_truncated
		or stage ~= "0"
		or indexed ~= relpath
		or (mode ~= "100644" and mode ~= "100755" and mode ~= "120000")
	then
		return "Whole-file Discard requires an exact index file; refresh and retry"
	end
end

local function revert_stat_error(stat, err)
	if err and err ~= "ENOENT" and not tostring(err):match("^ENOENT[: ]") then
		return "Cannot verify whole-file Discard target: " .. tostring(err)
	end
	if not stat and not err then
		return "Cannot verify whole-file Discard target"
	end
	if stat and stat.type ~= "file" and stat.type ~= "link" then
		return "Whole-file Discard refuses " .. stat.type .. " obstruction; refresh and retry"
	end
end

-- Windows lstat also calls junctions links. Only symbolic links are eligible.
local function revert_link_command(path)
	return {
		"powershell.exe",
		"-NoProfile",
		"-NonInteractive",
		"-Command",
		"$item = Get-Item -Force -ErrorAction Stop -LiteralPath $env:LAZYVCS_LINK; "
			.. "'{0}|{1}' -f $item.LinkType, $item.PSIsContainer",
	}, { LAZYVCS_LINK = path }
end

local function revert_link_valid(result)
	local directory = result and util.trim(result.stdout):match("^SymbolicLink|(%a+)$")
	return result
		and not result.stdout_truncated
		and not result.stderr_truncated
		and (directory == "True" or directory == "False")
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
	local result, index_err = util.system(
		{ "git", "ls-files", "--stage", "-z", "--", relpath },
		{ cwd = root, text = false }
	)
	index_err = result and revert_index_error(result, relpath) or index_err
	if not result or index_err then
		return nil, index_err
	end
	local intent, intent_err = require("lazyvcs.backends.git_index").intent_to_add(root, relpath)
	if intent == nil then
		return nil, intent_err
	end
	if intent then
		return nil, "Intent-to-add file has no saved index content; nothing to revert"
	end

	local stat, stat_err = vim.uv.fs_lstat(path)
	local refusal = revert_stat_error(stat, stat_err)
	if refusal then
		return nil, refusal
	end
	if stat and stat.type == "link" and vim.fn.has("win32") == 1 then
		local command, env = revert_link_command(path)
		if not revert_link_valid(util.system(command, { cwd = root, env = env })) then
			return nil, "Whole-file Discard refuses junction or directory link obstruction"
		end
	end
	local current, current_err = util.relpath(root, path)
	if current ~= relpath or util.canonical_path(root) ~= root then
		return nil, current_err or "Repository entry changed before discard; retry the action"
	end
	return util.system({ "git", "restore", "--worktree", "--no-recurse-submodules", "--", relpath }, { cwd = root })
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
		local function perform_restore()
			if not task:is_active() then
				return
			end
			local current, current_err = util.relpath(info.root, path)
			if current ~= relpath or util.canonical_path(info.root) ~= info.root then
				return task:finish(nil, current_err or "Repository entry changed before discard; retry the action")
			end
			local start = opts.start or util.system_start
			task:add(start({ "git", "restore", "--worktree", "--no-recurse-submodules", "--", relpath }, {
				cwd = info.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
				preserve_on_shutdown = true,
				scope = "mutation",
			}, function(result, restore_err)
				task:finish(result, restore_err)
			end))
		end
		local function restore()
			task:add(
				require("lazyvcs.backends.git_index").intent_to_add_async(
					info.root,
					relpath,
					process.start,
					function(intent, intent_err)
						if intent == nil then
							return task:finish(nil, intent_err)
						end
						if intent then
							return task:finish(nil, "Intent-to-add file has no saved index content; nothing to revert")
						end
						perform_restore()
					end,
					opts
				)
			)
		end

		task:add(process.start({ "git", "ls-files", "--stage", "-z", "--", relpath }, {
			cwd = info.root,
			timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
		}, function(result, index_err)
			if not task:is_active() then
				return
			end
			index_err = result and revert_index_error(result, relpath) or index_err
			if index_err or not result then
				return task:finish(nil, index_err)
			end
			local request, submit_err = vim.uv.fs_lstat(path, function(stat_err, stat)
				vim.schedule(util.safe_callback(function()
					if not task:is_active() then
						return
					end
					local refusal = revert_stat_error(stat, stat_err)
					if refusal then
						return task:finish(nil, refusal)
					end
					if stat and stat.type == "link" and vim.fn.has("win32") == 1 then
						local command, env = revert_link_command(path)
						return task:add(process.start(command, {
							cwd = info.root,
							env = env,
							timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
						}, function(link)
							if not revert_link_valid(link) then
								return task:finish(
									nil,
									"Whole-file Discard refuses junction or directory link obstruction"
								)
							end
							restore()
						end))
					end
					restore()
				end))
			end)
			if not request then
				return task:finish(nil, "Cannot verify whole-file Discard target: " .. tostring(submit_err))
			end
		end))
	end, opts))
	return task
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

	return util.system_lines(
		{ "git", "blame", "--encoding=UTF-8", "--porcelain", "--", relpath },
		{ cwd = root, output_limit_bytes = 32 * 1024 * 1024 }
	)
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
									local blame_args = { "git", "blame", "--encoding=UTF-8", "--porcelain" }
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
										output_limit_bytes = 32 * 1024 * 1024,
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
	local cache = {}
	for _, line in ipairs(lines or {}) do
		local revision = line:match("^(%x+)%s+%d+%s+%d+")
		if revision and #revision ~= 40 and #revision ~= 64 then
			revision = nil
		end
		if revision then
			current = vim.tbl_extend("force", cache[revision] or {}, {
				revision = short_revision(revision),
				full_revision = revision,
				backend = M.name,
				uncommitted = revision:match("^0+$") and true or nil,
			})
			current.author, current.date, current.summary =
				current.author or "-", current.date or "-", current.summary or ""
		elseif current and line:sub(1, 1) == "\t" then
			cache[current.full_revision] = vim.deepcopy(current)
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
			elseif key == "author-mail" or key == "author-tz" or key == "filename" or key == "previous" then
				current[key:gsub("-", "_")] = value
			elseif key == "author-time" then
				local timestamp = tonumber(value)
				current.author_time = timestamp
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
	local lines, log_err = util.system_lines({
		"git",
		"show",
		"--no-ext-diff",
		"--no-color",
		"--stat",
		"--format=medium",
		"--encoding=UTF-8",
		tostring(revision),
	}, { cwd = root })
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
			"--encoding=UTF-8",
			tostring(revision),
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
