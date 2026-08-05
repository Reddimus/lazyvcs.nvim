local M = {}

local defaults = {
	debounce_ms = 120,
	base_window = {
		width = 0.5,
		-- Keep the two panes' cursors on corresponding lines. `:diffthis` already
		-- sets 'cursorbind'; lazyvcs re-asserts it so a later ftplugin or
		-- colorscheme cannot silently unbind the pair.
		cursor_sync = true,
		-- Keep corresponding lines on the same screen row when the panes wrap.
		-- 'scrollbind' binds buffer lines, so with 'wrap' on (which needs
		-- `followwrap` in 'diffopt') a line that occupies four rows on one side
		-- and one on the other pushes everything below it out of alignment, and
		-- the error accumulates. "auto" pads the shorter side with virtual rows
		-- only while the panes actually wrap; "off" leaves native behaviour.
		align_wrapped = "auto",
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
			mutation_timeout_ms = 120000,
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

local function finite_number(name, value)
	vim.validate(name, value, "number")
	if value ~= value or value == math.huge or value == -math.huge then
		error("lazyvcs " .. name .. " must be a finite number")
	end
end

local function optional_keymap(name, value)
	if value ~= false and type(value) ~= "string" then
		error("lazyvcs " .. name .. " must be a string or false")
	end
	if type(value) == "string" and vim.trim(value) == "" then
		error("lazyvcs " .. name .. " must not be empty")
	end
end

local function warn_unknown_options(provided, known, prefix)
	if type(provided) ~= "table" or type(known) ~= "table" then
		return
	end
	for key, value in pairs(provided) do
		local path = prefix == "" and tostring(key) or (prefix .. "." .. tostring(key))
		if known[key] == nil then
			vim.notify_once("lazyvcs: unknown option '" .. path .. "'", vim.log.levels.WARN)
		elseif
			type(value) == "table"
			and type(known[key]) == "table"
			and not vim.islist(value)
			and not vim.islist(known[key])
		then
			warn_unknown_options(value, known[key], path)
		end
	end
end

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
	vim.validate("use_gitsigns", opts.use_gitsigns, "boolean")
	vim.validate("set_winbar", opts.set_winbar, "boolean")
	vim.validate("session_keymaps", opts.session_keymaps, "boolean")
	vim.validate("keymaps", opts.keymaps, "table")
	vim.validate("base_window", opts.base_window, "table")
	vim.validate("source_control", opts.source_control, "table")
	vim.validate("signs", opts.signs, "table")
	vim.validate("blame", opts.blame, "table")
	vim.validate("ai", opts.ai, "table")
	vim.validate("commit_message", opts.ai.commit_message, "table")

	vim.validate("base_window_cursor_sync", opts.base_window.cursor_sync, "boolean")
	vim.validate("base_window_align_wrapped", opts.base_window.align_wrapped, "string")
	vim.validate("signs_enabled", opts.signs.enabled, "boolean")
	vim.validate("signs_text", opts.signs.text, "table")
	vim.validate("blame_mode", opts.blame.mode, "string")
	vim.validate("blame_persist", opts.blame.persist, "boolean")
	vim.validate("blame_loading_text", opts.blame.loading_text, "string")
	vim.validate("blame_uncommitted_text", opts.blame.uncommitted_text, "string")
	vim.validate("blame_format", opts.blame.format, "string")
	vim.validate("enabled", opts.source_control.enabled, "boolean")
	vim.validate("ui", opts.source_control.ui, "string")
	vim.validate("auto_expand_width", opts.source_control.auto_expand_width, "boolean")
	vim.validate("show_clean", opts.source_control.show_clean, "boolean")
	vim.validate("confirm_mutations", opts.source_control.confirm_mutations, "boolean")
	vim.validate("remote_refresh", opts.source_control.remote_refresh, "string")
	vim.validate("sync_button_behavior", opts.source_control.sync_button_behavior, "string")
	vim.validate("always_show_repositories", opts.source_control.always_show_repositories, "boolean")
	vim.validate("selection_mode", opts.source_control.selection_mode, "string")
	vim.validate("repositories_sort", opts.source_control.repositories_sort, "string")
	vim.validate("changes_view_mode", opts.source_control.changes_view_mode, "string")
	vim.validate("changes_sort", opts.source_control.changes_sort, "string")
	vim.validate("compact_folders", opts.source_control.compact_folders, "boolean")
	vim.validate("show_action_button", opts.source_control.show_action_button, "boolean")
	vim.validate("show_input_action_button", opts.source_control.show_input_action_button, "boolean")
	vim.validate("remote_error_notifications", opts.source_control.remote_error_notifications, "string")
	vim.validate("background", opts.source_control.background, "table")
	vim.validate("commit_provider", opts.ai.commit_message.provider, "string")
	vim.validate("commit_provider_order", opts.ai.commit_message.provider_order, "table")
	vim.validate("commit_instructions", opts.ai.commit_message.instructions, "string")
	vim.validate("commit_context", opts.ai.commit_message.context, "string")
	vim.validate("commit_generate_key", opts.ai.commit_message.generate_key, "string")
	vim.validate("commit_insert_generate_key", opts.ai.commit_message.insert_generate_key, "string")
	vim.validate("commit_confirm_privacy", opts.ai.commit_message.confirm_privacy, "boolean")
	vim.validate("sign_add", opts.signs.text.add, "string")
	vim.validate("sign_change", opts.signs.text.change, "string")
	vim.validate("sign_delete", opts.signs.text.delete, "string")
	vim.validate("sign_topdelete", opts.signs.text.topdelete, "string")
	vim.validate("sign_changedelete", opts.signs.text.changedelete, "string")

	for name, value in pairs({
		debounce_ms = opts.debounce_ms,
		width = opts.base_window.width,
		signs_debounce_ms = opts.signs.debounce_ms,
		signs_sign_priority = opts.signs.sign_priority,
		signs_max_file_bytes = opts.signs.max_file_bytes,
		blame_delay_ms = opts.blame.delay_ms,
		blame_loading_delay_ms = opts.blame.loading_delay_ms,
		blame_max_width = opts.blame.max_width,
		blame_split_min_width = opts.blame.split_min_width,
		blame_split_max_width = opts.blame.split_max_width,
		scan_depth = opts.source_control.scan_depth,
		source_control_width = opts.source_control.width,
		auto_expand_max_width_ratio = opts.source_control.auto_expand_max_width_ratio,
		remote_refresh_interval_ms = opts.source_control.remote_refresh_interval_ms,
		commit_timeout_ms = opts.ai.commit_message.timeout_ms,
		commit_max_context_chars = opts.ai.commit_message.max_context_chars,
		git_workers = opts.source_control.background.git_workers,
		svn_workers = opts.source_control.background.svn_workers,
		status_timeout_ms = opts.source_control.background.status_timeout_ms,
		remote_timeout_ms = opts.source_control.background.remote_timeout_ms,
		switch_timeout_ms = opts.source_control.background.switch_timeout_ms,
		mutation_timeout_ms = opts.source_control.background.mutation_timeout_ms,
		history_limit = opts.source_control.background.history_limit,
	}) do
		finite_number(name, value)
	end

	local active_keymaps = {}
	for name, value in pairs(opts.keymaps) do
		optional_keymap("keymaps." .. name, value)
		if value ~= false then
			if active_keymaps[value] then
				error(
					string.format("lazyvcs keymaps.%s duplicates keymaps.%s (%s)", name, active_keymaps[value], value)
				)
			end
			active_keymaps[value] = name
		end
	end

	opts.debounce_ms = math.max(0, math.floor(opts.debounce_ms))
	opts.base_window.width = normalize_width(opts.base_window.width)
	if not vim.tbl_contains({ "auto", "off" }, opts.base_window.align_wrapped) then
		error("lazyvcs base_window.align_wrapped must be 'auto' or 'off'")
	end
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
	if not vim.tbl_contains({ "auto", "native" }, opts.source_control.ui) then
		error("lazyvcs source_control.ui must be 'auto' or 'native'")
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
	if not vim.islist(opts.ai.commit_message.provider_order) or #opts.ai.commit_message.provider_order == 0 then
		error("lazyvcs ai.commit_message.provider_order must be a non-empty list")
	end
	if
		not vim.tbl_contains({ "staged_first", "staged", "unstaged", "all", "status" }, opts.ai.commit_message.context)
	then
		error("lazyvcs ai.commit_message.context must be 'staged_first', 'staged', 'unstaged', 'all', or 'status'")
	end
	if vim.trim(opts.ai.commit_message.generate_key) == "" then
		error("lazyvcs ai.commit_message.generate_key must not be empty")
	end
	if vim.trim(opts.ai.commit_message.insert_generate_key) == "" then
		error("lazyvcs ai.commit_message.insert_generate_key must not be empty")
	end
	local seen_providers = {}
	for _, provider in ipairs(opts.ai.commit_message.provider_order) do
		if not vim.tbl_contains({ "copilotchat", "claude", "codex", "gemini", "copilot_cli" }, provider) then
			error("lazyvcs ai.commit_message.provider_order contains an unsupported provider")
		end
		if seen_providers[provider] then
			error("lazyvcs ai.commit_message.provider_order contains duplicate provider '" .. provider .. "'")
		end
		seen_providers[provider] = true
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
	if opts.source_control.background.mutation_timeout_ms <= 0 then
		error("lazyvcs source_control.background.mutation_timeout_ms must be greater than 0")
	end
	opts.source_control.background.mutation_timeout_ms = math.floor(opts.source_control.background.mutation_timeout_ms)
	opts.source_control.background.history_limit =
		math.min(10000, math.max(1, math.floor(opts.source_control.background.history_limit)))
	return opts
end

function M.setup(opts)
	warn_unknown_options(opts, defaults, "")
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
