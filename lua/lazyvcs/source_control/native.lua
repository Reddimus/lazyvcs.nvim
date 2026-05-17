local config = require("lazyvcs.config")
local jobs = require("lazyvcs.source_control.jobs")
local model = require("lazyvcs.source_control.model")
local ops = require("lazyvcs.source_control.ops")
local persist = require("lazyvcs.source_control.persist")

local M = {}

local states = {}
local ns = vim.api.nvim_create_namespace("lazyvcs_native")
local strwidth = vim.api.nvim_strwidth

local function normalize(path)
	return vim.fs.normalize(path or vim.fn.getcwd())
end

local function tabid()
	return vim.api.nvim_get_current_tabpage()
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function setup_highlights()
	vim.api.nvim_set_hl(0, "LazyVcsDisabled", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "LazyVcsBusy", { default = true, link = "DiagnosticInfo" })
end

local function truncate_right(text, max_width)
	text = text or ""
	if max_width <= 0 then
		return ""
	end
	if strwidth(text) <= max_width then
		return text
	end
	if max_width <= 3 then
		return vim.fn.strcharpart(text, 0, max_width)
	end
	local out = ""
	for index = 0, vim.fn.strchars(text) - 1 do
		local next_text = out .. vim.fn.strcharpart(text, index, 1)
		if strwidth(next_text) > max_width - 3 then
			break
		end
		out = next_text
	end
	return out .. "..."
end

local function truncate_left(text, max_width)
	text = text or ""
	if max_width <= 0 then
		return ""
	end
	if strwidth(text) <= max_width then
		return text
	end
	if max_width <= 3 then
		local chars = vim.fn.strchars(text)
		return vim.fn.strcharpart(text, math.max(0, chars - max_width), max_width)
	end
	local suffix_width = max_width - 3
	local out = ""
	for index = vim.fn.strchars(text) - 1, 0, -1 do
		local next_text = vim.fn.strcharpart(text, index, 1) .. out
		if strwidth(next_text) > suffix_width then
			break
		end
		out = next_text
	end
	return "..." .. out
end

local function compact_sync_text(sync)
	local text = sync and sync.text or ""
	local status = sync and sync.status or ""
	if text == "" then
		return ""
	end
	if status == "publish" then
		return "Pub"
	end
	return text:gsub("%s+", "")
end

local function repo_count_text(counts)
	local local_changes = counts and counts.local_changes or 0
	if local_changes <= 0 then
		return ""
	end
	return tostring(local_changes)
end

local function status_text_for_width(sync, counts, max_width)
	local full = sync and sync.text or ""
	local compact = compact_sync_text(sync)
	local count = repo_count_text(counts)
	for _, candidate in ipairs({ full, compact, count }) do
		if candidate ~= "" and strwidth(candidate) <= max_width then
			return candidate
		end
	end
	return nil
end

local function fit_right_text(text, max_width, min_width)
	text = text or ""
	min_width = min_width or 1
	if text == "" or max_width < min_width then
		return nil
	end
	if strwidth(text) <= max_width then
		return text
	end
	local truncated = truncate_left(text, max_width)
	if strwidth(truncated) < min_width then
		return nil
	end
	return truncated
end

local function compose_right_meta(primary, sync, counts, max_width)
	max_width = math.max(0, max_width or 0)
	local status = status_text_for_width(sync, counts, max_width)
	if not primary or primary == "" then
		return status or ""
	end
	if status and status ~= "" then
		local primary_budget = max_width - strwidth(status) - 1
		if primary_budget >= 8 then
			local display = fit_right_text(primary, primary_budget, 8)
			if display then
				return display .. " " .. status
			end
		end
		return status
	end
	return fit_right_text(primary, max_width, 8) or ""
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
	state.lazyvcs_hydration_generation = (state.lazyvcs_hydration_generation or 0) + 1
	state.lazyvcs_hydration_active = false
	state.lazyvcs_hydration_pending = 0
	state.lazyvcs_expanded = {}
	load_persisted_state(state, path)
end

