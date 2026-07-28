local util = require("lazyvcs.util")
local Task = require("lazyvcs.backends.task")

local M = {
	name = "git",
}

local ASYNC_TIMEOUT_MS = 30000

-- Mirror the svn backend's executable cache: backends/init.lua probes every
-- backend for each path, so an unguarded call here would spawn a failing process
-- on machines without Git.
local git_checked, git_present = false, false
local function git_available()
	if not git_checked then
		git_checked = true
		git_present = vim.fn.executable("git") == 1
	end
	return git_present
end

local function get_root(path)
	if not git_available() then
		return nil, "git executable not found"
	end
	local cwd = util.dir_of(path)
	local result, err = util.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd })
	if not result then
		return nil, err
	end
	return util.trim(result.stdout)
end

local function is_tracked(root, relpath)
	local _, err = util.system({ "git", "ls-files", "--error-unmatch", "--", relpath }, { cwd = root })
	return err == nil
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
	task:add(util.system_start({ "git", "rev-parse", "--show-toplevel" }, {
		cwd = cwd,
		timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
	}, function(result, err)
		if not result then
			return task:finish(nil, err)
		end
		local root = util.trim(result.stdout)
		if root == "" then
			return task:finish(nil, "Git returned an empty working-tree root")
		end
		task:finish({ root = root })
	end))
	return task
end

