local config = require("lazyvcs.config")
local jobs = require("lazyvcs.source_control.jobs")
local model = require("lazyvcs.source_control.model")
local persist = require("lazyvcs.source_control.persist")
local renderer = require("neo-tree.ui.renderer")
local manager = require("neo-tree.sources.manager")
local events = require("neo-tree.events")
local utils = require("neo-tree.utils")

local M = {
	name = "lazyvcs_source_control",
	display_name = " 󰊢 VCS ",
	default_config = {
		bind_to_cwd = true,
		window = {
			mappings = {
				["<space>"] = "toggle_repo_visibility",
				["<2-LeftMouse>"] = "open",
				["<cr>"] = "open",
				["<esc>"] = "close_window",
				["P"] = "none",
				["<C-f>"] = "none",
				["<C-b>"] = "none",
				["l"] = "open",
				["S"] = "cycle_changes_sort",
				["h"] = "close_node",
				["t"] = "none",
				["w"] = "none",
				["C"] = "close_node",
				["z"] = "none",
				["H"] = "toggle_show_clean",
				["R"] = "refresh_source",
				["a"] = "none",
				["A"] = "none",
				["d"] = "none",
				["r"] = "none",
				["y"] = "none",
				["x"] = "none",
				["p"] = "none",
				["<C-r>"] = "none",
				["e"] = "smart_e",
				["c"] = "commit_repo",
				["m"] = "none",
				["gm"] = "generate_commit_message",
				["b"] = "switch_repo",
				["s"] = "sync_repo",
				["ga"] = "stage_file",
				["gu"] = "unstage_file",
				["gr"] = "revert_file",
				["."] = "repo_actions",
				["v"] = "toggle_changes_view_mode",
				["<tab>"] = "toggle_repo_visibility",
				["q"] = "close_window",
				["?"] = "show_help",
				["<"] = "prev_source",
				[">"] = "next_source",
			},
		},
		renderers = {
			root = {
				{ "indent" },
				{ "icon" },
				{
					"container",
					width = "100%",
					content = {
						{ "name", zindex = 10 },
						{ "root_meta", zindex = 20, align = "right" },
					},
				},
			},
			view_section = {
				{ "indent", with_expanders = true },
				{ "icon" },
				{ "name", zindex = 10 },
			},
			repo_selector = {
				{ "indent" },
				{ "icon" },
				{
					"container",
					width = "100%",
					content = {
						{ "name", zindex = 10 },
						{ "repo_selector_meta", zindex = 20, align = "right" },
					},
				},
			},
			repo_changes = {
				{ "indent", with_markers = true },
				{ "icon" },
				{
					"container",
					width = "100%",
					content = {
						{ "name", zindex = 10 },
						{ "repo_changes_meta", zindex = 20, align = "right" },
					},
				},
			},
			commit_input = {
				{ "indent" },
				{ "icon" },
				{
					"container",
					width = "100%",
					content = {
						{ "name", zindex = 10 },
						{ "input_hint", zindex = 20, align = "right" },
					},
				},
			},
			action_button = {
				{ "indent" },
				{ "icon" },
				{ "name", zindex = 10 },
			},
			section = {
				{ "indent", with_expanders = true },
				{ "icon" },
				{ "name", zindex = 10 },
			},
			folder = {
				{ "indent", with_expanders = true },
				{ "icon" },
				{ "name", zindex = 10 },
			},
			file = {
				{ "indent" },
				{ "icon" },
				{
					"container",
					width = "100%",
					content = {
						{ "name", zindex = 10 },
						{ "change_status", zindex = 20, align = "right" },
					},
				},
			},
			message = {
				{ "indent", with_markers = false },
				{ "icon" },
				{ "name", zindex = 10 },
			},
		},
	},
}

local function refresh_visible(remote_refresh)
	utils.debounce("lazyvcs_source_control_refresh", function()
		manager._for_each_state(M.name, function(state)
			if state.path and renderer.window_exists(state) then
				state.lazyvcs_remote_refresh = remote_refresh
				manager.navigate(state, state.path, nil, nil, false)
			end
		end)
	end, 150, utils.debounce_strategy.CALL_LAST_ONLY)
end

local function refresh_hydration(state, immediate)
	if immediate then
		manager.navigate(state, state.path, nil, nil, false)
		return
	end

	utils.debounce("lazyvcs_source_control_hydration_" .. tostring(state.tabid or 0), function()
		if state.path and renderer.window_exists(state) then
			manager.navigate(state, state.path, nil, nil, false)
		end
	end, 150, utils.debounce_strategy.CALL_LAST_ONLY)
end