local function icon(node)
	if node.type == "root" then
		return "󰉋"
	end
	if node.type == "repo_selector" or node.type == "repo_changes" then
		return node.extra and node.extra.vcs == "svn" and "󰘦" or "󰊢"
	end
	if node.type == "commit_input" then
		return "󰏫"
	end
	if node.type == "action_button" then
		return "󰒓"
	end
	if node.type == "view_section" or node.type == "section" then
		return "󰉋"
	end
	if node.type == "folder" then
		return ""
	end
	if node.type == "message" then
		return "󰍩"
	end
	return "󰈙"
end

local function right_meta(node, max_width)
	local extra = node.extra or {}
	if node.type == "root" then
		if extra.hydration_active and (extra.hydration_pending or 0) > 0 then
			return "󰑓"
		end
		return ""
	end
	if node.type == "repo_selector" then
		return compose_right_meta(extra.path_label, extra.sync, extra.counts, max_width)
	end
	if node.type == "repo_changes" then
		return compose_right_meta(extra.branch, extra.sync, extra.counts, max_width)
	end
	if node.type == "commit_input" and extra.show_input_action_button then
		return fit_right_text(extra.primary_label, max_width or 0, 4) or ""
	end
	if node.type == "file" and extra.status then
		return extra.status
	end
	return ""
end

local function display_name(node)
	if node.type == "repo_selector" then
		local prefix = node.extra and node.extra.visible and "● " or "○ "
		if node.extra and node.extra.focused then
			prefix = "▸ "
		end
		return prefix .. node.name
	end
	return node.name
end

local function highlight_for(node)
	if node.extra and node.extra.disabled then
		return "LazyVcsDisabled"
	end
	if node.type == "repo_selector" or node.type == "repo_changes" or node.type == "folder" then
		return "Directory"
	end
	if node.type == "commit_input" then
		return "String"
	end
	if node.type == "action_button" then
		return "Function"
	end
	return "Comment"
end

local function desired_line_width(node, depth)
	local has_children = #(node.children or {}) > 0
	local marker = has_children and "▾ " or "  "
	local left = string.rep("  ", depth) .. marker .. icon(node) .. " " .. display_name(node)
	local extra = node.extra or {}
	local meta = ""
	if node.type == "root" and extra.hydration_active and (extra.hydration_pending or 0) > 0 then
		meta = "󰑓"
	elseif node.type == "repo_selector" then
		local primary = extra.path_label or ""
		local sync = extra.sync and extra.sync.text or ""
		meta = vim.trim((primary .. " " .. sync):gsub("%s+", " "))
	elseif node.type == "repo_changes" then
		local primary = extra.branch or ""
		local sync = extra.sync and extra.sync.text or ""
		meta = vim.trim((primary .. " " .. sync):gsub("%s+", " "))
	elseif node.type == "commit_input" and extra.show_input_action_button then
		meta = extra.primary_label or ""
	elseif node.type == "file" and extra.status then
		meta = extra.status
	end
	if meta == "" then
		return strwidth(left)
	end
	return strwidth(left) + 1 + strwidth(meta)
end

local function line_for_node(node, depth, width)
	local expanded = node.is_expanded and node:is_expanded() or false
	local has_children = #(node.children or {}) > 0
	local marker = has_children and (expanded and "▾ " or "▸ ") or "  "
	local left = string.rep("  ", depth) .. marker .. icon(node) .. " " .. display_name(node)
	local left_width = strwidth(left)
	if left_width >= width then
		return truncate_right(left, width)
	end

	local meta_budget = width - left_width - 1
	local meta = right_meta(node, meta_budget)
	if meta == "" then
		return left
	end
	local padding = width - left_width - strwidth(meta)
	if padding < 1 then
		return left
	end
	return left .. string.rep(" ", padding) .. meta
end

local function capture_view(state)
	if not valid_win(state.winid) then
		return nil
	end
	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, state.winid)
	if not ok then
		return nil
	end
	local node = state.lazyvcs_line_nodes and state.lazyvcs_line_nodes[cursor[1]] or nil
	local view
	pcall(vim.api.nvim_win_call, state.winid, function()
		view = vim.fn.winsaveview()
	end)
	return {
		node_id = node and node.id or nil,
		lnum = cursor[1],
		col = cursor[2],
		view = view,
	}
end