function M.load(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not a Git working tree"
	end

	local relpath = util.relpath(root, path)
	local tracked = is_tracked(root, relpath)
	---@type string[]
	local base_lines = {}
	local base_label = "EMPTY"

	if tracked then
		local loaded_lines, load_err = util.system_lines({ "git", "show", ":" .. relpath }, { cwd = root })
		if not loaded_lines then
			return nil, load_err or err
		end
		base_lines = loaded_lines
		base_label = "INDEX"
	end

	return {
		name = M.name,
		root = root,
		relpath = relpath,
		tracked = tracked,
		base_label = base_label,
		base_lines = base_lines,
		impl = M,
	}
end

function M.root(path)
	return get_root(path)
end

function M.is_versioned(path)
	local root = get_root(path)
	if not root then
		return false
	end
	return is_tracked(root, util.relpath(root, path))
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
		local relpath = util.relpath(info.root, path)
		task:add(util.system_start({ "git", "ls-files", "--error-unmatch", "--", relpath }, {
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

	local relpath = util.relpath(root, path)
	if not is_tracked(root, relpath) then
		return {
			root = root,
			relpath = relpath,
			base_label = "EMPTY",
			base_lines = {},
		}
	end

	local lines, load_err = util.system_lines({ "git", "show", ":" .. relpath }, { cwd = root })
	if not lines then
		return nil, load_err
	end
	return {
		root = root,
		relpath = relpath,
		base_label = "INDEX",
		base_lines = lines,
	}
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
	task:add(util.system_start({ "git", "rev-parse", "--show-toplevel" }, {
		cwd = cwd,
		timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
	}, function(result, err)
		if not task:is_active() then
			return
		end
		if err then
			return task:finish(nil, err)
		end
		local root = util.trim(result.stdout)
		local relpath = util.relpath(root, path)

		task:add(
			util.system_start(
				{ "git", "ls-files", "--error-unmatch", "--", relpath },
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
							base_lines = {},
						}
						if not base_only then
							payload.name = M.name
							payload.impl = M
						end
						return task:finish(payload)
					end

					task:add(util.system_lines_start({ "git", "show", ":" .. relpath }, {
						cwd = root,
						timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
					}, function(lines, show_err)
						if not lines then
							return task:finish(nil, show_err)
						end
						local payload = {
							root = root,
							relpath = relpath,
							tracked = true,
							base_label = "INDEX",
							base_lines = lines,
						}
						if not base_only then
							payload.name = M.name
							payload.impl = M
						end
						task:finish(payload)
					end))
				end
			)
		)
	end))
	return task
end

function M.load_async(path, on_done, opts)
	return load_payload_async(path, on_done, opts, false)
end

function M.load_base_async(path, on_done, opts)
	return load_payload_async(path, on_done, opts, true)
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
	local path = target.path or (root and relpath and vim.fs.normalize(root .. "/" .. relpath))
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

	if section == "merge" or change_kind == "conflict" then
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
			comparison.right = git_side("INDEX", ":" .. relpath, false)
		end
	elseif section == "changes" then
		comparison.kind = "git_unstaged"
		comparison.left = git_side("INDEX", ":" .. relpath, false)
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
		if not failed and pending == 0 then
			task:finish(comparison)
		end
	end
	for _, side in ipairs(sides) do
		local source = side.source or {}
		if source.kind == "empty" then
			side.lines = {}
		elseif source.kind == "git_object" then
			pending = pending + 1
			task:add(util.system_lines_start({ "git", "show", "--no-ext-diff", source.object }, {
				cwd = comparison.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
			}, function(lines, err)
				pending = pending - 1
				if failed then
					return
				end
				if not lines then
					if source.allow_missing then
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
	return task
end

-- `git status --porcelain` C-quotes any path with non-ASCII or special bytes:
-- `caf<e9>.txt` is reported as `"caf\303\251.txt"`. Stripping only the quotes
-- leaves literal backslash escapes, and vim.fs.normalize then turns those
-- backslashes into path separators, so the file could never be opened.
local function unquote_path(path)
	if not path:match('^".*"$') then
		return path
	end
	path = path:sub(2, -2)
	return (
		path:gsub("\\(%d%d%d)", function(octal)
			return string.char(tonumber(octal, 8))
		end):gsub("\\(.)", function(char)
			return ({ a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" })[char] or char
		end)
	)
end

function M.parse_status_lines(lines, root)
	local items = {}
	for _, line in ipairs(lines or {}) do
		if #line > 3 then
			local index_code, worktree_code = line:sub(1, 1), line:sub(2, 2)
			-- Prefer the worktree column; it is what the user sees on disk.
			local code = worktree_code ~= " " and worktree_code or index_code
			local path = util.trim(line:sub(4))
			-- Only rename/copy entries use `old -> new`; splitting unconditionally
			-- would truncate a file legitimately named `a -> b.txt`.
			if index_code == "R" or index_code == "C" then
				local _, _, renamed = path:find("%s%->%s(.+)$")
				path = renamed or path
			end
			path = unquote_path(path)
			if code ~= "" and code ~= " " and path ~= "" then
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
	if not git_available() then
		return nil, "git executable not found"
	end

	local lines, err = util.system_lines({ "git", "status", "--porcelain", "--untracked-files=normal" }, { cwd = root })
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
			return task:finish(nil, err or "Not a Git working tree")
		end
		task:add(util.system_lines_start({ "git", "status", "--porcelain", "--untracked-files=normal" }, {
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

function M.revert_file(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not a Git working tree"
	end

	local relpath = util.relpath(root, path)
	if not is_tracked(root, relpath) then
		return nil, "File is untracked; nothing to revert"
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
		local relpath = util.relpath(info.root, path)
		task:add(util.system_start({ "git", "ls-files", "--error-unmatch", "--", relpath }, {
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
			task:add(util.system_start({ "git", "restore", "--worktree", "--", relpath }, {
				cwd = info.root,
				timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
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

function M.revert_hunk(session, hunk)
	if not session.tracked or session.base_label ~= "INDEX" or not session.opts.use_gitsigns then
		return false
	end

	local ok, gitsigns = pcall(require, "gitsigns")
	if not ok or vim.b[session.editable_bufnr].gitsigns_status_dict == nil then
		return false
	end

	local winid = session.editable_win
	if not util.win_is_valid(winid) then
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

	local relpath = util.relpath(root, path)
	if not is_tracked(root, relpath) then
		return nil, "File is not tracked by Git"
	end

	return util.system_lines({ "git", "blame", "--line-porcelain", "--", relpath }, { cwd = root })
end

function M.blame_lines_async(path, on_done, opts)
	opts = opts or {}
	local cwd = util.dir_of(path)
	local task = Task.new(on_done)
	if not git_available() then
		vim.schedule(function()
			task:finish(nil, "git executable not found")
		end)
		return task
	end

	task:add(util.system_start({ "git", "rev-parse", "--show-toplevel" }, {
		cwd = cwd,
		timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
	}, function(result, err)
		if not task:is_active() then
			return
		end
		if err then
			return task:finish(nil, err)
		end

		local root = util.trim(result.stdout)
		local relpath = util.relpath(root, path)
		task:add(
			util.system_start(
				{ "git", "ls-files", "--error-unmatch", "--", relpath },
				{ cwd = root, timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS },
				function(_, tracked_err, raw)
					if not task:is_active() then
						return
					end
					if tracked_err then
						if raw and raw.code == 1 then
							return task:finish(nil, "File is not tracked by Git")
						end
						return task:finish(nil, tracked_err)
					end
					local blame_args = { "git", "blame", "--line-porcelain" }
					local blame_opts = {
						cwd = root,
						timeout = opts.timeout_ms or ASYNC_TIMEOUT_MS,
					}
					if opts.contents ~= nil then
						vim.list_extend(blame_args, { "--contents", "-" })
						blame_opts.stdin = type(opts.contents) == "table" and util.join_lines(opts.contents)
							or tostring(opts.contents)
					end
					vim.list_extend(blame_args, { "--", relpath })
					task:add(util.system_lines_start(blame_args, blame_opts, function(lines, blame_err)
						if not lines then
							return task:finish(nil, blame_err)
						end
						task:finish(lines, nil, root)
					end))
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
		local revision = line:match(
			"^(%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x)%s+%d+%s+%d+"
		)
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
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.blame_lines_async(path, function(lines, err)
		if not lines then
			return task:finish(nil, err)
		end
		local entry = M.parse_blame_entries(lines)[line_number]
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
	local relpath = util.relpath(root, path)
	local lines, log_err = util.system_lines(
		{ "git", "show", "--no-ext-diff", "--stat", "--format=medium", tostring(revision), "--", relpath },
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
		local relpath = util.relpath(info.root, path)
		task:add(util.system_lines_start({
			"git",
			"show",
			"--no-ext-diff",
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

function M.parse_remote_url(url)
	url = util.trim(url or "")
	if url == "" then
		return nil
	end

	local host, path = url:match("^git@([^:]+):(.+)$")
	if not host then
		host, path = url:match("^[%w+.-]+://([^/]+)/(.+)$")
		if host then
			host = host:gsub("^.+@", "")
		end
	end
	if not host or not path then
		return nil
	end

	path = path:gsub("%.git$", "")
	if host == "github.com" then
		local owner, repo = path:match("^([^/]+)/(.+)$")
		if owner and repo then
			return {
				provider = "github",
				base_url = "https://github.com/" .. owner .. "/" .. repo,
				owner = owner,
				repo = repo,
			}
		end
	end

	if host == "bitbucket.org" then
		local workspace, repo = path:match("^([^/]+)/(.+)$")
		if workspace and repo then
			return {
				provider = "bitbucket",
				base_url = "https://bitbucket.org/" .. workspace .. "/" .. repo,
				workspace = workspace,
				repo = repo,
			}
		end
	end

	local base = "https://" .. host
	local project, repo = path:match("^scm/([^/]+)/(.+)$")
	if base and project and repo then
		return {
			provider = "bitbucket_server",
			base_url = base .. "/projects/" .. project:upper() .. "/repos/" .. repo,
			project = project:upper(),
			repo = repo,
		}
	end

	project, repo = path:match("^projects/([^/]+)/repos/(.+)$")
	if base and project and repo then
		return {
			provider = "bitbucket_server",
			base_url = base .. "/projects/" .. project:upper() .. "/repos/" .. repo,
			project = project:upper(),
			repo = repo,
		}
	end

	return nil
end

function M.commit_url(root, revision, remote)
	local url = remote
	if not url or url == "" then
		local result = util.system({ "git", "remote", "get-url", "origin" }, { cwd = root })
		url = result and result.stdout or ""
	end
	local parsed = M.parse_remote_url(url)
	if not parsed then
		return nil
	end
	if parsed.provider == "github" then
		return parsed.base_url .. "/commit/" .. revision
	end
	if parsed.provider == "bitbucket" then
		return parsed.base_url .. "/commits/" .. revision
	end
	if parsed.provider == "bitbucket_server" then
		return parsed.base_url .. "/commits/" .. revision
	end
	return nil
end

return M
