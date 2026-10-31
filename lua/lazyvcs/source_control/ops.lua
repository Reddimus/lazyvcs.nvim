local ai = require("lazyvcs.source_control.ai")
local buffer_guard = require("lazyvcs.source_control.buffer_guard")
local confirm = require("lazyvcs.source_control.confirm")
local config = require("lazyvcs.config")
local input = require("lazyvcs.source_control.input")
local jobs = require("lazyvcs.source_control.jobs")
local model = require("lazyvcs.source_control.model")
local mutation_start = require("lazyvcs.source_control.mutation_start")
local persist = require("lazyvcs.source_control.persist")
local picker = require("lazyvcs.picker")
local repo_switch = require("lazyvcs.source_control.switch")
local session_state = require("lazyvcs.state")
local util = require("lazyvcs.util")

local remote_snapshots = require("lazyvcs.source_control.remote_refresh")

local M = {}
local mutation_generations = {}
local draft_states = setmetatable({}, { __mode = "k" })

local function draft_record(state, root)
	state.lazyvcs_commit_generations = state.lazyvcs_commit_generations or {}
	local record = state.lazyvcs_commit_generations[root]
	if not record then
		record = { revision = 0 }
		state.lazyvcs_commit_generations[root] = record
	end
	return record
end

local function detach_generation(state, record)
	local ticket = record.current
	if not ticket then
		return
	end
	record.current = nil
	state.lazyvcs_commit_pending[ticket.root] = nil
	ticket.active = false
	if state.lazyvcs_repaint then
		state.lazyvcs_repaint(state)
	end
	state.lazyvcs_commit_generation_count = state.lazyvcs_commit_generation_count - 1
	if state.lazyvcs_commit_generation_count == 0 then
		draft_states[state] = nil
	end
	return ticket
end

local function cancel_ticket(ticket)
	local task = ticket and ticket.task
	if task then
		local cancel = task.cancel or task.kill
		if type(cancel) == "function" then
			pcall(cancel, task)
		end
		ticket.task = nil
	end
end

function M.cancel_commit_generations(state, root)
	local records = state.lazyvcs_commit_generations or {}
	if root then
		local record = records[root]
		local ticket = record and detach_generation(state, record)
		cancel_ticket(ticket)
		return ticket and 1 or 0
	end
	local count = 0
	for _, record in pairs(state.lazyvcs_commit_pending or {}) do
		local ticket = detach_generation(state, record)
		if ticket then
			count = count + 1
			cancel_ticket(ticket)
		end
	end
	return count
end

local function set_commit_draft(state, root, value)
	local record = draft_record(state, root)
	record.revision = record.revision + 1
	M.cancel_commit_generations(state, root)
	state.lazyvcs_commit_drafts = state.lazyvcs_commit_drafts or {}
	state.lazyvcs_commit_drafts[root] = value
end

local function begin_commit_generation(state, root)
	M.cancel_commit_generations(state, root)
	local record = draft_record(state, root)
	local ticket = { state = state, root = root, revision = record.revision, active = true }
	record.current = ticket
	state.lazyvcs_commit_pending = state.lazyvcs_commit_pending or {}
	state.lazyvcs_commit_pending[root] = record
	state.lazyvcs_commit_generation_count = (state.lazyvcs_commit_generation_count or 0) + 1
	draft_states[state] = true
	return ticket
end

local function finish_commit_generation(ticket, message)
	local state = ticket.state
	local record = draft_record(state, ticket.root)
	if not ticket.active or record.current ~= ticket or record.revision ~= ticket.revision then
		return false
	end
	detach_generation(state, record)
	if message and util.trim(message) ~= "" then
		set_commit_draft(state, ticket.root, message)
		ai.clear_error(ticket.root)
		if state.lazyvcs_repaint then
			state.lazyvcs_repaint(state)
		end
	end
	return true
end

local function current_node(state)
	if state.lazyvcs_get_node then
		return state.lazyvcs_get_node(state)
	end
	return state.tree and state.tree:get_node() or nil
end

local function navigate(state)
	if state.lazyvcs_render then
		return state.lazyvcs_render(state)
	end
end

local function window_exists(state)
	if state.lazyvcs_window_exists then
		return state.lazyvcs_window_exists(state)
	end
	return true
end

local function repo_root_for_node(node)
	if not node then
		return nil
	end
	if node.extra and node.extra.repo_root then
		return node.extra.repo_root
	end
	if node.path then
		return node.path
	end
	if type(node.get_id) == "function" then
		return node:get_id()
	end
	return nil
end

local function current_repo(state, node)
	local repo_root = repo_root_for_node(node or current_node(state))
	if not repo_root then
		return nil
	end
	return state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[repo_root] or nil
end

local function repo_generation(state, repo_root)
	state.lazyvcs_repo_generations = state.lazyvcs_repo_generations or {}
	return state.lazyvcs_repo_generations[repo_root] or 0
end

local function invalidate_hydration(state, repo_root, reason)
	if type(state.lazyvcs_invalidate_hydration) == "function" then
		return state.lazyvcs_invalidate_hydration(state, repo_root, reason)
	end

	state.lazyvcs_hydration_generation = (state.lazyvcs_hydration_generation or 0) + 1
	state.lazyvcs_repo_generations = state.lazyvcs_repo_generations or {}
	state.lazyvcs_summary_generations = state.lazyvcs_summary_generations or {}
	local roots = {}
	if repo_root then
		roots[repo_root] = true
	else
		for _, repo in ipairs(state.lazyvcs_repo_specs or {}) do
			roots[repo.root] = true
		end
		for root in pairs(state.lazyvcs_repo_cache or {}) do
			roots[root] = true
		end
	end
	for root in pairs(roots) do
		state.lazyvcs_repo_generations[root] = (state.lazyvcs_repo_generations[root] or 0) + 1
		state.lazyvcs_summary_generations[root] = (state.lazyvcs_summary_generations[root] or 0) + 1
		local cached = state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[root] or nil
		if cached then
			cached.loading_summary = false
			cached.refreshing_summary = false
		end
	end
	return jobs.cancel(function(job)
		return job.owner == state and job.scope == "hydration" and (not repo_root or job.root == repo_root)
	end, reason or "hydration invalidated")
end

local function repo_changes_expanded(state, node, repo)
	if node and type(node.is_expanded) == "function" then
		return node:is_expanded()
	end
	local id = model.repo_changes_id(repo.root)
	return state.lazyvcs_expanded and state.lazyvcs_expanded[id] == true
end

local function set_repo_changes_expanded(state, repo, expanded)
	local id = model.repo_changes_id(repo.root)
	state.lazyvcs_expanded = state.lazyvcs_expanded or {}
	state.lazyvcs_force_expand = state.lazyvcs_force_expand or {}
	state.lazyvcs_expanded[id] = expanded == true
	if not expanded then
		state.lazyvcs_force_expand[id] = nil
	end
	persist.save_state(state)
	navigate(state)
end

local function restart_source(state, remote_refresh)
	invalidate_hydration(state, nil, "source restarted")
	state.lazyvcs_repo_cache = model.refresh_cache(state.lazyvcs_repo_cache)
	state.lazyvcs_loading_details = {}
	state.lazyvcs_remote_refresh = remote_refresh ~= false
	persist.save_state(state)
	navigate(state)
end

local function navigate_if_visible(state)
	if state.path and window_exists(state) then
		navigate(state)
	end
end