local function line_for_node_id(state, node_id)
	if not node_id then
		return nil
	end
	for line, node in pairs(state.lazyvcs_line_nodes or {}) do
		if node.id == node_id then
			return line
		end
	end
	return nil
end

local function restore_view(state, saved)
	if not saved or not valid_win(state.winid) then
		return
	end
	local current_win = vim.api.nvim_get_current_win()
	pcall(vim.api.nvim_win_call, state.winid, function()
		if saved.view then
			pcall(vim.fn.winrestview, saved.view)
		end
		local line_count = math.max(1, vim.api.nvim_buf_line_count(state.bufnr))
		local lnum = line_for_node_id(state, saved.node_id) or math.min(saved.lnum or 1, line_count)
		local line = vim.api.nvim_buf_get_lines(state.bufnr, lnum - 1, lnum, false)[1] or ""
		vim.api.nvim_win_set_cursor(state.winid, { lnum, math.min(saved.col or 0, #line) })
	end)
	if valid_win(current_win) and vim.api.nvim_get_current_win() ~= current_win then
		pcall(vim.api.nvim_set_current_win, current_win)
	end
end

local function attach_node_methods(state, node)
	node.is_expanded = function(current)
		return state.lazyvcs_expanded[current.id] == true
	end
	return node
end

local function apply_force_expand(state, node)
	if not node then
		return
	end
	if state.lazyvcs_force_expand and state.lazyvcs_force_expand[node.id] then
		state.lazyvcs_expanded[node.id] = true
		state.lazyvcs_force_expand[node.id] = nil
		if node.type == "repo_changes" then
			for _, child in ipairs(node.children or {}) do
				if child.type == "section" then
					state.lazyvcs_expanded[child.id] = true
				end
			end
		end
	end
	for _, child in ipairs(node.children or {}) do
		apply_force_expand(state, child)
	end
end

local function add_line(state, lines, marks, node, depth, width)
	attach_node_methods(state, node)
	local expanded = state.lazyvcs_expanded[node.id] == true
	local has_children = #(node.children or {}) > 0
	state.lazyvcs_longest_line_width = math.max(state.lazyvcs_longest_line_width or 0, desired_line_width(node, depth))
	lines[#lines + 1] = line_for_node(node, depth, width)
	marks[#lines] = { node = node, highlight = highlight_for(node) }
	if not has_children or not expanded then
		return
	end
	for _, child in ipairs(node.children or {}) do
		add_line(state, lines, marks, child, depth + 1, width)
	end
end

local function sidebar_width(state)
	if valid_win(state.winid) then
		return vim.api.nvim_win_get_width(state.winid)
	end
	return config.get().source_control.width
end

local function max_auto_width()
	local source_opts = config.get().source_control
	return math.max(20, math.floor(vim.o.columns * source_opts.auto_expand_max_width_ratio))
end

local function auto_width_target(state)
	local source_opts = config.get().source_control
	local base_width = state.lazyvcs_last_user_width or source_opts.width
	local desired = (state.lazyvcs_longest_line_width or base_width) + 1
	return math.min(max_auto_width(), math.max(base_width, desired))
end

local function maybe_apply_auto_width(state)
	if not valid_win(state.winid) or not state.lazyvcs_auto_expand_width then
		return false
	end
	local target = auto_width_target(state)
	if target == vim.api.nvim_win_get_width(state.winid) then
		return false
	end
	vim.api.nvim_win_set_width(state.winid, target)
	return true
end

local function build_lines(state, root)
	local width = math.max(20, sidebar_width(state))
	local lines = {}
	local marks = {}
	state.lazyvcs_longest_line_width = 0
	add_line(state, lines, marks, root, 0, width)
	return lines, marks
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

local function start_summary_hydration(state, remote_refresh)
	if state.lazyvcs_hydration_active then
		return
	end
	local specs = state.lazyvcs_repo_specs or {}
	if #specs == 0 then
		return
	end

	local queue = {}
	for _, repo in ipairs(specs) do
		local cached = state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[repo.root] or nil
		if (remote_refresh or not (cached and cached.summary_loaded)) and not (cached and cached.loading_summary) then
			queue[#queue + 1] = repo
		end
	end
	if #queue == 0 then
		return
	end

	state.lazyvcs_hydration_generation = (state.lazyvcs_hydration_generation or 0) + 1
	local generation = state.lazyvcs_hydration_generation
	state.lazyvcs_hydration_active = true
	state.lazyvcs_hydration_pending = #queue
	state.lazyvcs_repo_cache = state.lazyvcs_repo_cache or {}
	for _, repo in ipairs(queue) do
		local previous = state.lazyvcs_repo_cache[repo.root] or {}
		state.lazyvcs_repo_cache[repo.root] = vim.tbl_extend("force", model.make_placeholder(repo, previous), {
			loading_summary = true,
			refreshing_summary = previous.summary_loaded == true,
		})
	end
	M.render(state)

	local bg = config.get().source_control.background
	for _, repo in ipairs(queue) do
		local previous = state.lazyvcs_repo_cache[repo.root] or nil
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
			if state.lazyvcs_hydration_generation ~= generation then
				return
			end
			state.lazyvcs_hydration_pending = math.max(0, (state.lazyvcs_hydration_pending or 1) - 1)
			local cached = state.lazyvcs_repo_cache and state.lazyvcs_repo_cache[repo.root] or nil
			state.lazyvcs_repo_cache[repo.root] = summary or model.make_error(repo, cached, err)
			if state.lazyvcs_hydration_pending == 0 then
				state.lazyvcs_hydration_active = false
			end
			M.render(state)
		end)
	end
end

local function current_node(state)
	if not valid_win(state.winid) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(state.winid)[1]
	return state.lazyvcs_line_nodes and state.lazyvcs_line_nodes[lnum] or nil
end

local function node_can_expand(node)
	return node
		and (node.type == "root" or node.type == "view_section" or node.type == "section" or node.type == "folder")
end

local function toggle_node(state)
	local node = current_node(state)
	local node_id = node and node.id or nil
	if not node_can_expand(node) or not node_id then
		return
	end
	state.lazyvcs_expanded[node_id] = not state.lazyvcs_expanded[node_id]
	M.render(state)
end

local function rebalance_tab_later(state)
	vim.schedule(function()
		local ok, actions = pcall(require, "lazyvcs.actions")
		if ok and actions.rebalance_tab then
			pcall(actions.rebalance_tab, state.tabid or vim.api.nvim_get_current_tabpage())
		end
	end)
end

local function toggle_auto_expand_width(state)
	if not valid_win(state.winid) then
		return
	end
	if state.lazyvcs_auto_expand_width then
		state.lazyvcs_auto_expand_width = false
		local width = state.lazyvcs_last_user_width or config.get().source_control.width
		vim.api.nvim_win_set_width(state.winid, width)
		M.render(state)
		rebalance_tab_later(state)
		return
	end
	state.lazyvcs_last_user_width = vim.api.nvim_win_get_width(state.winid)
	state.lazyvcs_auto_expand_width = true
	M.render(state)
	rebalance_tab_later(state)
end

local function bind(bufnr, lhs, rhs, desc)
	vim.keymap.set("n", lhs, rhs, { buffer = bufnr, nowait = true, silent = true, desc = desc })
end

local function setup_buffer(state)
	setup_highlights()
	local bufnr = state.bufnr
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].buflisted = false
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].filetype = "lazyvcs-source-control"

	bind(bufnr, "q", function()
		M.close()
	end, "Close lazyvcs source control")
	bind(bufnr, "<cr>", function()
		M.dispatch("open")
	end, "Open lazyvcs node")
	bind(bufnr, "l", function()
		M.dispatch("open")
	end, "Open lazyvcs node")
	bind(bufnr, "h", function()
		toggle_node(state)
	end, "Close lazyvcs node")
	bind(bufnr, "<space>", function()
		M.dispatch("toggle_repo_visibility")
	end, "Toggle repository visibility")
	bind(bufnr, "<tab>", function()
		M.dispatch("toggle_repo_visibility")
	end, "Toggle repository visibility")
	bind(bufnr, "R", function()
		M.dispatch("refresh_source")
	end, "Refresh source control")
	bind(bufnr, "e", function()
		M.dispatch("smart_e")
	end, "Edit commit message or auto-fit width")
	bind(bufnr, "H", function()
		M.dispatch("toggle_show_clean")
	end, "Toggle clean repositories")
	bind(bufnr, "s", function()
		M.dispatch("sync_repo")
	end, "Repository actions")
	bind(bufnr, ".", function()
		M.dispatch("repo_actions")
	end, "Repository actions")
	bind(bufnr, "c", function()
		M.dispatch("commit_repo")
	end, "Commit repository")
	bind(bufnr, "b", function()
		M.dispatch("switch_repo")
	end, "Switch branch or target")
	bind(bufnr, "gm", function()
		M.dispatch("generate_commit_message")
	end, "Generate commit message")
	bind(bufnr, "ga", function()
		M.dispatch("stage_file")
	end, "Stage file")
	bind(bufnr, "gu", function()
		M.dispatch("unstage_file")
	end, "Unstage file")
	bind(bufnr, "gr", function()
		M.dispatch("revert_file")
	end, "Revert file")
	bind(bufnr, "v", function()
		M.dispatch("toggle_changes_view_mode")
	end, "Toggle changes view")
	bind(bufnr, "S", function()
		M.dispatch("cycle_changes_sort")
	end, "Cycle changes sort")
end

local function ensure_window(state, opts)
	opts = opts or {}
	if valid_win(state.winid) and valid_buf(state.bufnr) then
		if opts.focus ~= false then
			vim.api.nvim_set_current_win(state.winid)
		end
		return
	end
	local current = vim.api.nvim_get_current_win()
	state.editor_winid = current
	local source_opts = config.get().source_control
	vim.cmd("topleft " .. source_opts.width .. "vsplit")
	state.winid = vim.api.nvim_get_current_win()
	state.lazyvcs_last_user_width = state.lazyvcs_last_user_width or source_opts.width
	if not valid_buf(state.bufnr) then
		state.bufnr = vim.api.nvim_create_buf(false, true)
		setup_buffer(state)
	end
	vim.api.nvim_win_set_buf(state.winid, state.bufnr)
	vim.wo[state.winid].number = false
	vim.wo[state.winid].relativenumber = false
	vim.wo[state.winid].signcolumn = "no"
	vim.wo[state.winid].foldcolumn = "0"
	vim.wo[state.winid].wrap = false
	vim.wo[state.winid].cursorline = true
	if opts.focus == false and valid_win(current) then
		vim.api.nvim_set_current_win(current)
	end
end

function M.render(state)
	state = state or states[tabid()]
	if not state or not valid_buf(state.bufnr) then
		return
	end
	local saved_view = capture_view(state)
	state.lazyvcs_commit_drafts = state.lazyvcs_commit_drafts or {}
	local root = model.collect(state, {
		root = state.path,
		scan_depth = config.get().source_control.scan_depth,
	})
	state.lazyvcs_expanded[root.id] = true
	for _, child in ipairs(root.children or {}) do
		state.lazyvcs_expanded[child.id] = state.lazyvcs_expanded[child.id] ~= false
	end
	apply_force_expand(state, root)

	local lines, marks = build_lines(state, root)
	if maybe_apply_auto_width(state) then
		lines, marks = build_lines(state, root)
	end
	state.lazyvcs_line_nodes = {}
	for index, mark in ipairs(marks) do
		state.lazyvcs_line_nodes[index] = mark.node
	end

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
	vim.bo[state.bufnr].modifiable = false
	vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)
	for index, mark in ipairs(marks) do
		vim.api.nvim_buf_add_highlight(state.bufnr, ns, mark.highlight, index - 1, 0, -1)
	end
	restore_view(state, saved_view)
end

function M.navigate(state)
	state = state or states[tabid()]
	if not state or not valid_buf(state.bufnr) then
		return
	end
	M.render(state)
	local remote_refresh = state.lazyvcs_remote_refresh
	state.lazyvcs_remote_refresh = nil
	start_summary_hydration(state, remote_refresh)
	return state
end

local function prepare_state(path)
	local id = tabid()
	local state = states[id] or {}
	states[id] = state
	state.tabid = id
	state.path = normalize(path or state.path or vim.fn.getcwd())
	state.lazyvcs_confirm_mutations = config.get().source_control.confirm_mutations
	if state.lazyvcs_auto_expand_width == nil then
		state.lazyvcs_auto_expand_width = config.get().source_control.auto_expand_width
	end
	state.lazyvcs_render = M.navigate
	state.lazyvcs_window_exists = function(current)
		return valid_win(current.winid)
	end
	state.lazyvcs_get_node = current_node
	state.lazyvcs_open_file = function(_, path_to_open)
		if valid_win(state.editor_winid) and state.editor_winid ~= state.winid then
			vim.api.nvim_set_current_win(state.editor_winid)
		else
			vim.cmd("wincmd l")
			if vim.api.nvim_get_current_win() == state.winid then
				vim.cmd("rightbelow split")
			end
			state.editor_winid = vim.api.nvim_get_current_win()
		end
		vim.cmd.edit(vim.fn.fnameescape(path_to_open))
	end
	reset_for_path(state, state.path)
	if not state.lazyvcs_repo_specs then
		state.lazyvcs_repo_specs = model.discover(state.path, config.get().source_control.scan_depth)
	end
	return state
end

function M.open(opts)
	opts = opts or {}
	local state = prepare_state(opts.path or opts.root)
	ensure_window(state, { focus = opts.focus })
	state.lazyvcs_remote_refresh = should_remote_refresh(state)
	M.navigate(state)
	return state
end

function M.close()
	local state = states[tabid()]
	if state and valid_win(state.winid) then
		save_state(state)
		vim.api.nvim_win_close(state.winid, true)
		state.winid = nil
	end
end

function M.toggle(opts)
	local state = states[tabid()]
	if state and valid_win(state.winid) then
		M.close()
		return
	end
	return M.open(opts)
end

function M.refresh(remote_refresh)
	local state = states[tabid()]
	if not state then
		return M.open()
	end
	state.lazyvcs_repo_cache = {}
	state.lazyvcs_loading_details = {}
	state.lazyvcs_hydration_active = false
	state.lazyvcs_hydration_generation = (state.lazyvcs_hydration_generation or 0) + 1
	state.lazyvcs_remote_refresh = remote_refresh ~= false
	save_state(state)
	M.navigate(state)
end

function M.dispatch(action)
	local state = states[tabid()]
	if not state then
		return
	end
	local node = current_node(state)
	if action == "open" then
		if not node then
			return
		end
		if node.type == "file" then
			return ops.open_change(state, node)
		end
		if node.type == "commit_input" then
			return ops.edit_commit_message(state, node)
		end
		if node.type == "action_button" then
			return ops.run_primary_action(state, node)
		end
		if node.type == "repo_selector" then
			return ops.focus_repo(state, node, true)
		end
		if node.type == "repo_changes" then
			return ops.open_repo(state, node, toggle_node)
		end
		return toggle_node(state)
	end
	if action == "refresh_source" then
		return M.refresh(true)
	end
	if action == "smart_e" then
		if node and node.type == "commit_input" then
			return ops.edit_commit_message(state, node)
		end
		return toggle_auto_expand_width(state)
	end
	if action == "toggle_show_clean" then
		return ops.toggle_show_clean(state)
	end
	if action == "toggle_repo_visibility" then
		if node_can_expand(node) then
			return toggle_node(state)
		end
		return ops.toggle_repo_visibility(state, node)
	end
	if action == "toggle_changes_view_mode" then
		return ops.toggle_changes_view_mode(state)
	end
	if action == "cycle_changes_sort" then
		return ops.cycle_changes_sort(state)
	end
	if action == "sync_repo" then
		return ops.sync_repo(state, node)
	end
	if action == "repo_actions" then
		return ops.repo_action_picker(state, node)
	end
	if action == "commit_repo" then
		return ops.commit_repo(state, node)
	end
	if action == "switch_repo" then
		return ops.switch_repo(state, node)
	end
	if action == "generate_commit_message" then
		return ops.generate_commit_message(state, node)
	end
	if action == "stage_file" then
		return ops.stage_file(state, node)
	end
	if action == "unstage_file" then
		return ops.unstage_file(state, node)
	end
	if action == "revert_file" then
		return ops.revert_file(state, node)
	end
end

function M._state()
	return states[tabid()]
end

M._test_should_remote_refresh = should_remote_refresh

return M
