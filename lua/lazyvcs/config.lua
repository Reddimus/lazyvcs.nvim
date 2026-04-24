local M = {}

local defaults = {
	debounce_ms = 120,
	base_window = {
		width = 0.5,
	},
	use_gitsigns = true,
	set_winbar = true,
	session_keymaps = true,
	keymaps = {
		close = "q",
		next_hunk = "]v",
		prev_hunk = "[v",
		revert_hunk = "<leader>vr",
	},
	source_control = {
		enabled = true,
		scan_depth = 3,
		show_clean = false,
		remote_refresh = "manual",
		remote_refresh_interval_ms = 60000,
		selector_label = "VCS",
		sync_button_behavior = "picker",
		always_show_repositories = false,
		selection_mode = "multiple",
		repositories_sort = "discovery_time",
		changes_view_mode = "list",
		changes_sort = "path",
		compact_folders = true,
		show_action_button = true,
		show_input_action_button = true,
		remote_error_notifications = "summary",
		background = {
			git_workers = 4,
			svn_workers = 1,
			status_timeout_ms = 30000,
			remote_timeout_ms = 30000,
			switch_timeout_ms = 30000,
			mutation_timeout_ms = 0,
			history_limit = 100,
		},
	},
	ai = {
		commit_message = {
			provider = "copilotchat",
		},
	},
}

local options = vim.deepcopy(defaults)

local function normalize_width(width)
	if width <= 0 then
		error("lazyvcs base_window.width must be greater than 0")
	end

	if width <= 1 then
		return width
	end

	return math.floor(width)
end

local function normalize(opts)
	vim.validate({
		debounce_ms = { opts.debounce_ms, "number" },
		use_gitsigns = { opts.use_gitsigns, "boolean" },
		set_winbar = { opts.set_winbar, "boolean" },
		session_keymaps = { opts.session_keymaps, "boolean" },
		keymaps = { opts.keymaps, "table" },
		base_window = { opts.base_window, "table" },
		source_control = { opts.source_control, "table" },
		ai = { opts.ai, "table" },
	})

	vim.validate({
		close = { opts.keymaps.close, "string" },
		next_hunk = { opts.keymaps.next_hunk, "string" },
		prev_hunk = { opts.keymaps.prev_hunk, "string" },
		revert_hunk = { opts.keymaps.revert_hunk, "string" },
		width = { opts.base_window.width, "number" },
		enabled = { opts.source_control.enabled, "boolean" },
		scan_depth = { opts.source_control.scan_depth, "number" },
		show_clean = { opts.source_control.show_clean, "boolean" },
		remote_refresh = { opts.source_control.remote_refresh, "string" },
		remote_refresh_interval_ms = { opts.source_control.remote_refresh_interval_ms, "number" },
		selector_label = { opts.source_control.selector_label, "string" },
		sync_button_behavior = { opts.source_control.sync_button_behavior, "string" },
		always_show_repositories = { opts.source_control.always_show_repositories, "boolean" },
		selection_mode = { opts.source_control.selection_mode, "string" },
		repositories_sort = { opts.source_control.repositories_sort, "string" },
		changes_view_mode = { opts.source_control.changes_view_mode, "string" },
		changes_sort = { opts.source_control.changes_sort, "string" },
		compact_folders = { opts.source_control.compact_folders, "boolean" },
		show_action_button = { opts.source_control.show_action_button, "boolean" },
		show_input_action_button = { opts.source_control.show_input_action_button, "boolean" },
		remote_error_notifications = { opts.source_control.remote_error_notifications, "string" },
		background = { opts.source_control.background, "table" },
		commit_provider = { opts.ai.commit_message.provider, "string" },
	})
	vim.validate({
		git_workers = { opts.source_control.background.git_workers, "number" },
		svn_workers = { opts.source_control.background.svn_workers, "number" },
		status_timeout_ms = { opts.source_control.background.status_timeout_ms, "number" },
		remote_timeout_ms = { opts.source_control.background.remote_timeout_ms, "number" },
		switch_timeout_ms = { opts.source_control.background.switch_timeout_ms, "number" },
		mutation_timeout_ms = { opts.source_control.background.mutation_timeout_ms, "number" },
		history_limit = { opts.source_control.background.history_limit, "number" },
	})

	opts.debounce_ms = math.max(0, math.floor(opts.debounce_ms))
	opts.base_window.width = normalize_width(opts.base_window.width)
	opts.source_control.scan_depth = math.max(1, math.floor(opts.source_control.scan_depth))
	opts.source_control.remote_refresh_interval_ms =
		math.max(0, math.floor(opts.source_control.remote_refresh_interval_ms))
	if not vim.tbl_contains({ "manual", "on_open" }, opts.source_control.remote_refresh) then
		error("lazyvcs source_control.remote_refresh must be 'manual' or 'on_open'")
	end
	if not vim.tbl_contains({ "single", "multiple" }, opts.source_control.selection_mode) then
		error("lazyvcs source_control.selection_mode must be 'single' or 'multiple'")
	end
	if not vim.tbl_contains({ "discovery_time", "name", "path" }, opts.source_control.repositories_sort) then
		error("lazyvcs source_control.repositories_sort must be 'discovery_time', 'name', or 'path'")
	end
	if not vim.tbl_contains({ "list", "tree" }, opts.source_control.changes_view_mode) then
		error("lazyvcs source_control.changes_view_mode must be 'list' or 'tree'")
	end
	if not vim.tbl_contains({ "path", "name", "status" }, opts.source_control.changes_sort) then
		error("lazyvcs source_control.changes_sort must be 'path', 'name', or 'status'")
	end
	if not vim.tbl_contains({ "picker", "direct" }, opts.source_control.sync_button_behavior) then
		error("lazyvcs source_control.sync_button_behavior must be 'picker' or 'direct'")
	end
	if not vim.tbl_contains({ "summary", "inline", "notify" }, opts.source_control.remote_error_notifications) then
		error("lazyvcs source_control.remote_error_notifications must be 'summary', 'inline', or 'notify'")
	end
	opts.source_control.background.git_workers = math.max(1, math.floor(opts.source_control.background.git_workers))
	opts.source_control.background.svn_workers = math.max(1, math.floor(opts.source_control.background.svn_workers))
	opts.source_control.background.status_timeout_ms =
		math.max(0, math.floor(opts.source_control.background.status_timeout_ms))
	opts.source_control.background.remote_timeout_ms =
		math.max(0, math.floor(opts.source_control.background.remote_timeout_ms))
	opts.source_control.background.switch_timeout_ms =
		math.max(0, math.floor(opts.source_control.background.switch_timeout_ms))
	opts.source_control.background.mutation_timeout_ms =
		math.max(0, math.floor(opts.source_control.background.mutation_timeout_ms))
	opts.source_control.background.history_limit = math.max(1, math.floor(opts.source_control.background.history_limit))
	return opts
end

function M.setup(opts)
	options = normalize(vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {}))
	return options
end

function M.get()
	return options
end

return M