local function invalidate_repo(state, repo_root, remote_refresh, reason)
	state.lazyvcs_repo_cache = state.lazyvcs_repo_cache or {}
	invalidate_hydration(state, repo_root, reason or "repository invalidated")
	state.lazyvcs_repo_cache[repo_root] = nil
	state.lazyvcs_loading_details = state.lazyvcs_loading_details or {}
	state.lazyvcs_loading_details[repo_root] = nil
	state.lazyvcs_remote_refresh = remote_refresh ~= false
	persist.save_state(state)
end

local function clear_repo_details_loading(state, repo_root)
	state.lazyvcs_loading_details = state.lazyvcs_loading_details or {}
	state.lazyvcs_loading_details[repo_root] = nil
	local cached = state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[repo_root] or nil
	if cached then
		cached.loading_details = false
	end
end

local function refresh_repo(state, repo_root, remote_refresh)
	require("lazyvcs.backends").invalidate(repo_root)
	invalidate_repo(state, repo_root, remote_refresh, "repository refreshed")
	navigate_if_visible(state)
end

local function confirm_mutation(_, message, on_confirm)
	return confirm.mutation({
		prompt = message,
	}, on_confirm)
end

local function close_sessions_for_repo(repo_root)
	local actions = require("lazyvcs.actions")
	for _, session in ipairs(session_state.list()) do
		if session.root == repo_root then
			actions.close(session)
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

local function repo_needs_publish(repo)
	return repo and repo.sync and repo.sync.status == "publish"
end

local function clear_repo_job_errors(repo_root)
	session_state.clear_repo_job_errors(repo_root)
end

local function set_repo_job(state, repo_root, job)
	session_state.set_repo_job(repo_root, job)
	navigate_if_visible(state)
end

local function repository_changed(state, root, remote_refresh, cancelled)
	if state.lazyvcs_repository_changed then
		return state.lazyvcs_repository_changed(state, root, remote_refresh, cancelled)
	end
	invalidate_repo(state, root, remote_refresh)
	navigate_if_visible(state)
end