local function setup_highlights()
	vim.api.nvim_set_hl(0, "LazyVcsRepo", { link = "Directory", default = true })
	vim.api.nvim_set_hl(0, "LazyVcsCommit", { link = "String", default = true })
	vim.api.nvim_set_hl(0, "LazyVcsAction", { link = "Function", default = true })
	vim.api.nvim_set_hl(0, "LazyVcsSection", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "LazyVcsBusy", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "LazyVcsDisabled", { link = "Comment", default = true })
end

local function should_remote_refresh(state)
	if state.lazyvcs_remote_refresh ~= nil then
		if state.lazyvcs_remote_refresh then
			state.lazyvcs_last_remote_refresh_at = state.lazyvcs_last_remote_refresh_at or {}
			state.lazyvcs_last_remote_refresh_at[state.path] = vim.uv.now()
		end
		return state.lazyvcs_remote_refresh
	end
	local source_opts = config.get().source_control
	if source_opts.remote_refresh ~= "on_open" then
		return false
	end

	local now = vim.uv.now()
	local interval = source_opts.remote_refresh_interval_ms
	state.lazyvcs_last_remote_refresh_at = state.lazyvcs_last_remote_refresh_at or {}
	local last = state.lazyvcs_last_remote_refresh_at[state.path]
	if last and interval > 0 and now - last < interval then
		return false
	end
	state.lazyvcs_last_remote_refresh_at[state.path] = now
	return true
end

local function invalidate_hydration(state)
	state.lazyvcs_hydration_generation = (state.lazyvcs_hydration_generation or 0) + 1
	state.lazyvcs_hydration_active = false
	state.lazyvcs_hydration_queue = nil
	state.lazyvcs_hydration_remote = nil
	state.lazyvcs_hydration_pending = 0
	state.lazyvcs_hydration_errors = {}
	local generation = state.lazyvcs_hydration_generation
	jobs.cancel(function(job)
		return job.scope == "hydration" and job.generation and job.generation < generation
	end)
end

local function load_persisted_state(state, path)
	local saved = persist.load(path)
	state.lazyvcs_repo_visibility = {}
	for _, root in ipairs(saved.visible_repos or {}) do
		state.lazyvcs_repo_visibility[root] = true
	end
	state.lazyvcs_focused_repo = saved.focused_repo
	state.lazyvcs_show_clean = saved.show_clean
	state.lazyvcs_selection_mode = saved.selection_mode
	state.lazyvcs_changes_view_mode = saved.changes_view_mode
	state.lazyvcs_changes_sort = saved.changes_sort
end

local function reset_for_path(state, path)
	if state.lazyvcs_repo_root == path then
		return
	end
	state.lazyvcs_repo_root = path
	state.lazyvcs_repo_specs = nil
	state.lazyvcs_repo_cache = {}
	state.lazyvcs_loading_details = {}
	state.lazyvcs_force_expand = nil
	invalidate_hydration(state)
	load_persisted_state(state, path)
end

