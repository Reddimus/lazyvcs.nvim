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
	signs = {
		enabled = true,
		debounce_ms = 120,
		sign_priority = 6,
		max_file_bytes = 1024 * 1024,
		text = {
			add = "┃",
			change = "┃",
			delete = "_",
			topdelete = "‾",
			changedelete = "~",
		},
	},
	blame = {
		mode = "inline",
		persist = true,
		delay_ms = 150,
		loading_delay_ms = 750,
		loading_text = "Blame loading...",
		uncommitted_text = "Uncommitted line",
		format = "{author}, {date} - r{revision}",
		max_width = 80,
		split_min_width = 20,
		split_max_width = 34,
	},
	compat = {
		svnsigns_commands = true,
	},
	source_control = {
		enabled = true,
		ui = "auto",
		scan_depth = 3,
		width = 38,
		auto_expand_width = false,
		auto_expand_max_width_ratio = 0.5,
		show_clean = false,
		confirm_mutations = true,
		remote_refresh = "manual",
		remote_refresh_interval_ms = 60000,
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
			provider_order = { "copilotchat", "claude", "codex", "gemini", "copilot_cli" },
			instructions = "",
			timeout_ms = 30000,
			max_context_chars = 12000,
			context = "staged_first",
			generate_key = "gm",
			insert_generate_key = "<C-g>",
			confirm_privacy = true,
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
		signs = { opts.signs, "table" },
		blame = { opts.blame, "table" },
		compat = { opts.compat, "table" },
		ai = { opts.ai, "table" },
	})

	vim.validate({
		close = { opts.keymaps.close, "string" },
		next_hunk = { opts.keymaps.next_hunk, "string" },
		prev_hunk = { opts.keymaps.prev_hunk, "string" },
		revert_hunk = { opts.keymaps.revert_hunk, "string" },
		width = { opts.base_window.width, "number" },
		signs_enabled = { opts.signs.enabled, "boolean" },
		signs_debounce_ms = { opts.signs.debounce_ms, "number" },
		signs_sign_priority = { opts.signs.sign_priority, "number" },
		signs_max_file_bytes = { opts.signs.max_file_bytes, "number" },
		signs_text = { opts.signs.text, "table" },
		blame_mode = { opts.blame.mode, "string" },
		blame_persist = { opts.blame.persist, "boolean" },
		blame_delay_ms = { opts.blame.delay_ms, "number" },
		blame_loading_delay_ms = { opts.blame.loading_delay_ms, "number" },
		blame_loading_text = { opts.blame.loading_text, "string" },
		blame_uncommitted_text = { opts.blame.uncommitted_text, "string" },
		blame_format = { opts.blame.format, "string" },
		blame_max_width = { opts.blame.max_width, "number" },
		blame_split_min_width = { opts.blame.split_min_width, "number" },
		blame_split_max_width = { opts.blame.split_max_width, "number" },
		compat_svnsigns_commands = { opts.compat.svnsigns_commands, "boolean" },
		enabled = { opts.source_control.enabled, "boolean" },
		ui = { opts.source_control.ui, "string" },
		scan_depth = { opts.source_control.scan_depth, "number" },
		source_control_width = { opts.source_control.width, "number" },
		auto_expand_width = { opts.source_control.auto_expand_width, "boolean" },
		auto_expand_max_width_ratio = { opts.source_control.auto_expand_max_width_ratio, "number" },
		show_clean = { opts.source_control.show_clean, "boolean" },
		confirm_mutations = { opts.source_control.confirm_mutations, "boolean" },
		remote_refresh = { opts.source_control.remote_refresh, "string" },
		remote_refresh_interval_ms = { opts.source_control.remote_refresh_interval_ms, "number" },
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
		commit_provider_order = { opts.ai.commit_message.provider_order, "table" },
		commit_instructions = { opts.ai.commit_message.instructions, "string" },
		commit_timeout_ms = { opts.ai.commit_message.timeout_ms, "number" },
		commit_max_context_chars = { opts.ai.commit_message.max_context_chars, "number" },
		commit_context = { opts.ai.commit_message.context, "string" },
		commit_generate_key = { opts.ai.commit_message.generate_key, "string" },
		commit_insert_generate_key = { opts.ai.commit_message.insert_generate_key, "string" },
		commit_confirm_privacy = { opts.ai.commit_message.confirm_privacy, "boolean" },
	})
	vim.validate({
		sign_add = { opts.signs.text.add, "string" },
		sign_change = { opts.signs.text.change, "string" },
		sign_delete = { opts.signs.text.delete, "string" },
		sign_topdelete = { opts.signs.text.topdelete, "string" },
		sign_changedelete = { opts.signs.text.changedelete, "string" },
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
	opts.signs.debounce_ms = math.max(0, math.floor(opts.signs.debounce_ms))
	opts.signs.sign_priority = math.max(1, math.floor(opts.signs.sign_priority))
	opts.signs.max_file_bytes = math.max(0, math.floor(opts.signs.max_file_bytes))
	if not vim.tbl_contains({ "inline", "split", "off" }, opts.blame.mode) then
		error("lazyvcs blame.mode must be 'inline', 'split', or 'off'")
	end
	opts.blame.delay_ms = math.max(0, math.floor(opts.blame.delay_ms))
	opts.blame.loading_delay_ms = math.max(0, math.floor(opts.blame.loading_delay_ms))
	opts.blame.max_width = math.max(10, math.floor(opts.blame.max_width))
	opts.blame.split_min_width = math.max(10, math.floor(opts.blame.split_min_width))
	opts.blame.split_max_width = math.max(opts.blame.split_min_width, math.floor(opts.blame.split_max_width))
	if not vim.tbl_contains({ "auto", "native", "neo-tree" }, opts.source_control.ui) then
		error("lazyvcs source_control.ui must be 'auto', 'native', or legacy 'neo-tree'")
	end
	opts.source_control.scan_depth = math.max(1, math.floor(opts.source_control.scan_depth))
	opts.source_control.width = math.max(20, math.floor(opts.source_control.width))
	opts.source_control.auto_expand_max_width_ratio =
		math.min(1, math.max(0.1, opts.source_control.auto_expand_max_width_ratio))
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
	if
		not vim.tbl_contains(
			{ "auto", "copilotchat", "claude", "codex", "gemini", "copilot_cli", "off" },
			opts.ai.commit_message.provider
		)
	then
		error("lazyvcs ai.commit_message.provider must be 'auto', a supported provider, or 'off'")
	end
	if not vim.tbl_contains({ "staged_first" }, opts.ai.commit_message.context) then
		error("lazyvcs ai.commit_message.context must be 'staged_first'")
	end
	for _, provider in ipairs(opts.ai.commit_message.provider_order) do
		if not vim.tbl_contains({ "copilotchat", "claude", "codex", "gemini", "copilot_cli" }, provider) then
			error("lazyvcs ai.commit_message.provider_order contains an unsupported provider")
		end
	end
	opts.ai.commit_message.timeout_ms = math.max(0, math.floor(opts.ai.commit_message.timeout_ms))
	opts.ai.commit_message.max_context_chars = math.max(1000, math.floor(opts.ai.commit_message.max_context_chars))
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
	local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	if opts and opts.ai and opts.ai.commit_message and opts.ai.commit_message.provider_order then
		merged.ai.commit_message.provider_order = vim.deepcopy(opts.ai.commit_message.provider_order)
	end
	options = normalize(merged)
	return options
end

function M.get()
	return options
end

return M