local function finish_repo_job(state, repo, spec, result, err, raw)
	local current = session_state.get_repo_job(repo.root)
	if current and current.generation and current.generation ~= spec.generation then
		return
	end
	if raw and raw.cancelled then
		session_state.clear_repo_job(repo.root)
		repository_changed(state, repo.root, false, true)
		return
	end
	if err then
		session_state.set_repo_job(repo.root, {
			status = "error",
			action = spec.action,
			label = spec.label,
			sync_text = spec.sync_text,
			error = err,
			timed_out = raw and raw.timed_out == true or false,
		})
		repository_changed(state, repo.root, false)
		-- `.` opens repository actions in every sync_button_behavior; `s` may run Sync.
		local suffix = "; .: Show Last Error"
		local width = math.max(1, vim.o.columns - 1)
		local summary = vim.fn.strtrans((tostring(err):gsub("[\r\n]+", " ")))
		util.notify(
			util.truncate_display(util.truncate_display(summary, math.max(0, width - #suffix)) .. suffix, width),
			vim.log.levels.ERROR
		)
		return
	end

	session_state.clear_repo_job(repo.root)
	if repo.vcs == "svn" and spec.action == "commit" and not (result and (result.stdout or ""):find("%S")) then
		util.notify("No revision was created.", vim.log.levels.WARN)
	end
	if
		spec.clear_draft
		and (repo.vcs ~= "svn" or spec.action ~= "commit" or (result and (result.stdout or ""):find("%S")))
	then
		set_commit_draft(state, repo.root, "")
	end
	if spec.checktime then
		vim.cmd("silent! checktime")
	end
	if type(spec.after_success) == "function" then
		spec.after_success(result)
	end
	repository_changed(state, repo.root, spec.remote_refresh)
end

local function start_repo_job(state, repo, spec)
	local busy, job = repo_is_busy(repo.root)
	if busy then
		notify_repo_busy(repo, job)
		return false
	end
	if spec.guard_modified_buffers and not buffer_guard.check(repo.root) then
		session_state.clear_repo_job(repo.root)
		navigate_if_visible(state)
		return false
	end

	clear_repo_job_errors(repo.root)
	if spec.close_sessions then
		close_sessions_for_repo(repo.root)
	end

	mutation_generations[repo.root] = (mutation_generations[repo.root] or 0) + 1
	spec.generation = mutation_generations[repo.root]
	set_repo_job(state, repo.root, {
		status = "running",
		action = spec.action,
		label = spec.label,
		sync_text = spec.sync_text or spec.label,
		generation = spec.generation,
	})

	local completed = false
	local function resolve(result, raw)
		if completed then
			return
		end
		completed = true
		finish_repo_job(state, repo, spec, result, nil, raw)
	end
	local function reject(err, raw)
		if completed then
			return
		end
		completed = true
		finish_repo_job(state, repo, spec, nil, err, raw)
	end
	local ok, start_err = pcall(spec.start, resolve, reject)
	if not ok then
		reject(tostring(start_err))
		return false
	end
	return true
end

local read_only_commands = {
	git_status = true,
	git_current_branch = true,
	git_upstream = true,
	git_remotes = true,
	git_push_policy = true,
	git_upstream_target = true,
	git_fetch = true,
	svn_discard_info = true,
}

local function start_command(repo, kind, args, on_done, opts)
	opts = opts or {}
	local timeout = opts.timeout_ms or config.get().source_control.background.mutation_timeout_ms
	local base_mutation = kind == "git_stage_file"
		or kind == "git_unstage_file"
		or kind == "discard_staged"
		or kind == "git_stage_all"
		or kind == "git_commit"
		or kind == "git_merge"
		or kind == "svn_commit"
		or kind == "svn_update"
		or kind == "switch_mutation"
	local process_start = opts.start
	if
		base_mutation
		or opts.guard_modified_buffers
		or opts.branch_ref
		or opts.svn_discard
		or opts.git_untracked_delete
	then
		process_start = function(command, process_opts, on_exit)
			local signs, change, blame_change, live_change
			local guards = vim.tbl_extend("force", {}, opts)
			if base_mutation then
				local paths
				if kind == "git_stage_file" or kind == "git_unstage_file" or kind == "discard_staged" then
					paths = {}
					local after_separator = false
					for _, arg in ipairs(command) do
						if after_separator then
							paths[#paths + 1] = util.normalize_literal_path(repo.root .. "/" .. arg)
						elseif arg == "--" then
							after_separator = true
						end
					end
				end
				signs = require("lazyvcs.signs")
				guards.on_mutation_start = function()
					if opts.on_mutation_start then
						opts.on_mutation_start()
					end
					if repo.vcs == "svn" then
						remote_snapshots.invalidate(repo.root)
					end
					change = signs.begin_base_change(repo.root, paths)
					local actions = package.loaded["lazyvcs.actions"]
					if actions and actions.begin_base_change then
						live_change = actions.begin_base_change(repo.root, paths)
					end
					if
						kind == "git_commit"
						or kind == "svn_commit"
						or kind == "git_merge"
						or kind == "svn_update"
						or kind == "switch_mutation"
					then
						blame_change = require("lazyvcs.blame").begin_history_change(repo.root)
					end
				end
			end
			local function settle_base()
				if live_change then
					local settled = live_change
					live_change = nil
					util.safe_callback(require("lazyvcs.actions").finish_base_change)(settled)
				end
				if change then
					local settled = change
					change = nil
					if repo.vcs == "svn" then
						remote_snapshots.invalidate(repo.root)
					end
					util.safe_callback(signs.finish_base_change)(settled)
				end
				if blame_change then
					local settled = blame_change
					blame_change = nil
					util.safe_callback(require("lazyvcs.blame").finish_history_change)(settled)
				end
			end
			local function settle(result, err, raw)
				settle_base()
				on_exit(result, err, raw)
			end
			-- Custom starters (for example private commit-message files) spawn the command
			-- themselves; without a preflight the base changes when they start.
			if opts.start and not (opts.guard_modified_buffers or opts.branch_ref or opts.svn_discard) then
				if guards.on_mutation_start then
					guards.on_mutation_start()
				end
				local ok, handle = pcall(opts.start, command, process_opts, settle)
				if not ok then
					settle_base()
					error(handle, 0)
				end
				return handle
			end
			return mutation_start.start(repo, command, process_opts, guards, settle)
		end
	end
	return jobs.command(repo, kind, args, {
		cwd = opts.cwd or repo.root,
		timeout_ms = timeout,
		kill_grace_ms = opts.kill_grace_ms,
		output_limit_bytes = opts.output_limit_bytes,
		owner = opts.owner or repo.root,
		scope = opts.scope or (read_only_commands[kind] and kind or "mutation"),
		generation = opts.generation or mutation_generations[repo.root],
		priority = opts.priority or 100,
		start = process_start,
	}, function(result, err, raw)
		on_done(result, err, raw)
	end)
end

local function start_commit_command(repo, message, on_done)
	local args = repo.vcs == "git" and { "git", "-c", "i18n.commitEncoding=UTF-8", "commit", "-F", "-" }
		or { "svn", "commit", "-F", "-" }
	if repo.vcs == "svn" then
		args[#args + 1] = "--encoding"
		args[#args + 1] = "UTF-8"
		args[#args + 1] = util.svn_target(repo.root)
	end
	return start_command(repo, repo.vcs .. "_commit", args, on_done, {
		start = function(command, process_opts, on_exit)
			local message_index
			for index, arg in ipairs(command) do
				if arg == "-F" then
					message_index = index + 1
					break
				end
			end
			if not message_index or not command[message_index] then
				on_exit(nil, "Commit command is missing the -F message file argument")
				return
			end
			local commit_files = require("lazyvcs.source_control.commit_files")
			local file, file_err = commit_files.create(message)
			if not file then
				on_exit(nil, file_err)
				return
			end
			local function cleanup()
				commit_files.release(file)
			end
			command[message_index] = file.path
			process_opts.preserve_on_shutdown = process_opts.preserve_on_shutdown and file.persistent
			local started, handle = pcall(util.system_start, command, process_opts, function(...)
				cleanup()
				on_exit(...)
			end)
			if not started then
				cleanup()
				on_exit(nil, util.truncate((tostring(handle):gsub("[\r\n]+", " ")), 512))
				return
			end
			commit_files.attach(file, handle)
			return handle
		end,
	})
end

local function start_simple_repo_job(state, repo, spec, kind, args, opts)
	spec.start = function(resolve, reject)
		start_command(repo, kind, args, function(result, err, raw)
			if err then
				return reject(err, raw)
			end
			resolve(result, raw)
		end, opts)
	end
	return start_repo_job(state, repo, spec)
end

local function parse_git_branch_state(line)
	line = line or ""
	return {
		ahead = tonumber(line:match("ahead (%d+)") or "0") or 0,
		behind = tonumber(line:match("behind (%d+)") or "0") or 0,
		has_upstream = line:match("%.%.%.") ~= nil,
	}
end

local function parse_git_remotes(stdout)
	local seen = {}
	local remotes = {}
	for _, line in ipairs(util.split_lines(stdout or "")) do
		local remote = util.trim(line)
		if remote ~= "" and not seen[remote] then
			seen[remote] = true
			remotes[#remotes + 1] = remote
		end
	end
	return remotes
end

local function select_publish_remote(remotes)
	for _, remote in ipairs(remotes) do
		if remote == "origin" then
			return remote
		end
	end
	if #remotes == 1 then
		return remotes[1]
	end
	return nil
end

local function start_git_status(repo, on_done)
	start_command(
		repo,
		"git_status",
		{ "git", "status", "--branch", "--porcelain=v1", "--untracked-files=no", "--ignored=no" },
		function(status_result, status_err, raw)
			if status_err then
				return on_done(nil, status_err, raw)
			end

			local lines = util.split_lines(status_result.stdout)
			local branch_state = parse_git_branch_state(lines[1])
			on_done(branch_state, nil)
		end
	)
end

local function start_git_current_branch(repo, on_done)
	start_command(repo, "git_current_branch", { "git", "branch", "--show-current" }, function(result, err, raw)
		if err then
			return on_done(nil, err, raw)
		end
		local branch = util.trim(result and result.stdout or "")
		if branch == "" then
			return on_done(nil, "Cannot mutate detached HEAD in " .. repo.name .. ". Check out a branch first.", raw)
		end
		on_done(branch, nil)
	end)
end

local function start_git_upstream(repo, branch_name, on_done)
	start_command(repo, "git_upstream", {
		"git",
		"for-each-ref",
		"--format=%(refname)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)",
		"refs/heads/" .. branch_name,
	}, function(upstream, upstream_err, raw)
		if upstream_err then
			return on_done(nil, upstream_err, raw)
		end

		local value = upstream and upstream.stdout or ""
		if value == "" then
			return on_done({ missing = true }, nil)
		end
		local ref, full, remote, branch = value:match("^([^%z]+)%z([^%z]*)%z([^%z]*)%z([^%z\n]*)\n?$")
		if ref == "refs/heads/" .. branch_name and full == "" and remote == "" and branch == "" then
			return on_done({ missing = true }, nil)
		end
		if
			ref ~= "refs/heads/" .. branch_name
			or not full
			or not full:match("^refs/")
			or remote == ""
			or not branch:match("^refs/")
		then
			return on_done(
				nil,
				"Invalid or incomplete upstream metadata for " .. repo.name .. "; refresh and retry.",
				raw
			)
		end
		on_done({ remote = remote, branch = branch, full = full }, nil)
	end)
end

local function git_push_args(remote, refspec, set_upstream)
	local args = { "git", "push" }
	if set_upstream then
		args[#args + 1] = "--set-upstream"
	end
	vim.list_extend(args, { "--", remote, refspec })
	return args
end

local function confirm_git_intent(repo, branch, upstream, label, on_ready, on_done)
	local push_intent = require("lazyvcs.source_control.push_intent")
	start_command(repo, "git_push_policy", push_intent.policy_args(), function(result, err, raw)
		if err then
			return on_done(nil, err, raw)
		end
		if result.stdout_truncated then
			return on_done(nil, "Cannot verify push.default; refresh and retry.", raw)
		end
		local policy = util.trim(result.stdout or "")
		local target = upstream.missing and "refs/heads/" .. branch or upstream.branch
		local failure = push_intent.policy_error(branch, target, policy)
		if failure then
			return on_done(nil, failure)
		end
		local intent = {
			branch = branch,
			remote = upstream.remote,
			target = target,
			full = upstream.full,
			missing = upstream.missing,
			policy = policy,
		}
		local owner = current_repo_job(repo.root)
		return confirm.mutation({
			prompt = label
				.. " refs/heads/"
				.. branch
				.. " -> "
				.. intent.remote
				.. " "
				.. target
				.. " in "
				.. repo.name
				.. "?",
		}, function()
			if current_repo_job(repo.root) ~= owner then
				return
			end
			on_ready(intent)
		end, function()
			on_done(nil, "Cancelled", { code = 130, stdout = "", stderr = "Cancelled", cancelled = true })
		end)
	end)
end

local function push_with_intent(repo, branch, upstream, on_done)
	return confirm_git_intent(repo, branch, upstream, upstream.missing and "Publish" or "Push", function(intent)
		start_command(
			repo,
			upstream.missing and "git_publish" or "git_push",
			git_push_args(intent.remote, "refs/heads/" .. branch .. ":" .. intent.target, upstream.missing),
			on_done,
			{
				branch_ref = "refs/heads/" .. branch,
				git_remote_intent = intent,
			}
		)
	end, on_done)
end

local function start_git_fast_forward(repo, branch, upstream, ask, on_done)
	local plan = require("lazyvcs.source_control.push_intent")
	local intent = {
		kind = "fast_forward",
		branch = branch,
		remote = upstream.remote,
		target = upstream.branch,
		full = upstream.full,
	}
	start_command(repo, "git_upstream_target", plan.target_args(intent), function(result, err, raw)
		if err then
			return on_done(nil, err, raw)
		end
		local oid = util.trim(result.stdout or "")
		if result.stdout_truncated or not plan.valid_oid(oid) then
			return on_done(nil, "Cannot verify fetched upstream commit; refresh and retry.", raw)
		end
		intent.oid = oid
		local owner = current_repo_job(repo.root)
		local function start()
			if current_repo_job(repo.root) ~= owner then
				return
			end
			if ask then
				close_sessions_for_repo(repo.root)
			end
			start_command(repo, "git_merge", { "git", "merge", "--ff-only", oid }, on_done, {
				guard_modified_buffers = true,
				branch_ref = "refs/heads/" .. branch,
				git_remote_intent = intent,
			})
		end
		if not ask then
			return start()
		end
		return confirm.mutation(
			{
				prompt = "Fast-forward refs/heads/"
					.. branch
					.. " from "
					.. upstream.remote
					.. " "
					.. upstream.branch
					.. " ("
					.. oid:sub(1, 12)
					.. ") in "
					.. repo.name
					.. "?",
			},
			start,
			function()
				on_done(nil, "Cancelled", { code = 130, stdout = "", stderr = "Cancelled", cancelled = true })
			end
		)
	end)
end

local function start_git_publish(repo, on_done, expected_branch)
	start_command(repo, "git_remotes", { "git", "remote" }, function(remote_result, remote_err, raw)
		if remote_err then
			return on_done(nil, remote_err, raw)
		end

		local remotes = parse_git_remotes(remote_result and remote_result.stdout or "")
		local remote = select_publish_remote(remotes)
		if not remote then
			if #remotes == 0 then
				return on_done(nil, "Cannot publish " .. repo.name .. " because it has no Git remotes.", raw)
			end
			return on_done(
				nil,
				"Cannot publish " .. repo.name .. " because it has multiple Git remotes and no origin remote.",
				raw
			)
		end

		-- Resolve the branch immediately before the destructive network mutation;
		-- the cached sidebar model may be stale or the branch may have changed in
		-- another terminal while the remote list was loading.
		start_git_current_branch(repo, function(branch, branch_err, branch_raw)
			if branch_err then
				return on_done(nil, branch_err, branch_raw)
			end
			if expected_branch and branch ~= expected_branch then
				return on_done(nil, "Branch changed while preparing to publish; retry the action.")
			end
			start_git_upstream(repo, branch, function(upstream, upstream_err, upstream_raw)
				if upstream_err then
					return on_done(nil, upstream_err, upstream_raw)
				end
				if upstream.missing then
					upstream.remote = remote
				end
				return push_with_intent(repo, branch, upstream, on_done)
			end)
		end)
	end)
end

local function start_git_push(repo, on_done)
	start_git_current_branch(repo, function(branch, branch_err, branch_raw)
		if branch_err then
			return on_done(nil, branch_err, branch_raw)
		end
		start_git_upstream(repo, branch, function(upstream, upstream_err, upstream_raw)
			if upstream_err then
				return on_done(nil, upstream_err, upstream_raw)
			end
			if upstream.missing then
				return start_git_publish(repo, on_done)
			end

			return push_with_intent(repo, branch, upstream, on_done)
		end)
	end)
end

local function start_git_integrate(repo, sync, on_done)
	start_git_current_branch(repo, function(branch, branch_err, branch_raw)
		if branch_err then
			return on_done(nil, branch_err, branch_raw)
		end
		start_git_upstream(repo, branch, function(upstream, upstream_err, upstream_raw)
			if upstream_err then
				return on_done(nil, upstream_err, upstream_raw)
			end
			if upstream.missing then
				if sync then
					return start_git_publish(repo, on_done, branch)
				end
				return on_done(nil, "Branch " .. branch .. " has no upstream to fast-forward from.")
			end
			local function integrate()
				start_command(
					repo,
					"git_fetch",
					{ "git", "fetch", "--prune", "--quiet", "--", upstream.remote },
					function(_, fetch_err, fetch_raw)
						if fetch_err then
							return on_done(nil, fetch_err, fetch_raw)
						end
						start_git_current_branch(repo, function(current, current_err, current_raw)
							if current_err then
								return on_done(nil, current_err, current_raw)
							end
							if current ~= branch then
								return on_done(nil, "Branch changed while fetching; retry the action.")
							end
							start_git_status(repo, function(branch_state, status_err, status_raw)
								if status_err then
									return on_done(nil, status_err, status_raw)
								end
								if branch_state.ahead > 0 and branch_state.behind > 0 then
									return on_done(
										nil,
										"Pull and Sync only fast-forward. This branch has diverged; explicitly merge or rebase, then retry Sync."
									)
								end
								if branch_state.behind > 0 then
									return start_git_fast_forward(repo, branch, upstream, sync, on_done)
								end
								if sync and branch_state.ahead > 0 then
									return push_with_intent(repo, branch, upstream, on_done)
								end
								on_done({ code = 0, stdout = "", stderr = "" }, nil)
							end)
						end)
					end
				)
			end
			return integrate()
		end)
	end)
end

function M.load_repo_details(state, root)
	local repo = state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[root]
	if
		not repo
		or not window_exists(state)
		or state.lazyvcs_target_owner_valid and not state.lazyvcs_target_owner_valid(state)
		or repo_is_busy(root)
	then
		return repo
	end
	if repo.details_loaded then
		return repo
	end
	if repo.loading_details then
		return repo
	end

	state.lazyvcs_loading_details = state.lazyvcs_loading_details or {}
	state.lazyvcs_loading_details[repo.root] = true
	state.lazyvcs_repo_cache[repo.root] = vim.tbl_extend("force", repo, { loading_details = true })

	local generation = repo_generation(state, repo.root)
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
			output_limit_bytes = opts.output_limit_bytes,
			generation = generation,
			-- Use a per-repository scope; one repository generation must not mark another
			-- repository stale.
			scope = "details:" .. repo.root,
			owner = state,
			priority = 10,
		}, on_done)
	end, function(detail, err)
		local ok, failure = pcall(function()
			if repo_generation(state, repo.root) ~= generation then
				return
			end
			state.lazyvcs_loading_details[repo.root] = nil
			if state.lazyvcs_target_owner_valid and not state.lazyvcs_target_owner_valid(state) then
				local cached = state.lazyvcs_repo_cache[repo.root]
				if cached then
					cached.loading_details = false
					state.lazyvcs_restore_details = state.lazyvcs_restore_details or {}
					state.lazyvcs_restore_details[repo.root] = true
				end
				return
			end
			if detail then
				state.lazyvcs_repo_cache[repo.root] = model.merge_details(state.lazyvcs_repo_cache[repo.root], detail)
			else
				state.lazyvcs_repo_cache[repo.root] =
					model.merge_details(state.lazyvcs_repo_cache[repo.root], model.make_error(repo, repo, err))
				util.notify(tostring(err):gsub("[\r\n]+", " "), vim.log.levels.WARN)
			end
			state.lazyvcs_repo_cache[repo.root] =
				model.with_remote_snapshot(state.lazyvcs_repo_cache[repo.root], remote_snapshots.read(repo.root))
			navigate_if_visible(state)
		end)
		if not ok then
			util.notify(tostring(failure):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
		end
	end)
	return state.lazyvcs_repo_cache[repo.root]
end

function M.refresh(state, remote_refresh)
	require("lazyvcs.backends").invalidate(state.path)
	clear_repo_job_errors()
	restart_source(state, remote_refresh)
end

function M.toggle_show_clean(state)
	persist.mark(state, "show_clean")
	state.lazyvcs_show_clean = not state.lazyvcs_show_clean
	persist.save_state(state)
	navigate(state)
end

function M.toggle_changes_view_mode(state)
	persist.mark(state, "changes_view_mode")
	state.lazyvcs_changes_view_mode = state.lazyvcs_changes_view_mode == "tree" and "list" or "tree"
	persist.save_state(state)
	navigate(state)
end

function M.cycle_changes_sort(state)
	persist.mark(state, "changes_sort")
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
	persist.save_state(state)
	navigate(state)
end

function M.edit_commit_message(state, node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local busy, job = repo_is_busy(repo.root)
	if busy and job then
		return notify_repo_busy(repo, job)
	end

	input.open(state, repo, state.lazyvcs_commit_drafts[repo.root] or "", function(value)
		if value == nil then
			return
		end
		set_commit_draft(state, repo.root, util.trim(value))
		navigate(state)
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
	local ticket = begin_commit_generation(state, repo.root)
	if state.lazyvcs_repaint then
		state.lazyvcs_repaint(state)
	end
	local function finish(message, err)
		local record = draft_record(state, repo.root)
		if not ticket.active or record.current ~= ticket or record.revision ~= ticket.revision then
			return
		end
		if err then
			if finish_commit_generation(ticket) then
				ai.notify_error(repo.root, err)
			end
			return
		end
		local draft = util.trim((state.lazyvcs_commit_drafts or {})[repo.root] or "")
		if message and util.trim(message) ~= "" and draft ~= "" and draft ~= message then
			return picker.select({ "Replace", "Keep" }, { prompt = "Replace existing commit draft?" }, function(choice)
				if
					finish_commit_generation(ticket, choice == "Replace" and message or nil) and state.lazyvcs_repaint
				then
					state.lazyvcs_repaint(state)
				end
			end)
		end
		finish_commit_generation(ticket, message)
	end
	local ok, task, err = pcall(ai.generate, repo, finish, {
		owner = state,
		on_cancel = function()
			finish_commit_generation(ticket)
		end,
	})
	if not ok or not task then
		finish(nil, ok and err or task)
		return
	end
	ticket.task = task
	if not ticket.active then
		cancel_ticket(ticket)
	end
end

function M.cancel_diff_target(state, _reason)
	local task = state.lazyvcs_diff_target_task
	state.lazyvcs_diff_target_generation = (state.lazyvcs_diff_target_generation or 0) + 1
	state.lazyvcs_diff_target_task = nil
	state.lazyvcs_diff_target_root = nil
	if task then
		local cancel = task.cancel or task.kill
		if type(cancel) == "function" then
			pcall(cancel, task, 15)
		end
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
	if not repo then
		util.notify("Unable to resolve the repository for this change", vim.log.levels.WARN)
		return
	end

	if (node.extra or {}).change_kind == "untracked" then
		local stat = vim.uv.fs_lstat(node.path)
		if stat and stat.type == "directory" then
			return util.notify(
				"Directory changes cannot open as file diffs; open the directory's repository or select a file.",
				vim.log.levels.INFO
			)
		end
	end
	local backends = require("lazyvcs.backends")
	local target = vim.tbl_extend("force", vim.deepcopy(node.extra or {}), {
		vcs = repo.vcs,
		root = repo.root,
		repo_root = repo.root,
		path = node.path,
	})
	M.cancel_diff_target(state, "target replaced")
	local origin_win = vim.api.nvim_get_current_win()
	local origin_path = state.path
	local editor_target = require("lazyvcs.editor_target")
	local destination = editor_target.capture(state.editor_winid, origin_win)
	local generation = state.lazyvcs_diff_target_generation
	state.lazyvcs_diff_target_root = repo.root
	navigate_if_visible(state)

	local completed = false
	local task = backends.load_diff_target_async(target, function(loaded, load_err)
		completed = true
		if state.lazyvcs_diff_target_generation ~= generation then
			return
		end
		local owner_valid = not state.lazyvcs_target_owner_valid or state.lazyvcs_target_owner_valid(state)
		local destination_valid = editor_target.valid(destination)
		if not owner_valid or state.path ~= origin_path or not destination_valid then
			M.cancel_diff_target(state, "target owner changed")
			return
		end
		state.lazyvcs_diff_target_task = nil
		state.lazyvcs_diff_target_root = nil
		navigate_if_visible(state)
		if not loaded then
			util.notify(load_err or "Unable to load the selected diff target", vim.log.levels.ERROR)
			return
		end
		local actions = require("lazyvcs.actions")
		if type(actions.open_target) ~= "function" then
			util.notify("Typed diff UI support is unavailable", vim.log.levels.ERROR)
			return
		end
		destination.preserve_focus = vim.api.nvim_get_current_win() ~= origin_win
		local ok, open_err = pcall(actions.open_target, loaded, destination)
		if not ok then
			util.notify(tostring(open_err):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
		end
	end, {
		timeout_ms = config.get().source_control.background.status_timeout_ms,
	})
	if not completed then
		state.lazyvcs_diff_target_task = task
	end
	return task
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
	confirm_mutation(state, "Stage " .. relpath .. " in " .. repo.name .. "?", function()
		start_simple_repo_job(
			state,
			repo,
			{
				action = "stage_file",
				label = "Staging " .. relpath .. "...",
				sync_text = "Stage",
				remote_refresh = false,
			},
			"git_stage_file",
			args,
			{
				git_stage = { { path = node.path, relpath = relpath } },
				guard_paths = { node.path },
				guard_relpaths = { relpath },
			}
		)
	end)
end

local function git_index_paths(node)
	local paths = { node.extra.relpath }
	local index = node.extra.index_status or (node.extra.status or ""):sub(1, 1)
	if index == "R" and node.extra.renamed_from then
		paths[#paths + 1] = node.extra.renamed_from
	end
	return paths, index
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
	local relpath = node.extra.relpath
	local paths, index = git_index_paths(node)
	local args = index == "A" and { "git", "rm", "--cached", "-f", "--" } or { "git", "restore", "--staged", "--" }
	vim.list_extend(args, paths)
	confirm_mutation(state, "Unstage " .. relpath .. " in " .. repo.name .. "?", function()
		start_simple_repo_job(
			state,
			repo,
			{
				action = "unstage_file",
				label = "Unstaging " .. relpath .. "...",
				sync_text = "Unstage",
				remote_refresh = false,
			},
			"git_unstage_file",
			args,
			{
				git_addition = index == "A" and relpath or nil,
				git_unstage = index ~= "A" and paths or nil,
			}
		)
	end)
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
	local relpath, path_err = util.relpath(repo.root, node.path)
	if not relpath or relpath ~= node.extra.relpath then
		return util.notify(
			path_err or "Selected repository entry changed; refresh and retry discard",
			vim.log.levels.WARN
		)
	end
	local section = node.extra.section
	local change_kind = node.extra.change_kind
	local status = node.extra.status or ""
	if repo.vcs == "git" and (node.extra.intent_to_add or status == " A") then
		return util.notify(
			"Discard refuses intent-to-add content not stored in Git; unstage or delete it explicitly.",
			vim.log.levels.WARN
		)
	end
	local relpaths = repo.vcs == "git" and section == "staged" and git_index_paths(node) or { relpath }
	local paths = { node.path }
	for index = 2, #relpaths do
		local path = util.normalize_literal_path(repo.root .. "/" .. relpaths[index])
		local relative, err = util.relpath(repo.root, path)
		if relative ~= relpaths[index] then
			return util.notify(err or "Rename source changed; refresh and retry discard", vim.log.levels.WARN)
		end
		paths[#paths + 1] = path
	end
	if not buffer_guard.check(repo.root, paths) then
		return
	end
	local action
	local prompt
	local args
	if repo.vcs == "git" and (section == "untracked" or change_kind == "untracked") then
		action = "delete_untracked"
		prompt = "Delete untracked " .. relpath .. " from " .. repo.name .. "?"
		args = {
			"git",
			"--literal-pathspecs",
			"status",
			"--porcelain=v1",
			"-z",
			"--untracked-files=normal",
			"--",
			relpath,
		}
	elseif repo.vcs == "git" and section == "staged" then
		action = "discard_staged"
		prompt = "Discard staged and working tree changes for "
			.. table.concat(relpaths, " and ")
			.. " in "
			.. repo.name
			.. "?"
		args = status:sub(1, 1) == "A" and { "git", "rm", "-f", "--", relpath }
			or vim.list_extend(
				{ "git", "restore", "--no-recurse-submodules", "--source=HEAD", "--staged", "--worktree", "--" },
				relpaths
			)
	elseif repo.vcs == "git" and section == "merge" then
		action = "discard_staged"
		prompt = "Restore " .. relpath .. " to HEAD, replacing index and working tree changes in " .. repo.name .. "?"
		args = { "git", "restore", "--no-recurse-submodules", "--source=HEAD", "--staged", "--worktree", "--", relpath }
	elseif repo.vcs == "git" then
		action = "discard_unstaged"
		prompt = "Discard unstaged changes for " .. relpath .. " in " .. repo.name .. "?"
		args = { "git", "restore", "--no-recurse-submodules", "--worktree", "--", relpath }
	elseif change_kind == "untracked" then
		util.notify(
			"Deleting unversioned SVN paths is not supported safely; delete the path explicitly.",
			vim.log.levels.WARN
		)
		return
	else
		action = "svn_revert"
		prompt = "Discard local SVN changes for " .. relpath .. " in " .. repo.name .. "?"
		args = { "svn", "revert", "--", util.svn_target(relpath) }
	end
	local function discard(subtrees, svn_discard)
		if not buffer_guard.check(repo.root, paths, subtrees) then
			return
		end
		confirm_mutation(state, prompt, function()
			start_simple_repo_job(
				state,
				repo,
				{
					action = action,
					label = "Discarding " .. relpath .. "...",
					sync_text = "Discard",
					remote_refresh = false,
					checktime = true,
				},
				action,
				args,
				{
					guard_modified_buffers = true,
					guard_paths = paths,
					guard_relpaths = relpaths,
					guard_subtrees = subtrees,
					svn_discard = svn_discard,
					git_addition = repo.vcs == "git" and section == "staged" and status:sub(1, 1) == "A" and relpath
						or nil,
					git_conflict = repo.vcs == "git" and section == "merge" and relpath or nil,
					git_rename_source = #relpaths > 1 and relpaths[2] or nil,
					git_intent_guard = repo.vcs == "git" and action == "discard_unstaged" and relpath or nil,
					git_head_restore = repo.vcs == "git"
							and action == "discard_staged"
							and status:sub(1, 1) ~= "A"
							and relpaths
						or nil,
					tracked_discard = action ~= "delete_untracked" and vim.tbl_map(function(index)
						return {
							path = paths[index],
							relpath = relpaths[index],
							directory = svn_discard and svn_discard.kind == "dir",
						}
					end, vim.fn.range(1, #paths)) or nil,
					git_untracked_delete = action == "delete_untracked" and { path = node.path, relpath = relpath }
						or nil,
				}
			)
		end)
	end
	if repo.vcs ~= "svn" then
		return discard(action == "delete_untracked" and paths or nil)
	end
	start_command(
		repo,
		"svn_discard_info",
		{ "svn", "info", "--xml", "--depth", "empty", "--", util.svn_target(relpath) },
		function(result, err)
			if err then
				return util.notify((tostring(err):gsub("[\r\n]+", " ")), vim.log.levels.ERROR)
			end
			local info = require("lazyvcs.backends.xml").parse_info(result.stdout)
			if not info or not info.kind or not info.schedule then
				return util.notify("Unable to classify SVN discard target; refresh and retry.", vim.log.levels.WARN)
			end
			local recursive = info.kind == "dir"
				and (info.schedule == "delete" or info.schedule == "add" or info.schedule == "replace")
			if recursive then
				prompt = "Discard SVN directory " .. relpath .. " and its descendants in " .. repo.name .. "?"
				args = { "svn", "revert", "--depth", "infinity", "--", util.svn_target(relpath) }
			end
			discard(
				recursive and paths or nil,
				{ relpath = relpath, recursive = recursive, kind = info.kind, schedule = info.schedule }
			)
		end
	)
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

	local preparing = { status = "running", action = "commit", label = "Preparing commit..." }
	session_state.set_repo_job(repo.root, preparing)
	preparing = session_state.get_repo_job(repo.root)

	model.load_repo_summary_async(repo, { remote_refresh = false }, function(args, opts, done)
		return jobs.command(repo, "commit_preflight", args, {
			owner = state,
			scope = "commit_preflight",
			priority = 100,
			timeout_ms = config.get().source_control.background.status_timeout_ms,
			output_limit_bytes = opts.output_limit_bytes,
		}, done)
	end, function(fresh, err)
		if session_state.get_repo_job(repo.root) ~= preparing then
			return
		end
		session_state.clear_repo_job(repo.root)
		if not fresh or fresh.incomplete or fresh.error then
			return util.notify(
				"Commit status failed; refresh and retry: " .. tostring(err or fresh and fresh.error),
				vim.log.levels.WARN
			)
		end
		repo = fresh
		confirm_mutation(state, "Commit changes in " .. repo.name .. "?", function()
			if repo.vcs == "git" then
				if repo.counts.staged == 0 and repo.counts.local_changes > 0 then
					picker.select({
						"Stage all and commit",
						"Cancel",
					}, {
						prompt = "No staged changes in " .. repo.name,
						snacks = {
							layout = "select",
							matcher = { sort_empty = true },
						},
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
								start_command(
									repo,
									"git_stage_all",
									{ "git", "add", "-A" },
									function(_, add_err, add_raw)
										if add_err then
											return reject(add_err, add_raw)
										end
										start_commit_command(repo, message, function(result, commit_err, commit_raw)
											if commit_err then
												return reject(commit_err, commit_raw)
											end
											resolve(result, commit_raw)
										end)
									end,
									{ git_require_resolved = true }
								)
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
						start_commit_command(repo, message, function(result, err, raw)
							if err then
								return reject(err, raw)
							end
							resolve(result, raw)
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
					start_commit_command(repo, message, function(result, err, raw)
						if err then
							return reject(err, raw)
						end
						resolve(result, raw)
					end)
				end,
			})
		end)
	end)
end

function M.focus_repo(state, node, activate_changes)
	local repo = current_repo(state, node)
	if not repo then
		return
	end

	state.lazyvcs_focused_repo = repo.root
	state.lazyvcs_repo_visibility_overrides = state.lazyvcs_repo_visibility_overrides or {}
	if state.lazyvcs_selection_mode == "single" then
		state.lazyvcs_repo_visibility_overrides = { [repo.root] = true }
	else
		state.lazyvcs_repo_visibility_overrides[repo.root] = true
	end

	if activate_changes and not repo_is_busy(repo.root) then
		repo = M.load_repo_details(state, repo.root)
		state.lazyvcs_force_expand = state.lazyvcs_force_expand or {}
		state.lazyvcs_force_expand[model.repo_changes_id(repo.root)] = true
	end

	persist.save_state(state)
	navigate(state)
end

function M.toggle_repo_visibility(state, node)
	node = node or current_node(state)
	local repo = current_repo(state, node)
	if not repo then
		return
	end

	state.lazyvcs_repo_visibility = state.lazyvcs_repo_visibility or {}
	state.lazyvcs_repo_visibility_overrides = state.lazyvcs_repo_visibility_overrides or {}
	if state.lazyvcs_selection_mode == "single" then
		state.lazyvcs_repo_visibility_overrides = { [repo.root] = true }
		state.lazyvcs_focused_repo = repo.root
	else
		local enabled = state.lazyvcs_repo_visibility[repo.root] == true
		state.lazyvcs_repo_visibility_overrides[repo.root] = not enabled
		if enabled and state.lazyvcs_focused_repo == repo.root then
			state.lazyvcs_focused_repo = nil
		elseif not enabled then
			state.lazyvcs_focused_repo = repo.root
		end
	end

	persist.save_state(state)
	navigate(state)
end

function M.collapse_repo(state, node)
	local repo = current_repo(state, node)
	if repo and repo_changes_expanded(state, node, repo) then
		return set_repo_changes_expanded(state, repo, false)
	end
end

function M.retry_repo(state, node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	state.lazyvcs_restore_details = state.lazyvcs_restore_details or {}
	state.lazyvcs_restore_details[repo.root] = true
	refresh_repo(state, repo.root, false)
end

function M.open_repo(state, node, _toggle_node)
	local repo = current_repo(state, node)
	if not repo then
		return
	end
	local expanded = repo_changes_expanded(state, node, repo)
	local busy = repo_is_busy(repo.root)
	if expanded and (repo.details_loaded or busy or repo.loading_details or repo.detail_error) then
		return set_repo_changes_expanded(state, repo, false)
	end
	if not repo.details_loaded then
		if busy then
			return
		end
		if not expanded then
			state.lazyvcs_force_expand = state.lazyvcs_force_expand or {}
			state.lazyvcs_force_expand[model.repo_changes_id(repo.root)] = true
		end
		M.load_repo_details(state, repo.root)
		return navigate(state)
	end
	if busy then
		return
	end
	return set_repo_changes_expanded(state, repo, true)
end

local function repo_actions(repo)
	local actions = {
		{ label = "Compare against base...", action = "compare" },
		{ label = "Commit", action = "commit", enabled = not repo.incomplete },
		{ label = "Generate Commit Message", action = "generate", enabled = ai.available() },
		{ label = "Refresh", action = "refresh" },
	}

	local job = current_repo_job(repo.root)
	if
		job and job.status == "error" and job.error
		or repo.error
		or repo.detail_error
		or repo.remote_error
		or ai.last_error(repo.root)
	then
		actions[#actions + 1] = { label = "Show Last Error", action = "show_error" }
	end

	if repo.vcs == "git" then
		if repo.upstream or repo.has_remotes ~= false then
			actions[#actions + 1] = { label = "Sync Changes", action = "sync" }
			actions[#actions + 1] = { label = "Pull", action = "pull" }
			actions[#actions + 1] = { label = "Push", action = "push" }
		end
		if repo.has_remotes ~= false then
			actions[#actions + 1] = { label = "Fetch", action = "fetch" }
		end
		actions[#actions + 1] = { label = "Checkout Branch or Tag...", action = "switch" }
		actions[#actions + 1] = { label = "Stage All", action = "stage_all", enabled = not repo.incomplete }
	else
		actions[#actions + 1] = { label = "Switch...", action = "switch" }
		actions[#actions + 1] = { label = "Update", action = "update" }
	end

	return vim.tbl_filter(function(item)
		return item.enabled == nil or item.enabled
	end, actions)
end

-- `:LazyVCS sidebar cancel <path>` matches jobs by root, so the argument has to
-- canonicalize the same way the job owners did.
local function normalize_cancel_root(path)
	if not path or path == "" then
		return nil
	end
	return util.canonical_path(vim.fn.fnamemodify(path, ":p"))
end

function M.cancel(path, opts)
	opts = opts or {}
	local root = normalize_cancel_root(path)
	local ai_count = 0
	for state in pairs(draft_states) do
		if opts.all_owners or opts.owner == nil or opts.owner == state then
			ai_count = ai_count + M.cancel_commit_generations(state, root)
		end
	end
	ai_count = ai_count
		+ require("lazyvcs.source_control.ai_requests").cancel(
			root,
			not opts.all_owners and opts.owner or nil,
			opts.reason
		)
	local count = jobs.cancel(function(job)
		if job.kind == "buffer" then
			return false
		end
		if root and job.root ~= root then
			return false
		end
		if not opts.all_owners then
			if opts.owner ~= nil and job.owner ~= opts.owner then
				return false
			end
			if job.scope == "hydration" then
				return opts.owner ~= nil
			end
		end
		return true
	end, opts.reason or "user")
	if root then
		local current = session_state.get_repo_job(root)
		if current and current.status == "running" and count == 0 then
			session_state.clear_repo_job(root)
		end
	elseif count == 0 then
		for _, job in ipairs(session_state.list_repo_jobs()) do
			if job.status == "running" then
				session_state.clear_repo_job(job.root)
			end
		end
	end
	return count + ai_count
end

function M.cancel_repo(state, node)
	local repo = current_repo(state, node or current_node(state))
	if not repo then
		return 0
	end
	local hydration_count = invalidate_hydration(state, repo.root, "user")
	clear_repo_details_loading(state, repo.root)
	if state.lazyvcs_diff_target_root == repo.root then
		M.cancel_diff_target(state, "user")
	end
	local count = hydration_count + M.cancel(repo.root, { owner = state })
	count = count + M.cancel(repo.root, { owner = repo.root })
	if state.lazyvcs_repaint then
		state.lazyvcs_repaint(state)
	else
		navigate_if_visible(state)
	end
	util.notify(
		count == 1 and ("Cancelled the active operation for " .. repo.name)
			or string.format("Cancelled %d operations for %s", count, repo.name),
		count > 0 and vim.log.levels.INFO or vim.log.levels.WARN
	)
	return count
end

local function execute_repo_action(state, repo, action, node)
	if action == "show_error" then
		local job = current_repo_job(repo.root)
		local errors = {}
		for _, err in pairs({
			job and job.error,
			repo.error,
			repo.detail_error,
			repo.remote_error,
			ai.last_error(repo.root),
		}) do
			if err then
				errors[#errors + 1] = tostring(err):gsub("\n$", "")
			end
		end
		if #errors > 0 then
			return util.show_text(
				"LazyVCS: Last Error",
				vim.split(table.concat(errors, "\n\n"), "\n", { plain = true })
			)
		end
		return
	end
	if action == "compare" then
		if window_exists(state) then
			vim.api.nvim_set_current_win(state.winid)
			return require("lazyvcs.compare").open({ path = repo.root })
		end
		return
	end
	if action == "cancel" then
		return M.cancel_repo(state, node)
	end
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
	local mutation_labels = {
		stage_all = "Stage all changes in " .. repo.name .. "?",
		fetch = "Fetch " .. repo.name .. "?",
		pull = "Pull " .. repo.name .. "?",
		update = "Update " .. repo.name .. "?",
		sync = repo.vcs == "svn" and ("Sync " .. repo.name .. "?") or nil,
	}
	if mutation_labels[action] then
		return confirm_mutation(state, mutation_labels[action], function()
			execute_repo_action(state, repo, "_" .. action, node)
		end)
	end
	if action:sub(1, 1) == "_" then
		action = action:sub(2)
	end
	if action == "stage_all" then
		local current = state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[repo.root] or repo
		if repo.incomplete or current.incomplete then
			return util.notify("Status incomplete; refresh before Stage All.", vim.log.levels.WARN)
		end
		if repo.vcs ~= "git" then
			util.notify("Stage all is only supported for Git", vim.log.levels.WARN)
			return
		end
		return start_simple_repo_job(
			state,
			repo,
			{
				action = "stage_all",
				label = "Staging all changes...",
				sync_text = "Stage All",
				remote_refresh = false,
			},
			"git_stage_all",
			{ "git", "add", "-A" },
			{
				status_complete = function()
					return not ((state.lazyvcs_repo_cache or {})[repo.root] or repo).incomplete
				end,
			}
		)
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
				start_command(
					repo,
					"git_fetch",
					{ "git", "fetch", "--all", "--prune", "--quiet" },
					function(result, err, raw)
						if err then
							return reject(err, raw)
						end
						resolve(result, raw)
					end
				)
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
			guard_modified_buffers = true,
			start = function(resolve, reject)
				start_git_integrate(repo, false, function(result, err, raw)
					if err then
						return reject(err, raw)
					end
					resolve(result, raw)
				end)
			end,
		})
		return
	end
	if action == "push" then
		local publishing = repo_needs_publish(repo)
		start_repo_job(state, repo, {
			action = "push",
			label = publishing and "Publishing..." or "Pushing...",
			sync_text = publishing and "Publish" or "Push",
			remote_refresh = true,
			start = function(resolve, reject)
				start_git_push(repo, function(result, err, raw)
					if err then
						return reject(err, raw)
					end
					resolve(result, raw)
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
			guard_modified_buffers = true,
			start = function(resolve, reject)
				start_command(
					repo,
					"svn_update",
					{ "svn", "update", util.svn_target(repo.root) },
					function(result, err, raw)
						if err then
							return reject(err, raw)
						end
						resolve(result, raw)
					end,
					{ guard_modified_buffers = true }
				)
			end,
		})
		return
	end
	if action == "sync" then
		if repo.vcs == "git" then
			local publishing = repo_needs_publish(repo)
			start_repo_job(state, repo, {
				action = "sync",
				label = publishing and "Publishing..." or "Syncing...",
				sync_text = publishing and "Publish" or "Sync",
				remote_refresh = true,
				checktime = true,
				start = function(resolve, reject)
					start_git_integrate(repo, true, function(result, err, raw)
						if err then
							return reject(err, raw)
						end
						resolve(result, raw)
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
				guard_modified_buffers = true,
				start = function(resolve, reject)
					start_command(
						repo,
						"svn_update",
						{ "svn", "update", util.svn_target(repo.root) },
						function(result, err, raw)
							if err then
								return reject(err, raw)
							end
							resolve(result, raw)
						end,
						{ guard_modified_buffers = true }
					)
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

	local marker = {}
	set_repo_job(state, repo.root, {
		token = marker,
		status = "running",
		action = "switch_targets",
		label = "Loading targets...",
		sync_text = "Branches",
	})
	local bg = config.get().source_control.background
	-- One generation per enumeration, established here. Bumping it inside the
	-- per-command runner below would make each step of the chain supersede the
	-- previous one and cancel the enumeration's own earlier subprocesses.
	state.lazyvcs_switch_generations = state.lazyvcs_switch_generations or {}
	local switch_scope = "switch:" .. tostring(repo.root)
	local switch_generation = (state.lazyvcs_switch_generations[switch_scope] or 0) + 1
	state.lazyvcs_switch_generations[switch_scope] = switch_generation
	return repo_switch.open_async(repo, {
		cancel_id = function(id)
			jobs.cancel(function(candidate)
				return candidate.id == id
			end, "switch targets cancelled")
		end,
		-- Check picker liveness separately; cancelled SVN callbacks can continue the
		-- enumeration chain.
		is_stale = function()
			return state.lazyvcs_tearing_down == true or not window_exists(state)
		end,
		on_complete = function()
			local current = session_state.get_repo_job(repo.root)
			if current and current.token == marker then
				session_state.clear_repo_job(repo.root)
			end
		end,
		on_ready = function()
			navigate_if_visible(state)
		end,
		before_mutation = function()
			return true
		end,
		run_mutation = function(target_repo, choice, args, mutation_opts)
			local label = choice and (choice.label or choice.short or choice.text or choice.name) or "selected target"
			confirm_mutation(state, "Switch " .. target_repo.name .. " to " .. label .. "?", function()
				local guard_worktree = not (choice and choice.preserves_worktree)
				start_repo_job(state, target_repo, {
					action = "switch",
					label = "Switching...",
					sync_text = "Switch",
					remote_refresh = false,
					checktime = true,
					close_sessions = true,
					guard_modified_buffers = guard_worktree,
					start = function(resolve, reject)
						start_command(target_repo, "switch_mutation", args, function(result, err, raw)
							if err then
								return reject(err, raw)
							end
							resolve(result, raw)
						end, {
							cwd = mutation_opts.cwd or target_repo.root,
							guard_modified_buffers = guard_worktree,
						})
					end,
					after_success = function(result)
						if type(mutation_opts.on_success) == "function" then
							mutation_opts.on_success(result)
						end
					end,
				})
			end)
		end,
		after_mutation = function() end,
	}, function(args, opts, on_done)
		-- Own enumeration with the sidebar state so teardown cancels it. Use a per-repository
		-- scope and generation to avoid stale watermarks from earlier sidebar lifetimes.
		return jobs.command(repo, opts.kind or "switch", args, {
			timeout_ms = bg.switch_timeout_ms,
			owner = state,
			generation = switch_generation,
			scope = switch_scope,
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
	if busy and job then
		return picker.select({
			{
				label = "Cancel " .. (job.label or job.sync_text or "Operation"),
				action = "cancel",
			},
		}, {
			prompt = "Operation running for " .. repo.name,
			format_item = function(item)
				return item.label
			end,
			snacks = {
				layout = "select",
				matcher = { sort_empty = true },
			},
		}, function(choice)
			if choice then
				execute_repo_action(state, repo, choice.action, node)
			end
		end)
	end
	local actions = repo_actions(repo)
	picker.select(actions, {
		prompt = "Actions for " .. repo.name,
		format_item = function(item)
			return item.label
		end,
		snacks = {
			layout = "select",
			matcher = { sort_empty = true },
		},
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
