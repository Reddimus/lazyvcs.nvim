local util = require("lazyvcs.util")

local M = {
	name = "git",
}

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
	local cwd = vim.fs.dirname(path)
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

function M.load_base_async(path, on_done)
	if not git_available() then
		vim.schedule(function()
			on_done(nil, "git executable not found")
		end)
		return nil
	end

	local cwd = vim.fs.dirname(path)
	return util.system_start({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd }, function(result, err)
		if err then
			return on_done(nil, err)
		end
		local root = util.trim(result.stdout)
		local relpath = util.relpath(root, path)

		util.system_start(
			{ "git", "ls-files", "--error-unmatch", "--", relpath },
			{ cwd = root },
			function(_, tracked_err)
				if tracked_err then
					-- Untracked: empty base rather than an error, so signs still render.
					return on_done({
						root = root,
						relpath = relpath,
						tracked = false,
						base_label = "EMPTY",
						base_lines = {},
					})
				end

				util.system_lines_start({ "git", "show", ":" .. relpath }, { cwd = root }, function(lines, show_err)
					if not lines then
						return on_done(nil, show_err)
					end
					on_done({
						root = root,
						relpath = relpath,
						tracked = true,
						base_label = "INDEX",
						base_lines = lines,
					})
				end)
			end
		)
	end)
end

function M.parse_status_lines(lines, root)
	local items = {}
	for _, line in ipairs(lines or {}) do
		if #line > 3 then
			local index_code, worktree_code = line:sub(1, 1), line:sub(2, 2)
			-- Prefer the worktree column; it is what the user sees on disk.
			local code = worktree_code ~= " " and worktree_code or index_code
			local path = util.trim(line:sub(4))
			-- Renames are reported as `old -> new`; keep the destination.
			local _, _, renamed = path:find("%s%->%s(.+)$")
			path = renamed or path
			-- Porcelain quotes paths containing special characters.
			path = path:gsub('^"(.*)"$', "%1")
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

function M.blame_lines_async(path, on_done)
	local cwd = vim.fs.dirname(path)
	local job = {
		handle = nil,
		cancelled = false,
	}
	function job:kill(signal)
		self.cancelled = true
		if self.handle then
			pcall(self.handle.kill, self.handle, signal or 15)
		end
	end

	job.handle = util.system_start({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd }, function(result, err)
		if job.cancelled then
			return
		end
		if err then
			return on_done(nil, err)
		end

		local root = util.trim(result.stdout)
		local relpath = util.relpath(root, path)
		job.handle = util.system_start(
			{ "git", "ls-files", "--error-unmatch", "--", relpath },
			{ cwd = root },
			function(_, tracked_err)
				if job.cancelled then
					return
				end
				if tracked_err then
					return on_done(nil, "File is not tracked by Git")
				end
				job.handle = util.system_lines_start(
					{ "git", "blame", "--line-porcelain", "--", relpath },
					{ cwd = root },
					function(lines, blame_err)
						if job.cancelled then
							return
						end
						if not lines then
							return on_done(nil, blame_err)
						end
						on_done(lines, nil, root)
					end
				)
			end
		)
	end)

	return job
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