local function force_expanded_nodes(state, root)
	local expanded = { root.id }
	for _, child in ipairs(root.children or {}) do
		expanded[#expanded + 1] = child.id
	end
	local extra = state.lazyvcs_force_expand or {}
	for id, enabled in pairs(extra) do
		if enabled then
			expanded[#expanded + 1] = id
		end
	end
	state.lazyvcs_force_expand = nil
	return expanded
end

local function start_summary_hydration(state, remote_refresh, follow_remote_refresh)
	if state.lazyvcs_hydration_active then
		return
	end
	local specs = state.lazyvcs_repo_specs or {}
	if #specs == 0 then
		return
	end

	local visible = state.lazyvcs_repo_visibility or {}
	local focused = state.lazyvcs_focused_repo
	local queue = {}
	local deferred = {}
	for _, repo in ipairs(specs) do
		local cached = state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[repo.root] or nil
		if (remote_refresh or not (cached and cached.summary_loaded)) and not (cached and cached.loading_summary) then
			if repo.root == focused then
				table.insert(queue, 1, repo)
			elseif visible[repo.root] then
				queue[#queue + 1] = repo
			else
				deferred[#deferred + 1] = repo
			end
		end
	end
	vim.list_extend(queue, deferred)
	if #queue == 0 then
		return
	end

	invalidate_hydration(state)
	state.lazyvcs_hydration_active = true
	state.lazyvcs_hydration_remote = remote_refresh
	state.lazyvcs_hydration_pending = #queue
	state.lazyvcs_hydration_errors = {}
	local generation = state.lazyvcs_hydration_generation
	local bg = config.get().source_control.background

	state.lazyvcs_repo_cache = state.lazyvcs_repo_cache or {}
	for _, repo in ipairs(queue) do
		local previous = state.lazyvcs_repo_cache[repo.root] or {}
		state.lazyvcs_repo_cache[repo.root] = vim.tbl_extend("force", model.make_placeholder(repo, previous), {
			loading_summary = true,
			refreshing_summary = previous.summary_loaded == true,
		})
	end
	refresh_hydration(state, true)

	local function finish_one(repo, summary, err)
		if state.lazyvcs_hydration_generation ~= generation or state.lazyvcs_repo_root ~= state.path then
			return
		end
		if not renderer.window_exists(state) then
			state.lazyvcs_hydration_active = false
			jobs.cancel(function(job)
				return job.scope == "hydration" and job.generation == generation
			end)
			return
		end
		state.lazyvcs_hydration_pending = math.max(0, (state.lazyvcs_hydration_pending or 1) - 1)
		local previous = state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[repo.root] or nil
		state.lazyvcs_repo_cache[repo.root] = summary or model.make_error(repo, previous, err)
		if err then
			state.lazyvcs_hydration_errors[#state.lazyvcs_hydration_errors + 1] = repo.name .. ": " .. err
			if remote_refresh and config.get().source_control.remote_error_notifications == "notify" then
				require("lazyvcs.util").notify(repo.name .. ": " .. err, vim.log.levels.WARN)
			end
		end
		if state.lazyvcs_hydration_pending == 0 then
			state.lazyvcs_hydration_active = false
			refresh_hydration(state, true)
			local errors = state.lazyvcs_hydration_errors or {}
			state.lazyvcs_hydration_errors = {}
			if
				remote_refresh
				and #errors > 0
				and config.get().source_control.remote_error_notifications == "summary"
			then
				local suffix = #errors == 1 and errors[1] or (#errors .. " repositories failed")
				require("lazyvcs.util").notify("VCS remote refresh failed: " .. suffix, vim.log.levels.WARN)
			end
			if follow_remote_refresh then
				start_summary_hydration(state, true, false)
			end
		else
			refresh_hydration(state, false)
		end
	end

	for _, repo in ipairs(queue) do
		local previous = state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[repo.root] or nil
		model.load_repo_summary_async(repo, {
			previous = previous or {},
			remote_refresh = remote_refresh,
			status_timeout_ms = bg.status_timeout_ms,
			remote_timeout_ms = bg.remote_timeout_ms,
		}, function(args, opts, on_done)
			jobs.command(repo, opts.kind, args, {
				timeout_ms = opts.timeout_ms,
				generation = generation,
				scope = "hydration",
				priority = remote_refresh and -10 or 0,
			}, on_done)
		end, function(summary, err)
			finish_one(repo, summary, err)
		end)
	end
end

M.navigate = function(state, path, path_to_reveal, callback, async)
	state.dirty = false
	state.path = vim.fs.normalize(path or manager.get_cwd(state) or vim.fn.getcwd())
	state.lazyvcs_commit_drafts = state.lazyvcs_commit_drafts or {}
	reset_for_path(state, state.path)

	if not state.lazyvcs_repo_specs then
		state.lazyvcs_repo_specs = model.discover(state.path, config.get().source_control.scan_depth)
	end

	if path_to_reveal then
		renderer.position.set(state, path_to_reveal)
	end

	local root = model.collect(state, {
		root = state.path,
		scan_depth = config.get().source_control.scan_depth,
	})
	state.default_expanded_nodes = force_expanded_nodes(state, root)
	local remote_refresh = should_remote_refresh(state)
	state.lazyvcs_remote_refresh = nil
	renderer.show_nodes({ root }, state)
	start_summary_hydration(state, remote_refresh == true and false or remote_refresh, remote_refresh == true)

	if type(callback) == "function" then
		vim.schedule(callback)
	end
end

M.setup = function(source_config, global_config)
	setup_highlights()

	if source_config.bind_to_cwd then
		manager.subscribe(M.name, {
			event = events.VIM_DIR_CHANGED,
			handler = function()
				refresh_visible(false)
			end,
		})
	end

	manager.subscribe(M.name, {
		event = events.VIM_BUFFER_CHANGED,
		handler = function(args)
			if args.afile == "" or utils.is_real_file(args.afile) then
				refresh_visible(false)
			end
		end,
	})

	manager.subscribe(M.name, {
		event = events.GIT_EVENT,
		handler = function()
			refresh_visible(false)
		end,
	})

	manager.subscribe(M.name, {
		event = events.NEO_TREE_WINDOW_AFTER_CLOSE,
		handler = function(args)
			if not args or args.source ~= M.name then
				return
			end
			manager._for_each_state(M.name, function(state)
				if not args.tabid or state.tabid == args.tabid then
					invalidate_hydration(state)
				end
			end)
		end,
	})

	if global_config.enable_diagnostics then
		manager.subscribe(M.name, {
			event = events.VIM_DIAGNOSTIC_CHANGED,
			handler = function()
				refresh_visible(false)
			end,
		})
	end
end

M._test_should_remote_refresh = should_remote_refresh

return M
