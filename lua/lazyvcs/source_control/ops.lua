local ai = require("lazyvcs.source_control.ai")
local config = require("lazyvcs.config")
local input = require("lazyvcs.source_control.input")
local jobs = require("lazyvcs.source_control.jobs")
local model = require("lazyvcs.source_control.model")
local persist = require("lazyvcs.source_control.persist")
local repo_switch = require("lazyvcs.source_control.switch")
local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")
local session_state = require("lazyvcs.state")
local util = require("lazyvcs.util")

local M = {}

local function file_exists(path)
	return vim.uv.fs_stat(path) ~= nil
end

local function current_node(state)
	return state.tree and state.tree:get_node() or nil
end

local function active_session_for_tab()
	local tabpage = vim.api.nvim_get_current_tabpage()
	for _, session in pairs(session_state.sessions) do
		if
			util.win_is_valid(session.editable_win)
			and vim.api.nvim_win_get_tabpage(session.editable_win) == tabpage
		then
			return session
		end
	end
	return nil
end

local function serialize_state(state)
	local visible = {}
	for root, enabled in pairs(state.lazyvcs_repo_visibility or {}) do
		if enabled then
			visible[#visible + 1] = root
		end
	end
	table.sort(visible)

	return {
		visible_repos = visible,
		focused_repo = state.lazyvcs_focused_repo,
		show_clean = state.lazyvcs_show_clean,
		selection_mode = state.lazyvcs_selection_mode,
		changes_view_mode = state.lazyvcs_changes_view_mode,
		changes_sort = state.lazyvcs_changes_sort,
	}
end

local function save_state(state)
	if state.path and state.path ~= "" then
		persist.save(state.path, serialize_state(state))
	end
end

local function current_repo(state, node)
	node = node or current_node(state)
	if not node then
		return nil
	end
	local repo_root = node.extra and node.extra.repo_root or node.path or node:get_id()
	return state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[repo_root] or nil
end

local function restart_source(state, remote_refresh)
	state.lazyvcs_repo_cache = {}
	state.lazyvcs_loading_details = {}
	state.lazyvcs_hydration_active = false
	state.lazyvcs_hydration_generation = (state.lazyvcs_hydration_generation or 0) + 1
	local generation = state.lazyvcs_hydration_generation
	jobs.cancel(function(job)
		return job.scope == "hydration" and job.generation and job.generation < generation
	end)
	state.lazyvcs_remote_refresh = remote_refresh ~= false
	save_state(state)
	manager.navigate(state, state.path, nil, nil, false)
end

local function navigate_if_visible(state)
	if state.path and renderer.window_exists(state) then
		manager.navigate(state, state.path, nil, nil, false)
	end
end

local function invalidate_repo(state, repo_root, remote_refresh)
	state.lazyvcs_repo_cache = state.lazyvcs_repo_cache or {}
	state.lazyvcs_repo_cache[repo_root] = nil
	state.lazyvcs_loading_details = state.lazyvcs_loading_details or {}
	state.lazyvcs_loading_details[repo_root] = nil
	state.lazyvcs_hydration_active = false
	state.lazyvcs_hydration_generation = (state.lazyvcs_hydration_generation or 0) + 1
	local generation = state.lazyvcs_hydration_generation
	jobs.cancel(function(job)
		return job.scope == "hydration" and job.generation and job.generation < generation
	end)
	state.lazyvcs_hydration_queue = nil
	state.lazyvcs_hydration_remote = nil
	state.lazyvcs_remote_refresh = remote_refresh ~= false
	save_state(state)
end

local function refresh_repo(state, repo_root, remote_refresh)
	invalidate_repo(state, repo_root, remote_refresh)
	navigate_if_visible(state)
end

local function run(args, opts)
	local result, err = util.system(args, opts)
	if not result then
		util.notify(err, vim.log.levels.ERROR)
		return nil, err
	end
	return result
end

local function stage_all(repo)
	if repo.vcs ~= "git" then
		return nil, "Stage all is only supported for Git"
	end
	return run({ "git", "add", "-A" }, { cwd = repo.root })
end

local function close_sessions_for_repo(repo_root)
	local actions = require("lazyvcs.actions")
	for _, session in ipairs(session_state.list()) do
		if session.root == repo_root then
			actions.close(session.editable_bufnr)
		end
	end
end

local function current_repo_job(repo_root)
	return session_state.get_repo_job(repo_root)
end

local function repo_is_busy(repo_root)
	local job = current_repo_job(repo_root)
	return job and job.status == "running", job
end

local function notify_repo_busy(repo, job)
	util.notify((job and job.label or "Repository action") .. " already running for " .. repo.name, vim.log.levels.INFO)
end

local function clear_repo_job_errors(repo_root)
	session_state.clear_repo_job_errors(repo_root)
end

local function set_repo_job(state, repo_root, job)
	session_state.set_repo_job(repo_root, job)
	navigate_if_visible(state)
end

local function finish_repo_job(state, repo, spec, result, err)
	if err then
		session_state.set_repo_job(repo.root, {
			status = "error",
			action = spec.action,
			label = spec.label,
			sync_text = spec.sync_text,
			error = err,
		})
		invalidate_repo(state, repo.root, false)
		navigate_if_visible(state)
		util.notify(err, vim.log.levels.ERROR)
		return
	end

	session_state.clear_repo_job(repo.root)
	if spec.clear_draft then
		state.lazyvcs_commit_drafts[repo.root] = ""
	end
	if spec.checktime then
		vim.cmd("silent! checktime")
	end
	if type(spec.after_success) == "function" then
		spec.after_success(result)
	end
	invalidate_repo(state, repo.root, spec.remote_refresh)
	navigate_if_visible(state)
end

local function start_repo_job(state, repo, spec)
	local busy, job = repo_is_busy(repo.root)
	if busy then
		notify_repo_busy(repo, job)
		return false
	end

	clear_repo_job_errors(repo.root)
	if spec.close_sessions then
		close_sessions_for_repo(repo.root)
	end

	set_repo_job(state, repo.root, {
		status = "running",
		action = spec.action,
		label = spec.label,
		sync_text = spec.sync_text or spec.label,
	})

	local ok, start_err = pcall(spec.start, function(result)
		finish_repo_job(state, repo, spec, result, nil)
	end, function(err)
		finish_repo_job(state, repo, spec, nil, err)
	end)
	if not ok then
		finish_repo_job(state, repo, spec, nil, tostring(start_err))
		return false
	end
	return true
end

local function start_command(args, cwd, on_done)
	local timeout = config.get().source_control.background.mutation_timeout_ms
	util.system_start(args, { cwd = cwd, timeout = timeout > 0 and timeout or nil }, function(result, err)
		on_done(result, err)
	end)
end

local function parse_git_branch_state(line)
	line = line or ""
	return {
		ahead = tonumber(line:match("ahead (%d+)") or "0") or 0,
		behind = tonumber(line:match("behind (%d+)") or "0") or 0,
		has_upstream = line:match("%.%.%.") ~= nil,
	}
end

local function parse_upstream(upstream)
	upstream = util.trim(upstream or "")
	local remote, branch = upstream:match("^([^/]+)/(.+)$")
	return remote, branch, upstream
end

local function start_git_status(repo, on_done)
	start_command(
		{ "git", "status", "--branch", "--porcelain=v1", "--untracked-files=no", "--ignored=no" },
		repo.root,
		function(status_result, status_err)
			if status_err then
				return on_done(nil, status_err)
			end

			local lines = util.split_lines(status_result.stdout)
			local branch_state = parse_git_branch_state(lines[1])
			on_done(branch_state, nil)
		end
	)
end

local function start_git_upstream(repo, on_done)
	start_command(
		{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" },
		repo.root,
		function(upstream, upstream_err)
			if upstream_err then
				return on_done(nil, upstream_err)
			end

			local remote, branch, full = parse_upstream(upstream.stdout)
			if not remote or not branch then
				return on_done(nil, "Unable to determine upstream branch for " .. repo.name)
			end
			on_done({
				remote = remote,
				branch = branch,
				full = full,
			}, nil)
		end
	)
end

local function start_git_fast_forward(repo, on_done)
	start_git_upstream(repo, function(upstream, upstream_err)
		if upstream_err then
			return on_done(nil, upstream_err)
		end

		start_command({ "git", "fetch", "--prune", "--quiet", upstream.remote }, repo.root, function(_, fetch_err)
			if fetch_err then
				return on_done(nil, fetch_err)
			end

			start_git_status(repo, function(branch_state, status_err)
				if status_err then
					return on_done(nil, status_err)
				end
				if branch_state.ahead > 0 and branch_state.behind > 0 then
					return on_done(
						nil,
						"Branch has both incoming and outgoing commits. Use explicit pull/push actions."
					)
				end
				if branch_state.behind == 0 then
					return on_done({ stdout = "" }, nil)
				end
				start_command({ "git", "merge", "--ff-only", upstream.full }, repo.root, on_done)
			end)
		end)
	end)
end

local function start_git_sync(repo, on_done)
	start_git_upstream(repo, function(upstream, upstream_err)
		if upstream_err then
			return start_command({ "git", "push", "--set-upstream", "origin", repo.branch }, repo.root, on_done)
		end

		start_command({ "git", "fetch", "--prune", "--quiet", upstream.remote }, repo.root, function(_, fetch_err)
			if fetch_err then
				return on_done(nil, fetch_err)
			end

			start_git_status(repo, function(branch_state, status_err)
				if status_err then
					return on_done(nil, status_err)
				end
				if branch_state.behind > 0 and branch_state.ahead > 0 then
					return on_done(
						nil,
						"Branch has both incoming and outgoing commits. Use explicit pull/push actions."
					)
				end
				if branch_state.behind > 0 then
					return start_command({ "git", "merge", "--ff-only", upstream.full }, repo.root, on_done)
				end
				if branch_state.ahead > 0 then
					return start_command(
						{ "git", "push", upstream.remote, repo.branch .. ":" .. upstream.branch },
						repo.root,
						on_done
					)
				end
				on_done({ stdout = "" }, nil)
			end)
		end)
	end)
end

local function ensure_repo_details(state, repo)
	if repo.details_loaded then
		return repo
	end
	if repo.loading_details then
		return repo
	end

	state.lazyvcs_loading_details = state.lazyvcs_loading_details or {}
	state.lazyvcs_loading_details[repo.root] = true
	state.lazyvcs_repo_cache[repo.root] = vim.tbl_extend("force", repo, { loading_details = true })
	navigate_if_visible(state)

	local generation = state.lazyvcs_hydration_generation or 0
	local bg = config.get().source_control.background
	model.load_repo_details_async(repo, {
		previous = repo,
		remote_refresh = false,
		changes_sort = state.lazyvcs_changes_sort or config.get().source_control.changes_sort,
		status_timeout_ms = bg.status_timeout_ms,
		remote_timeout_ms = bg.remote_timeout_ms,
	}, function(args, opts, on_done)
		jobs.command(repo, opts.kind, args, {
			timeout_ms = opts.timeout_ms,
			generation = generation,
			scope = "details",
			priority = 10,
		}, on_done)
	end, function(detail, err)
		if (state.lazyvcs_hydration_generation or 0) ~= generation then
			return
		end
		state.lazyvcs_loading_details[repo.root] = nil
		if detail then
			state.lazyvcs_repo_cache[repo.root] = detail
		else
			state.lazyvcs_repo_cache[repo.root] = model.make_error(repo, repo, err)
			util.notify(err, vim.log.levels.WARN)
		end
		navigate_if_visible(state)
	end)
	return state.lazyvcs_repo_cache[repo.root]
end

local function first_available_repo_root(state)
	for _, repo in ipairs(state.lazyvcs_repo_specs or {}) do
		return repo.root
	end
end

function M.refresh(state, remote_refresh)
	clear_repo_job_errors()
	restart_source(state, remote_refresh)
end

function M.toggle_show_clean(state)
	state.lazyvcs_show_clean = not state.lazyvcs_show_clean
	restart_source(state, false)
end

function M.toggle_changes_view_mode(state)
	state.lazyvcs_changes_view_mode = state.lazyvcs_changes_view_mode == "tree" and "list" or "tree"
	save_state(state)
	manager.navigate(state, state.path, nil, nil, false)
end

function M.cycle_changes_sort(state)
	local current = state.lazyvcs_changes_sort or config.get().source_control.changes_sort
	local order = { "path", "name", "status" }
	local next_index = 1
	for index, value in ipairs(order) do
		if value == current then
			next_index = (index % #order) + 1
			break
		end
	end
	state.lazyvcs_changes_sort = order[next_index]
	restart_source(state, false)
end

function M.edit_commit_message(state, node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end

	input.open(state, repo, state.lazyvcs_commit_drafts[repo.root] or "", function(value)
		if value == nil then
			return
		end
		state.lazyvcs_commit_drafts[repo.root] = util.trim(value)
		manager.navigate(state, state.path, nil, nil, false)
	end)
end

function M.generate_commit_message(state, node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end
	local ok, err = ai.generate(repo, function(message)
		state.lazyvcs_commit_drafts[repo.root] = message
		manager.navigate(state, state.path, nil, nil, false)
	end)
	if not ok then
		util.notify(err, vim.log.levels.WARN)
	end
end

function M.open_change(state, node)
	node = node or current_node(state)
	if not node or node.type ~= "file" then
		return
	end
	local repo = current_repo(state, node)
	if repo then
		local busy, job = repo_is_busy(repo.root)
		if busy then
			return notify_repo_busy(repo, job)
		end
	end
	if node.extra and node.extra.deleted then
		util.notify("Opening deleted file diffs is not supported yet", vim.log.levels.WARN)
		return
	end
	local active = active_session_for_tab()
	if active and util.win_is_valid(active.editable_win) then
		if active.source_path == node.path then
			vim.api.nvim_set_current_win(active.editable_win)
			return
		end
		vim.api.nvim_set_current_win(active.editable_win)
		vim.cmd.edit(vim.fn.fnameescape(node.path))
		return
	end
	require("neo-tree.utils").open_file(state, node.path, "edit")
	require("lazyvcs").open({ bufnr = vim.api.nvim_get_current_buf() })
end

function M.stage_file(state, node)
	node = node or current_node(state)
	if not node or node.type ~= "file" then
		return
	end
	local repo = current_repo(state, node)
	if not repo or repo.vcs ~= "git" then
		util.notify("Stage is only supported for Git file nodes", vim.log.levels.WARN)
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end
	local relpath = node.extra.relpath
	local args = node.extra.deleted and { "git", "add", "-A", "--", relpath } or { "git", "add", "--", relpath }
	if run(args, { cwd = repo.root }) then
		restart_source(state, false)
	end
end

function M.unstage_file(state, node)
	node = node or current_node(state)
	if not node or node.type ~= "file" then
		return
	end
	local repo = current_repo(state, node)
	if not repo or repo.vcs ~= "git" then
		util.notify("Unstage is only supported for Git file nodes", vim.log.levels.WARN)
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end
	if run({ "git", "reset", "--", node.extra.relpath }, { cwd = repo.root }) then
		restart_source(state, false)
	end
end

function M.revert_file(state, node)
	node = node or current_node(state)
	if not node or node.type ~= "file" then
		return
	end
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end
	local relpath = node.extra.relpath
	local result
	if repo.vcs == "git" then
		result = run({ "git", "restore", "--worktree", "--", relpath }, { cwd = repo.root })
		if not result and node.extra.change_kind == "untracked" and file_exists(node.path) then
			vim.fn.delete(node.path)
			result = { stdout = "" }
		end
	else
		result = run({ "svn", "revert", relpath }, { cwd = repo.root })
	end
	if result then
		restart_source(state, false)
	end
end

function M.commit_repo(state, node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local message = util.trim(state.lazyvcs_commit_drafts[repo.root] or "")
	if message == "" then
		util.notify("Commit message is empty", vim.log.levels.WARN)
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end

	if repo.vcs == "git" then
		if repo.counts.staged == 0 and repo.counts.local_changes > 0 then
			vim.ui.select({
				"Stage all and commit",
				"Cancel",
			}, {
				prompt = "No staged changes in " .. repo.name,
			}, function(choice)
				if choice ~= "Stage all and commit" then
					return
				end
				start_repo_job(state, repo, {
					action = "commit",
					label = "Committing...",
					sync_text = "Commit",
					remote_refresh = true,
					clear_draft = true,
					start = function(resolve, reject)
						start_command({ "git", "add", "-A" }, repo.root, function(_, add_err)
							if add_err then
								return reject(add_err)
							end
							start_command({ "git", "commit", "-m", message }, repo.root, function(result, commit_err)
								if commit_err then
									return reject(commit_err)
								end
								resolve(result)
							end)
						end)
					end,
				})
			end)
			return
		end
		start_repo_job(state, repo, {
			action = "commit",
			label = "Committing...",
			sync_text = "Commit",
			remote_refresh = true,
			clear_draft = true,
			start = function(resolve, reject)
				start_command({ "git", "commit", "-m", message }, repo.root, function(result, err)
					if err then
						return reject(err)
					end
					resolve(result)
				end)
			end,
		})
		return
	end

	if repo.counts.local_changes == 0 then
		util.notify("No local SVN changes to commit", vim.log.levels.WARN)
		return
	end
	start_repo_job(state, repo, {
		action = "commit",
		label = "Committing...",
		sync_text = "Commit",
		remote_refresh = true,
		clear_draft = true,
		start = function(resolve, reject)
			start_command({ "svn", "commit", "-m", message, repo.root }, repo.root, function(result, err)
				if err then
					return reject(err)
				end
				resolve(result)
			end)
		end,
	})
end

function M.focus_repo(state, node, activate_changes)
	local repo = current_repo(state, node)
	if not repo then
		return
	end

	state.lazyvcs_focused_repo = repo.root
	state.lazyvcs_repo_visibility = state.lazyvcs_repo_visibility or {}
	if state.lazyvcs_selection_mode == "single" then
		state.lazyvcs_repo_visibility = { [repo.root] = true }
	else
		state.lazyvcs_repo_visibility[repo.root] = true
	end

	if activate_changes and not repo_is_busy(repo.root) then
		repo = ensure_repo_details(state, repo)
		state.lazyvcs_force_expand = state.lazyvcs_force_expand or {}
		state.lazyvcs_force_expand[model.repo_changes_id(repo.root)] = true
	end

	save_state(state)
	manager.navigate(state, state.path, nil, nil, false)
end

function M.toggle_repo_visibility(state, node)
	node = node or current_node(state)
	local repo = current_repo(state, node)
	if not repo then
		return
	end

	state.lazyvcs_repo_visibility = state.lazyvcs_repo_visibility or {}
	if state.lazyvcs_selection_mode == "single" then
		state.lazyvcs_repo_visibility = { [repo.root] = true }
		state.lazyvcs_focused_repo = repo.root
	else
		if state.lazyvcs_repo_visibility[repo.root] then
			state.lazyvcs_repo_visibility[repo.root] = nil
		else
			state.lazyvcs_repo_visibility[repo.root] = true
		end
		if not next(state.lazyvcs_repo_visibility) then
			local fallback = state.lazyvcs_focused_repo or first_available_repo_root(state)
			if fallback then
				state.lazyvcs_repo_visibility[fallback] = true
			end
		end
		if not state.lazyvcs_repo_visibility[state.lazyvcs_focused_repo] then
			for root, enabled in pairs(state.lazyvcs_repo_visibility) do
				if enabled then
					state.lazyvcs_focused_repo = root
					break
				end
			end
		end
	end

	save_state(state)
	manager.navigate(state, state.path, nil, nil, false)
end

function M.open_repo(state, node, toggle_node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local busy = repo_is_busy(repo.root)
	if busy then
		return
	end
	if node and type(node.is_expanded) == "function" and node:is_expanded() then
		return toggle_node(state)
	end
	if repo.details_loaded then
		return toggle_node(state)
	end

	state.lazyvcs_force_expand = state.lazyvcs_force_expand or {}
	state.lazyvcs_force_expand[model.repo_changes_id(repo.root)] = true
	ensure_repo_details(state, repo)
	manager.navigate(state, state.path, nil, nil, false)
end

local function repo_actions(repo)
	local actions = {
		{ label = "Commit", action = "commit" },
		{ label = "Generate Commit Message", action = "generate", enabled = ai.available() },
		{ label = "Refresh", action = "refresh" },
	}

	if repo.vcs == "git" then
		actions[#actions + 1] = { label = "Sync Changes", action = "sync" }
		actions[#actions + 1] = { label = "Checkout Branch or Tag...", action = "switch" }
		actions[#actions + 1] = { label = "Fetch", action = "fetch" }
		actions[#actions + 1] = { label = "Pull", action = "pull" }
		actions[#actions + 1] = { label = "Push", action = "push" }
		actions[#actions + 1] = { label = "Stage All", action = "stage_all" }
	else
		actions[#actions + 1] = { label = "Switch...", action = "switch" }
		actions[#actions + 1] = { label = "Update", action = "update" }
	end

	return vim.tbl_filter(function(item)
		return item.enabled == nil or item.enabled
	end, actions)
end

local function execute_repo_action(state, repo, action, node)
	if action == "commit" then
		return M.commit_repo(state, node)
	end
	if action == "generate" then
		return M.generate_commit_message(state, node)
	end
	if action == "refresh" then
		clear_repo_job_errors(repo.root)
		refresh_repo(state, repo.root, true)
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end
	if action == "stage_all" then
		if stage_all(repo) then
			refresh_repo(state, repo.root, false)
		end
		return
	end
	if action == "switch" then
		return M.switch_repo(state, node)
	end
	if action == "fetch" then
		start_repo_job(state, repo, {
			action = "fetch",
			label = "Fetching...",
			sync_text = "Fetch",
			remote_refresh = true,
			start = function(resolve, reject)
				start_command({ "git", "fetch", "--all", "--prune", "--quiet" }, repo.root, function(result, err)
					if err then
						return reject(err)
					end
					resolve(result)
				end)
			end,
		})
		return
	end
	if action == "pull" then
		start_repo_job(state, repo, {
			action = "pull",
			label = "Pulling...",
			sync_text = "Pull",
			remote_refresh = true,
			checktime = true,
			close_sessions = true,
			start = function(resolve, reject)
				start_git_fast_forward(repo, function(result, err)
					if err then
						return reject(err)
					end
					resolve(result)
				end)
			end,
		})
		return
	end
	if action == "push" then
		start_repo_job(state, repo, {
			action = "push",
			label = "Pushing...",
			sync_text = "Push",
			remote_refresh = true,
			start = function(resolve, reject)
				start_command({ "git", "push" }, repo.root, function(result, err)
					if err then
						return reject(err)
					end
					resolve(result)
				end)
			end,
		})
		return
	end
	if action == "update" then
		start_repo_job(state, repo, {
			action = "update",
			label = "Updating...",
			sync_text = "Update",
			remote_refresh = true,
			checktime = true,
			close_sessions = true,
			start = function(resolve, reject)
				start_command({ "svn", "update", repo.root }, repo.root, function(result, err)
					if err then
						return reject(err)
					end
					resolve(result)
				end)
			end,
		})
		return
	end
	if action == "sync" then
		if repo.vcs == "git" then
			start_repo_job(state, repo, {
				action = "sync",
				label = "Syncing...",
				sync_text = "Sync",
				remote_refresh = true,
				checktime = true,
				close_sessions = true,
				start = function(resolve, reject)
					start_git_sync(repo, function(result, err)
						if err then
							return reject(err)
						end
						resolve(result)
					end)
				end,
			})
		else
			start_repo_job(state, repo, {
				action = "sync",
				label = "Updating...",
				sync_text = "Update",
				remote_refresh = true,
				checktime = true,
				close_sessions = true,
				start = function(resolve, reject)
					start_command({ "svn", "update", repo.root }, repo.root, function(result, err)
						if err then
							return reject(err)
						end
						resolve(result)
					end)
				end,
			})
		end
		return
	end
end

function M.switch_repo(state, node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end

	set_repo_job(state, repo.root, {
		status = "running",
		action = "switch_targets",
		label = "Loading targets...",
		sync_text = "Branches",
	})
	local bg = config.get().source_control.background
	return repo_switch.open_async(repo, {
		on_ready = function()
			session_state.clear_repo_job(repo.root)
			navigate_if_visible(state)
		end,
		before_mutation = function(target_repo)
			return true
		end,
		run_mutation = function(target_repo, choice, args, mutation_opts)
			start_repo_job(state, target_repo, {
				action = "switch",
				label = "Switching...",
				sync_text = "Switch",
				remote_refresh = false,
				checktime = true,
				close_sessions = true,
				start = function(resolve, reject)
					start_command(args, mutation_opts.cwd or target_repo.root, function(result, err)
						if err then
							return reject(err)
						end
						resolve(result)
					end)
				end,
				after_success = function(result)
					if type(mutation_opts.on_success) == "function" then
						mutation_opts.on_success(result)
					end
				end,
			})
		end,
		after_mutation = function() end,
	}, function(args, opts, on_done)
		jobs.command(repo, opts.kind or "switch", args, {
			timeout_ms = bg.switch_timeout_ms,
			generation = state.lazyvcs_hydration_generation or 0,
			scope = "switch",
			priority = 20,
		}, on_done)
	end)
end

function M.run_primary_action(state, node)
	node = node or current_node(state)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local action = node.extra and node.extra.action or "commit"
	execute_repo_action(state, repo, action, node)
end

function M.repo_action_picker(state, node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end
	local actions = repo_actions(repo)
	vim.ui.select(actions, {
		prompt = "Actions for " .. repo.name,
		format_item = function(item)
			return item.label
		end,
	}, function(choice)
		if not choice then
			return
		end
		execute_repo_action(state, repo, choice.action, node)
	end)
end

function M.sync_repo(state, node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy then
		return notify_repo_busy(repo, job)
	end
	if config.get().source_control.sync_button_behavior == "direct" then
		return execute_repo_action(state, repo, "sync", node)
	end
	return M.repo_action_picker(state, node)
end

return M
