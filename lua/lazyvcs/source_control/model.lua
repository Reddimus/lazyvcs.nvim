local config = require("lazyvcs.config")
local runtime_state = require("lazyvcs.state")
local util = require("lazyvcs.util")

local M = {}

local uv = vim.uv

local function join(...)
	return table.concat({ ... }, "/")
end

local function normalize(path)
	return vim.fs.normalize(path)
end

local function basename(path)
	return vim.fs.basename(path)
end

local function is_dir(path)
	local stat = uv.fs_stat(path)
	return stat and stat.type == "directory" or false
end

local function file_exists(path)
	return uv.fs_stat(path) ~= nil
end

local function parse_svn_status_xml(raw)
	local entries = {}
	local current
	for tag_text in (raw or ""):gmatch("<[^>]+>") do
		if tag_text:match("^<entry%s") then
			current = {
				path = tag_text:match('path="([^"]+)"'),
			}
		elseif current and tag_text:match("^<wc%-status%s") then
			current.wc_item = tag_text:match('item="([^"]+)"')
			current.props = tag_text:match('props="([^"]+)"')
		elseif current and tag_text:match("^<repos%-status%s") then
			current.repos_item = tag_text:match('item="([^"]+)"')
		elseif current and tag_text:match("^</entry>") then
			if current.path and current.wc_item then
				entries[#entries + 1] = current
			end
			current = nil
		end
	end
	return entries
end

local function parse_svn_info_xml(raw)
	local entry = raw and raw:match("<entry.-</entry>") or nil
	if not entry then
		return nil
	end

	return {
		url = entry:match("<url>(.-)</url>"),
		root = entry:match("<root>(.-)</root>"),
		revision = entry:match('<entry[^>]-revision="([^"]+)"'),
	}
end

local function svn_branch_from_info(raw)
	local info = parse_svn_info_xml(raw)
	if not info or not info.url or info.url == "" then
		return "svn"
	end

	local rel = info.url
	if info.root and info.root ~= "" and rel:sub(1, #info.root) == info.root then
		rel = rel:sub(#info.root + 2)
	end
	rel = rel:gsub("^projects/", "")
	if rel == "trunk" then
		return "trunk"
	end
	local branch = rel:match("^branches/(.+)$")
	if branch then
		return branch
	end
	return rel ~= "" and rel or "svn"
end

local function resolve_svn_entry_path(repo_root, entry_path)
	local normalized = normalize(entry_path)
	if normalized:sub(1, #repo_root) == repo_root then
		return normalized, util.relpath(repo_root, normalized) or normalized
	end
	local absolute = normalize(join(repo_root, entry_path))
	return absolute, util.relpath(repo_root, absolute) or entry_path
end

local function repo_kind(path)
	if is_dir(join(path, ".git")) then
		return "git"
	end
	if is_dir(join(path, ".svn")) then
		return "svn"
	end
end

function M.repo_selector_id(root)
	return normalize(root) .. "::selector"
end

function M.repo_changes_id(root)
	return normalize(root) .. "::repo_changes"
end

local function section_node_id(root, id)
	return normalize(root) .. "::section::" .. id
end

local function folder_node_id(root, section, path)
	return string.format("%s::folder::%s::%s", normalize(root), section, path)
end

local function sync_badge(text, status, highlight)
	return {
		text = text,
		status = status,
		highlight = highlight,
	}
end

local function make_counts(previous)
	return {
		local_changes = previous and previous.counts and previous.counts.local_changes or 0,
		staged = previous and previous.counts and previous.counts.staged or 0,
		remote = previous and previous.counts and previous.counts.remote or 0,
	}
end

local function placeholder_status(repo, previous)
	return {
		root = repo.root,
		name = repo.name,
		vcs = repo.vcs,
		order = repo.order,
		relpath = repo.relpath,
		path_label = repo.path_label,
		branch = previous and previous.branch or nil,
		upstream = previous and previous.upstream or nil,
		sections = previous and previous.sections or {},
		counts = make_counts(previous),
		sync = previous and previous.sync or sync_badge("…", "loading", "Comment"),
		error = previous and previous.error or nil,
		summary_loaded = previous and previous.summary_loaded or false,
		details_loaded = previous and previous.details_loaded or false,
		loading_details = previous and previous.loading_details or false,
		loading_summary = previous and previous.loading_summary or false,
		refreshing_summary = previous and previous.refreshing_summary or false,
	}
end

local function apply_repo_job(status)
	local job = runtime_state.get_repo_job(status.root)
	if not job then
		status.job = nil
		return status
	end

	status.job = job
	if job.status == "running" then
		status.sync = sync_badge(job.sync_text or job.label or "Busy", "busy", "LazyVcsBusy")
		status.error = nil
	elseif job.status == "error" then
		status.sync = sync_badge("!", "error", "DiagnosticError")
		status.error = job.error or status.error
	end
	return status
end

function M.make_error(repo, previous, err)
	local status = placeholder_status(repo, previous)
	status.sync = sync_badge("!", "error", "DiagnosticError")
	status.error = err
	status.summary_loaded = true
	status.loading_details = false
	status.loading_summary = false
	status.refreshing_summary = false
	return apply_repo_job(status)
end

function M.make_placeholder(repo, previous)
	return apply_repo_job(placeholder_status(repo, previous))
end

local function scan_repos(root, max_depth, depth, repos, seen)
	root = normalize(root)
	if seen[root] then
		return
	end
	seen[root] = true

	local kind = repo_kind(root)
	if kind then
		repos[#repos + 1] = {
			root = root,
			name = basename(root),
			vcs = kind,
			order = #repos + 1,
		}
		if depth >= max_depth then
			return
		end
	end

	if depth >= max_depth then
		return
	end

	local fd = uv.fs_scandir(root)
	if not fd then
		return
	end

	while true do
		local name, entry_type = uv.fs_scandir_next(fd)
		if not name then
			break
		end
		if entry_type == "directory" and name ~= ".git" and name ~= ".svn" then
			scan_repos(join(root, name), max_depth, depth + 1, repos, seen)
		end
	end
end

local function annotate_repos(root, repos)
	local name_counts = {}
	for _, repo in ipairs(repos) do
		name_counts[repo.name] = (name_counts[repo.name] or 0) + 1
	end

	for _, repo in ipairs(repos) do
		repo.relpath = util.relpath(root, repo.root) or repo.name
		if name_counts[repo.name] > 1 then
			repo.path_label = repo.relpath
		else
			local parent = vim.fs.dirname(repo.relpath)
			repo.path_label = parent and parent ~= "." and parent ~= repo.relpath and parent or nil
		end
	end
end

function M.discover(root, max_depth)
	root = normalize(root)
	local repos = {}
	scan_repos(root, max_depth, 0, repos, {})
	annotate_repos(root, repos)
	table.sort(repos, function(a, b)
		return a.order < b.order
	end)
	return repos
end

local function parse_git_branch(line)
	local branch = util.trim((line or ""):gsub("^##%s*", ""))
	local upstream
	local ahead = 0
	local behind = 0
	local branch_name = branch

	local lhs, rhs, suffix = branch:match("^(.-)%.%.%.([^ ]+)(.*)$")
	if lhs and rhs then
		branch_name = lhs
		upstream = rhs
		ahead = tonumber((suffix or ""):match("ahead (%d+)") or "0") or 0
		behind = tonumber((suffix or ""):match("behind (%d+)") or "0") or 0
	end

	return {
		branch = branch_name,
		upstream = upstream,
		ahead = ahead,
		behind = behind,
	}
end

local function parse_git_summary(lines)
	local branch_info = {
		branch = "HEAD",
		upstream = nil,
		ahead = 0,
		behind = 0,
	}
	if lines[1] then
		branch_info = parse_git_branch(lines[1])
	end

	local counts = {
		local_changes = 0,
		staged = 0,
		remote = 0,
	}
	local seen = {}

	for idx = 2, #lines do
		local line = lines[idx]
		if line ~= "" then
			local relpath = line:sub(4)
			if not seen[relpath] then
				seen[relpath] = true
				counts.local_changes = counts.local_changes + 1
			end
			local index = line:sub(1, 1)
			if index ~= " " and index ~= "?" then
				counts.staged = counts.staged + 1
			end
		end
	end

	return branch_info, counts
end

local function git_kind_from_char(char, fallback)
	local map = {
		M = "modified",
		A = "added",
		D = "deleted",
		R = "renamed",
		C = "renamed",
		T = "modified",
		U = "conflict",
		["?"] = "untracked",
		["!"] = "conflict",
	}
	return map[char] or fallback or "modified"
end

local function git_sort_weight(item)
	local map = {
		conflict = 1,
		deleted = 2,
		modified = 3,
		renamed = 4,
		added = 5,
		untracked = 6,
		remote = 7,
	}
	return map[item.extra.change_kind] or 99
end

local function sort_items(items, sort_key)
	table.sort(items, function(a, b)
		if sort_key == "status" then
			local aw = git_sort_weight(a)
			local bw = git_sort_weight(b)
			if aw ~= bw then
				return aw < bw
			end
			return a.extra.relpath < b.extra.relpath
		end
		if sort_key == "name" then
			local an = vim.fs.basename(a.extra.relpath)
			local bn = vim.fs.basename(b.extra.relpath)
			if an ~= bn then
				return an < bn
			end
		end
		return a.extra.relpath < b.extra.relpath
	end)
end

local function make_file_item(repo, section, opts)
	return {
		id = string.format("%s::%s::%s::%s", repo.root, section, opts.relpath, opts.status or opts.change_kind),
		type = "file",
		name = opts.display_name or opts.relpath,
		path = opts.path,
		extra = {
			repo_root = repo.root,
			vcs = repo.vcs,
			relpath = opts.relpath,
			change_kind = opts.change_kind,
			status = opts.status,
			section = section,
			deleted = opts.deleted or false,
			renamed_from = opts.renamed_from,
		},
	}
end

local function build_git_sync(branch_info, counts, fetch_error)
	if fetch_error then
		return sync_badge("!", "error", "DiagnosticError")
	end
	if
		not branch_info.upstream
		and branch_info.branch
		and branch_info.branch ~= ""
		and branch_info.branch ~= "HEAD"
	then
		return sync_badge("Publish", "publish", "DiagnosticInfo")
	end
	if branch_info.behind > 0 and branch_info.ahead > 0 then
		return sync_badge(
			string.format("%d↓ %d↑", branch_info.behind, branch_info.ahead),
			"diverged",
			"DiagnosticWarn"
		)
	end
	if branch_info.behind > 0 then
		return sync_badge(string.format("%d↓", branch_info.behind), "incoming", "DiagnosticInfo")
	end
	if branch_info.ahead > 0 then
		return sync_badge(string.format("%d↑", branch_info.ahead), "outgoing", "DiagnosticHint")
	end
	if counts.local_changes > 0 then
		return sync_badge("", "dirty", "Comment")
	end
	return sync_badge("", "synced", "Comment")
end

local function build_git_summary(repo, opts, status_stdout, fetch_error)
	opts = opts or {}
	local previous = opts.previous or {}
	local branch_info, counts = parse_git_summary(util.split_lines(status_stdout))

	return apply_repo_job({
		root = repo.root,
		name = repo.name,
		vcs = repo.vcs,
		order = repo.order,
		relpath = repo.relpath,
		path_label = repo.path_label,
		branch = branch_info.branch,
		upstream = branch_info.upstream,
		sections = previous.sections or {},
		counts = counts,
		sync = vim.tbl_extend("force", build_git_sync(branch_info, counts, fetch_error), {
			ahead = branch_info.ahead,
			behind = branch_info.behind,
			fetch_error = fetch_error,
		}),
		error = nil,
		summary_loaded = true,
		details_loaded = previous.details_loaded or false,
		loading_details = false,
		loading_summary = false,
	})
end

local function git_summary(repo, opts)
	opts = opts or {}
	local lines, branch_err = util.system_lines(
		{ "git", "status", "--branch", "--porcelain=v1", "--untracked-files=all", "--ignored=no" },
		{ cwd = repo.root }
	)
	if not lines then
		return nil, branch_err
	end

	local branch_info, counts = parse_git_summary(lines)
	local status_stdout = table.concat(lines, "\n") .. "\n"
	local fetch_error
	if opts.remote_refresh and branch_info.upstream then
		local remotes = util.system_lines({ "git", "remote" }, { cwd = repo.root })
		if remotes and #remotes > 0 then
			local _, err = util.system({ "git", "fetch", "--all", "--prune", "--quiet" }, { cwd = repo.root })
			fetch_error = err
			local refreshed = util.system_lines(
				{ "git", "status", "--branch", "--porcelain=v1", "--untracked-files=all", "--ignored=no" },
				{ cwd = repo.root }
			)
			if refreshed and refreshed[1] then
				branch_info, counts = parse_git_summary(refreshed)
				status_stdout = table.concat(refreshed, "\n") .. "\n"
			end
		end
	end

	return build_git_summary(repo, opts, status_stdout, fetch_error)
end

local function parse_git_entries(root, raw, sort_key)
	local sections = {
		merge = { id = "merge", label = "Merge Changes", items = {} },
		staged = { id = "staged", label = "Staged Changes", items = {} },
		changes = { id = "changes", label = "Changes", items = {} },
		untracked = { id = "untracked", label = "Untracked Changes", items = {} },
	}
	local counts = {
		local_changes = 0,
		staged = 0,
		remote = 0,
	}

	local items = vim.split(raw or "", "\0", { plain = true, trimempty = true })
	local seen = {}
	local idx = 1

	while idx <= #items do
		local entry = items[idx]
		local status = entry:sub(1, 2)
		local index = status:sub(1, 1)
		local worktree = status:sub(2, 2)
		local relpath = entry:sub(4)
		local renamed_from

		if status:find("R", 1, true) or status:find("C", 1, true) then
			renamed_from = items[idx + 1]
			idx = idx + 1
		end

		if not seen[relpath] then
			seen[relpath] = true
			counts.local_changes = counts.local_changes + 1
		end

		local abs_path = normalize(join(root, relpath))
		if status == "??" then
			sections.untracked.items[#sections.untracked.items + 1] = make_file_item(
				{ root = root, vcs = "git" },
				"untracked",
				{
					path = abs_path,
					relpath = relpath,
					status = status,
					change_kind = "untracked",
				}
			)
		elseif index == "U" or worktree == "U" or status == "AA" or status == "DD" then
			sections.merge.items[#sections.merge.items + 1] = make_file_item({ root = root, vcs = "git" }, "merge", {
				path = abs_path,
				relpath = relpath,
				status = status,
				change_kind = "conflict",
				display_name = renamed_from and string.format("%s <- %s", relpath, renamed_from) or relpath,
				renamed_from = renamed_from,
			})
		else
			if index ~= " " and index ~= "?" then
				counts.staged = counts.staged + 1
				sections.staged.items[#sections.staged.items + 1] = make_file_item(
					{ root = root, vcs = "git" },
					"staged",
					{
						path = abs_path,
						relpath = relpath,
						status = index .. " ",
						change_kind = git_kind_from_char(index, "modified"),
						deleted = index == "D" and not file_exists(abs_path),
						display_name = renamed_from and string.format("%s <- %s", relpath, renamed_from) or relpath,
						renamed_from = renamed_from,
					}
				)
			end

			if worktree ~= " " then
				sections.changes.items[#sections.changes.items + 1] = make_file_item(
					{ root = root, vcs = "git" },
					"changes",
					{
						path = abs_path,
						relpath = relpath,
						status = " " .. worktree,
						change_kind = git_kind_from_char(worktree, "modified"),
						deleted = worktree == "D" and not file_exists(abs_path),
						display_name = renamed_from and string.format("%s <- %s", relpath, renamed_from) or relpath,
						renamed_from = renamed_from,
					}
				)
			end
		end

		idx = idx + 1
	end

	local ordered = {}
	for _, id in ipairs({ "merge", "staged", "changes", "untracked" }) do
		if #sections[id].items > 0 then
			sort_items(sections[id].items, sort_key)
			ordered[#ordered + 1] = sections[id]
		end
	end

	return ordered, counts
end

local function build_git_detail(repo, opts, status_stdout, raw_stdout)
	opts = opts or {}
	local summary = build_git_summary(repo, opts, status_stdout, nil)
	local sort_key = opts.changes_sort or config.get().source_control.changes_sort
	local sections, counts = parse_git_entries(repo.root, raw_stdout, sort_key)
	summary.sections = sections
	summary.counts = counts
	summary.sync = vim.tbl_extend(
		"force",
		build_git_sync({
			ahead = summary.sync.ahead or 0,
			behind = summary.sync.behind or 0,
			upstream = summary.upstream,
			branch = summary.branch,
		}, counts, summary.sync.fetch_error),
		{
			ahead = summary.sync.ahead or 0,
			behind = summary.sync.behind or 0,
			fetch_error = summary.sync.fetch_error,
		}
	)
	summary.details_loaded = true
	summary.loading_details = false
	return apply_repo_job(summary)
end

local function git_detail(repo, opts)
	opts = opts or {}
	local status, status_err = util.system(
		{ "git", "status", "--branch", "--porcelain=v1", "--untracked-files=all", "--ignored=no" },
		{ cwd = repo.root }
	)
	if not status then
		return nil, status_err
	end

	local raw_files, file_err = util.system(
		{ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no" },
		{ cwd = repo.root }
	)
	if not raw_files then
		return nil, file_err
	end

	return build_git_detail(repo, opts, status.stdout, raw_files.stdout)
end

local function build_svn_sync(counts)
	if counts.local_changes > 0 and counts.remote > 0 then
		return sync_badge(
			string.format("%d↓ %d↑", counts.remote, counts.local_changes),
			"diverged",
			"DiagnosticWarn"
		)
	elseif counts.remote > 0 then
		return sync_badge(string.format("%d↓", counts.remote), "incoming", "DiagnosticInfo")
	elseif counts.local_changes > 0 then
		return sync_badge(string.format("%d↑", counts.local_changes), "outgoing", "DiagnosticHint")
	end
	return sync_badge("", "synced", "Comment")
end

local function build_svn_summary(repo, opts, status_stdout, info_stdout)
	opts = opts or {}
	local previous = opts.previous or {}
	local entries = parse_svn_status_xml(status_stdout)

	local counts = {
		local_changes = 0,
		staged = 0,
		remote = previous.counts and previous.counts.remote or 0,
	}

	local remote_count = 0
	for _, entry in ipairs(entries) do
		if entry.wc_item ~= "external" then
			if entry.wc_item ~= "normal" then
				counts.local_changes = counts.local_changes + 1
			end
			if opts.remote_refresh and entry.repos_item == "modified" then
				remote_count = remote_count + 1
			end
		end
	end
	counts.remote = opts.remote_refresh and remote_count or counts.remote

	return apply_repo_job({
		root = repo.root,
		name = repo.name,
		vcs = repo.vcs,
		order = repo.order,
		relpath = repo.relpath,
		path_label = repo.path_label,
		branch = svn_branch_from_info(info_stdout),
		sections = previous.sections or {},
		counts = counts,
		sync = build_svn_sync(counts),
		error = nil,
		summary_loaded = true,
		details_loaded = previous.details_loaded or false,
		loading_details = false,
		loading_summary = false,
	})
end

local function svn_summary(repo, opts)
	opts = opts or {}
	local args = { "svn", "status", "--xml" }
	if opts.remote_refresh then
		args[#args + 1] = "-u"
	end
	args[#args + 1] = repo.root

	local result, err = util.system(args, { cwd = repo.root })
	if not result then
		return nil, err
	end
	local info = util.system({ "svn", "info", "--xml", repo.root }, { cwd = repo.root })
	return build_svn_summary(repo, opts, result.stdout, info and info.stdout or nil)
end

local function build_svn_detail(repo, opts, status_stdout, info_stdout)
	opts = opts or {}
	local previous = opts.previous or {}
	local entries = parse_svn_status_xml(status_stdout)

	local sections = {
		changes = { id = "changes", label = "Changes", items = {} },
		untracked = { id = "untracked", label = "Unversioned", items = {} },
		remote = { id = "remote", label = "Remote Changes", items = {} },
	}
	local counts = {
		local_changes = 0,
		staged = 0,
		remote = previous.counts and previous.counts.remote or 0,
	}
	local remote_count = 0
	for _, entry in ipairs(entries) do
		if entry.wc_item ~= "external" then
			local abs_path, relpath = resolve_svn_entry_path(repo.root, entry.path)
			local kind = ({
				modified = "modified",
				added = "added",
				deleted = "deleted",
				replaced = "renamed",
				unversioned = "untracked",
				missing = "deleted",
				obstructed = "conflict",
				conflicted = "conflict",
				incomplete = "conflict",
			})[entry.wc_item]
			if entry.wc_item ~= "normal" and kind then
				local section_id = entry.wc_item == "unversioned" and "untracked" or "changes"
				sections[section_id].items[#sections[section_id].items + 1] = make_file_item(
					{ root = repo.root, vcs = "svn" },
					section_id,
					{
						path = abs_path,
						relpath = relpath,
						status = entry.wc_item,
						change_kind = kind,
						deleted = kind == "deleted" and not file_exists(abs_path),
					}
				)
				counts.local_changes = counts.local_changes + 1
			end
			if opts.remote_refresh and entry.repos_item == "modified" then
				if entry.wc_item == "normal" then
					sections.remote.items[#sections.remote.items + 1] = make_file_item(
						{ root = repo.root, vcs = "svn" },
						"remote",
						{
							path = abs_path,
							relpath = relpath,
							status = "*",
							change_kind = "remote",
						}
					)
				end
				remote_count = remote_count + 1
			end
		end
	end

	counts.remote = opts.remote_refresh and remote_count or counts.remote
	local sort_key = opts.changes_sort or config.get().source_control.changes_sort
	local ordered = {}
	for _, id in ipairs({ "changes", "untracked", "remote" }) do
		if #sections[id].items > 0 then
			sort_items(sections[id].items, sort_key)
			ordered[#ordered + 1] = sections[id]
		end
	end

	return apply_repo_job({
		root = repo.root,
		name = repo.name,
		vcs = repo.vcs,
		order = repo.order,
		relpath = repo.relpath,
		path_label = repo.path_label,
		branch = svn_branch_from_info(info_stdout),
		sections = ordered,
		counts = counts,
		sync = build_svn_sync(counts),
		error = nil,
		summary_loaded = true,
		details_loaded = true,
		loading_details = false,
	})
end

local function svn_detail(repo, opts)
	opts = opts or {}
	local args = { "svn", "status", "--xml" }
	if opts.remote_refresh then
		args[#args + 1] = "-u"
	end
	args[#args + 1] = repo.root

	local result, err = util.system(args, { cwd = repo.root })
	if not result then
		return nil, err
	end
	local info = util.system({ "svn", "info", "--xml", repo.root }, { cwd = repo.root })
	return build_svn_detail(repo, opts, result.stdout, info and info.stdout or nil)
end

local function mark_node_disabled(node, disabled, busy_label)
	if not disabled or type(node) ~= "table" then
		return node
	end
	node.extra = node.extra or {}
	node.extra.disabled = true
	node.extra.busy_label = busy_label
	for _, child in ipairs(node.children or {}) do
		mark_node_disabled(child, true, busy_label)
	end
	return node
end

function M.load_repo_summary(repo, opts)
	if repo.vcs == "git" then
		return git_summary(repo, opts)
	end
	return svn_summary(repo, opts)
end

function M.load_repo_details(repo, opts)
	if repo.vcs == "git" then
		return git_detail(repo, opts)
	end
	return svn_detail(repo, opts)
end

function M.load_repo_summary_async(repo, opts, run_command, on_done)
	opts = opts or {}
	if repo.vcs == "git" then
		run_command(
			{ "git", "status", "--branch", "--porcelain=v1", "--untracked-files=all", "--ignored=no" },
			{ kind = "summary", timeout_ms = opts.status_timeout_ms },
			function(status, status_err)
				if not status then
					return on_done(nil, status_err)
				end
				local branch_info = parse_git_summary(util.split_lines(status.stdout))
				if not (opts.remote_refresh and branch_info.upstream) then
					return on_done(build_git_summary(repo, opts, status.stdout, nil))
				end
				run_command(
					{ "git", "remote" },
					{ kind = "remote", timeout_ms = opts.status_timeout_ms },
					function(remotes)
						if not remotes or #util.split_lines(remotes.stdout) == 0 then
							return on_done(build_git_summary(repo, opts, status.stdout, nil))
						end
						run_command(
							{ "git", "fetch", "--all", "--prune", "--quiet" },
							{ kind = "remote", timeout_ms = opts.remote_timeout_ms },
							function(_, fetch_err)
								run_command({
									"git",
									"status",
									"--branch",
									"--porcelain=v1",
									"--untracked-files=all",
									"--ignored=no",
								}, { kind = "summary", timeout_ms = opts.status_timeout_ms }, function(
									refreshed
								)
									on_done(
										build_git_summary(
											repo,
											opts,
											refreshed and refreshed.stdout or status.stdout,
											fetch_err
										)
									)
								end)
							end
						)
					end
				)
			end
		)
		return
	end

	local args = { "svn", "status", "--xml" }
	if opts.remote_refresh then
		args[#args + 1] = "-u"
	end
	args[#args + 1] = repo.root
	run_command(args, {
		kind = opts.remote_refresh and "remote" or "summary",
		timeout_ms = opts.remote_refresh and opts.remote_timeout_ms or opts.status_timeout_ms,
	}, function(status, status_err)
		if not status then
			return on_done(nil, status_err)
		end
		run_command(
			{ "svn", "info", "--xml", repo.root },
			{ kind = "summary", timeout_ms = opts.status_timeout_ms },
			function(info)
				on_done(build_svn_summary(repo, opts, status.stdout, info and info.stdout or nil))
			end
		)
	end)
end

function M.load_repo_details_async(repo, opts, run_command, on_done)
	opts = opts or {}
	if repo.vcs == "git" then
		run_command(
			{ "git", "status", "--branch", "--porcelain=v1", "--untracked-files=all", "--ignored=no" },
			{ kind = "details", timeout_ms = opts.status_timeout_ms },
			function(status, status_err)
				if not status then
					return on_done(nil, status_err)
				end
				run_command(
					{ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=no" },
					{ kind = "details", timeout_ms = opts.status_timeout_ms },
					function(files, files_err)
						if not files then
							return on_done(nil, files_err)
						end
						on_done(build_git_detail(repo, opts, status.stdout, files.stdout))
					end
				)
			end
		)
		return
	end

	local args = { "svn", "status", "--xml" }
	if opts.remote_refresh then
		args[#args + 1] = "-u"
	end
	args[#args + 1] = repo.root
	run_command(args, {
		kind = opts.remote_refresh and "remote" or "details",
		timeout_ms = opts.remote_refresh and opts.remote_timeout_ms or opts.status_timeout_ms,
	}, function(status, status_err)
		if not status then
			return on_done(nil, status_err)
		end
		run_command(
			{ "svn", "info", "--xml", repo.root },
			{ kind = "details", timeout_ms = opts.status_timeout_ms },
			function(info)
				on_done(build_svn_detail(repo, opts, status.stdout, info and info.stdout or nil))
			end
		)
	end)
end

local function repo_visible(repo, show_clean)
	if show_clean then
		return true
	end
	if not repo.summary_loaded then
		return true
	end
	return repo.sync.status == "error"
		or repo.sync.status == "incoming"
		or repo.sync.status == "outgoing"
		or repo.sync.status == "diverged"
		or repo.sync.status == "publish"
		or repo.counts.local_changes > 0
		or repo.counts.remote > 0
end

local function first_interesting_repo(repos, show_clean)
	for _, repo in ipairs(repos) do
		if repo_visible(repo, show_clean) then
			return repo.root
		end
	end
	return repos[1] and repos[1].root or nil
end

local function ordered_repositories(repos, sort_key)
	table.sort(repos, function(a, b)
		if sort_key == "name" then
			if a.name ~= b.name then
				return a.name < b.name
			end
			return a.root < b.root
		end
		if sort_key == "path" then
			return a.root < b.root
		end
		return (a.order or 0) < (b.order or 0)
	end)
	return repos
end

local function branch_label(repo)
	if repo.vcs == "git" and repo.branch and repo.branch ~= "" then
		return " " .. repo.branch
	end
	if repo.vcs == "svn" then
		if repo.branch and repo.branch ~= "" and repo.branch ~= "svn" then
			return "svn " .. repo.branch
		end
		return "svn"
	end
	return ""
end

local function primary_action(repo)
	if repo.job and repo.job.status == "running" then
		return { label = repo.job.label or "Working...", action = repo.job.action or "busy" }
	end
	if repo.vcs == "svn" then
		if repo.counts.remote > 0 then
			return { label = "Update", action = "update" }
		end
		return { label = "Commit", action = "commit" }
	end
	if repo.sync.status == "publish" then
		return { label = "Publish Branch", action = "push" }
	end
	if repo.sync.status == "incoming" or repo.sync.status == "outgoing" or repo.sync.status == "diverged" then
		return { label = "Sync Changes", action = "sync" }
	end
	return { label = "Commit", action = "commit" }
end

local function folder_tree_from_items(repo, section, items, compact)
	local root = { name = "", path = "", folders = {}, files = {} }

	for _, item in ipairs(items) do
		local relpath = item.extra.relpath
		local segments = vim.split(relpath, "/", { plain = true })
		local cursor = root
		local current_path = {}
		for idx = 1, #segments - 1 do
			current_path[#current_path + 1] = segments[idx]
			local key = table.concat(current_path, "/")
			cursor.folders[key] = cursor.folders[key]
				or {
					name = segments[idx],
					path = key,
					folders = {},
					files = {},
				}
			cursor = cursor.folders[key]
		end
		cursor.files[#cursor.files + 1] = item
	end

	local function render_folder(node)
		local label = node.name
		local current = node
		if compact then
			while vim.tbl_count(current.folders) == 1 and #current.files == 0 do
				local _, only = next(current.folders)
				if not only then
					break
				end
				label = label .. "/" .. only.name
				current = only
			end
		end

		local children = {}
		local folders = vim.tbl_values(current.folders)
		table.sort(folders, function(a, b)
			return a.path < b.path
		end)
		for _, folder in ipairs(folders) do
			children[#children + 1] = render_folder(folder)
		end
		for _, file in ipairs(current.files) do
			children[#children + 1] = file
		end

		return {
			id = folder_node_id(repo.root, section.id, current.path),
			type = "folder",
			name = label,
			loaded = true,
			children = children,
			extra = {
				repo_root = repo.root,
				section = section.id,
			},
		}
	end

	local nodes = {}
	local folders = vim.tbl_values(root.folders)
	table.sort(folders, function(a, b)
		return a.path < b.path
	end)
	for _, folder in ipairs(folders) do
		nodes[#nodes + 1] = render_folder(folder)
	end
	for _, file in ipairs(root.files) do
		nodes[#nodes + 1] = file
	end
	return nodes
end

local function make_section_node(repo, section, source_opts)
	local items = vim.deepcopy(section.items)
	sort_items(items, source_opts.changes_sort)
	local children = source_opts.changes_view_mode == "tree"
			and folder_tree_from_items(repo, section, items, source_opts.compact_folders)
		or items

	return {
		id = section_node_id(repo.root, section.id),
		type = "section",
		name = string.format("%s (%d)", section.label, #section.items),
		loaded = true,
		children = children,
		extra = {
			repo_root = repo.root,
			section_id = section.id,
		},
	}
end

local function make_repo_change_children(repo, source_opts)
	local draft = repo.draft ~= "" and repo.draft or ""
	local placeholder = "Commit message"
	local primary = primary_action(repo)
	local disabled = repo.job and repo.job.status == "running"
	local children = {
		{
			id = repo.root .. "::commit",
			type = "commit_input",
			name = draft ~= "" and draft or placeholder,
			extra = {
				repo_root = repo.root,
				placeholder = placeholder,
				draft = draft,
				primary_label = primary.label,
				show_input_action_button = source_opts.show_input_action_button,
				disabled = disabled,
				busy_label = primary.label,
			},
		},
	}

	if source_opts.show_action_button then
		children[#children + 1] = {
			id = repo.root .. "::action",
			type = "action_button",
			name = primary.label,
			extra = {
				repo_root = repo.root,
				action = primary.action,
				label = primary.label,
				disabled = disabled,
				busy_label = primary.label,
			},
		}
	end

	if repo.details_loaded then
		if #repo.sections == 0 then
			children[#children + 1] = {
				id = repo.root .. "::clean",
				type = "message",
				name = "No changes",
				extra = {
					repo_root = repo.root,
					disabled = disabled,
					busy_label = primary.label,
				},
			}
			return children
		end
		for _, section in ipairs(repo.sections) do
			children[#children + 1] =
				mark_node_disabled(make_section_node(repo, section, source_opts), disabled, primary.label)
		end
		return children
	end

	local message
	if disabled then
		message = primary.label
	elseif repo.loading_details then
		message = "Loading changes..."
	elseif not repo.summary_loaded then
		message = "Loading repository status..."
	elseif repo.counts.local_changes == 0 and repo.counts.remote == 0 then
		message = "Working tree clean"
	else
		message = "Press <CR> to load changes"
	end

	children[#children + 1] = {
		id = repo.root .. "::loading",
		type = "message",
		name = message,
		extra = {
			repo_root = repo.root,
			disabled = disabled,
			busy_label = primary.label,
		},
	}
	return children
end

local function normalize_visibility_state(state, repos, source_opts)
	local available = {}
	for _, repo in ipairs(repos) do
		available[repo.root] = true
	end

	state.lazyvcs_repo_visibility = state.lazyvcs_repo_visibility or {}
	for root, _ in pairs(vim.deepcopy(state.lazyvcs_repo_visibility)) do
		if not available[root] then
			state.lazyvcs_repo_visibility[root] = nil
		end
	end

	if state.lazyvcs_focused_repo and not available[state.lazyvcs_focused_repo] then
		state.lazyvcs_focused_repo = nil
	end

	if state.lazyvcs_selection_mode == "single" then
		local focused = state.lazyvcs_focused_repo or first_interesting_repo(repos, state.lazyvcs_show_clean)
		state.lazyvcs_focused_repo = focused
		state.lazyvcs_repo_visibility = {}
		if focused then
			state.lazyvcs_repo_visibility[focused] = true
		end
		return
	end

	local has_visible = false
	for root, enabled in pairs(state.lazyvcs_repo_visibility) do
		if enabled and available[root] then
			has_visible = true
			break
		end
	end

	if not has_visible then
		for _, repo in ipairs(repos) do
			if repo_visible(repo, state.lazyvcs_show_clean) then
				state.lazyvcs_repo_visibility[repo.root] = true
				has_visible = true
			end
		end
	end

	if not has_visible then
		local fallback = first_interesting_repo(repos, true)
		if fallback then
			state.lazyvcs_repo_visibility[fallback] = true
		end
	end

	if not state.lazyvcs_focused_repo then
		for _, repo in ipairs(repos) do
			if state.lazyvcs_repo_visibility[repo.root] then
				state.lazyvcs_focused_repo = repo.root
				break
			end
		end
	end

	if not state.lazyvcs_focused_repo and repos[1] then
		state.lazyvcs_focused_repo = repos[1].root
	end
end

local function make_repo_selector_node(repo, state)
	return {
		id = M.repo_selector_id(repo.root),
		path = repo.root,
		type = "repo_selector",
		name = repo.name,
		loaded = true,
		extra = {
			repo_root = repo.root,
			vcs = repo.vcs,
			branch = branch_label(repo),
			sync = repo.sync,
			counts = repo.counts,
			path_label = repo.path_label,
			visible = state.lazyvcs_repo_visibility[repo.root] == true,
			focused = state.lazyvcs_focused_repo == repo.root,
			disabled = repo.job and repo.job.status == "running",
			refreshing_summary = repo.refreshing_summary,
		},
	}
end

local function make_repo_changes_node(repo, source_opts)
	return {
		id = M.repo_changes_id(repo.root),
		path = repo.root,
		type = "repo_changes",
		name = repo.name,
		loaded = true,
		children = make_repo_change_children(repo, source_opts),
		extra = {
			repo_root = repo.root,
			vcs = repo.vcs,
			branch = branch_label(repo),
			sync = repo.sync,
			counts = repo.counts,
			path_label = repo.path_label,
			disabled = repo.job and repo.job.status == "running",
			refreshing_summary = repo.refreshing_summary,
		},
	}
end

function M.collect(state, opts)
	opts = opts or {}
	local source_opts = vim.tbl_extend("force", config.get().source_control, {
		show_clean = state.lazyvcs_show_clean,
		selection_mode = state.lazyvcs_selection_mode,
		changes_view_mode = state.lazyvcs_changes_view_mode,
		changes_sort = state.lazyvcs_changes_sort,
	})
	local root = normalize(opts.root or state.path or vim.fn.getcwd())
	local repo_specs = state.lazyvcs_repo_specs or M.discover(root, opts.scan_depth or source_opts.scan_depth)
	local repo_cache = state.lazyvcs_repo_cache or {}
	local drafts = state.lazyvcs_commit_drafts or {}

	state.lazyvcs_repo_specs = repo_specs
	state.lazyvcs_repo_cache = repo_cache

	local loaded = {}
	for _, spec in ipairs(repo_specs) do
		local status = apply_repo_job(repo_cache[spec.root] or placeholder_status(spec))
		if status.loading_summary and status.summary_loaded then
			status.refreshing_summary = true
		elseif status.loading_summary then
			status.sync = sync_badge("…", "loading", "LazyVcsBusy")
			status.refreshing_summary = false
		end
		status.draft = drafts[spec.root] or ""
		status.order = spec.order
		status.relpath = spec.relpath
		status.path_label = spec.path_label
		loaded[#loaded + 1] = status
	end

	state.lazyvcs_show_clean = state.lazyvcs_show_clean == nil and source_opts.show_clean or state.lazyvcs_show_clean
	state.lazyvcs_selection_mode = state.lazyvcs_selection_mode or source_opts.selection_mode
	state.lazyvcs_changes_view_mode = state.lazyvcs_changes_view_mode or source_opts.changes_view_mode
	state.lazyvcs_changes_sort = state.lazyvcs_changes_sort or source_opts.changes_sort
	source_opts.show_clean = state.lazyvcs_show_clean
	source_opts.selection_mode = state.lazyvcs_selection_mode
	source_opts.changes_view_mode = state.lazyvcs_changes_view_mode
	source_opts.changes_sort = state.lazyvcs_changes_sort

	ordered_repositories(loaded, source_opts.repositories_sort)
	normalize_visibility_state(state, loaded, source_opts)

	local repo_selector_nodes = {}
	for _, repo in ipairs(loaded) do
		repo_cache[repo.root] = repo
		repo_selector_nodes[#repo_selector_nodes + 1] = make_repo_selector_node(repo, state)
	end

	local change_nodes = {}
	for _, repo in ipairs(loaded) do
		if state.lazyvcs_repo_visibility[repo.root] then
			change_nodes[#change_nodes + 1] = make_repo_changes_node(repo, source_opts)
		end
	end

	if #change_nodes == 0 then
		change_nodes[#change_nodes + 1] = {
			id = root .. "::changes::empty",
			type = "message",
			name = "No repositories selected",
			extra = {},
		}
	end

	local children = {}
	local hydration_extra = {
		hydration_active = state.lazyvcs_hydration_active == true,
		hydration_pending = state.lazyvcs_hydration_pending or 0,
	}
	if #repo_specs > 1 or source_opts.always_show_repositories then
		children[#children + 1] = {
			id = root .. "::repositories",
			type = "view_section",
			name = string.format("Repositories (%d)", #repo_selector_nodes),
			loaded = true,
			children = repo_selector_nodes,
			extra = { section = "repositories" },
		}
	end

	children[#children + 1] = {
		id = root .. "::changes",
		type = "view_section",
		name = string.format("Changes (%d)", #change_nodes),
		loaded = true,
		children = change_nodes,
		extra = { section = "changes" },
	}

	return {
		id = root,
		path = root,
		type = "root",
		name = "Source Control for " .. root,
		loaded = true,
		children = children,
		extra = vim.tbl_extend("force", { repo_count = #repo_selector_nodes }, hydration_extra),
	}
end

return M
