local common = require("neo-tree.sources.common.commands")
local ops = require("lazyvcs.source_control.ops")

local M = {}

local function current_node(state)
	return state.tree and state.tree:get_node() or nil
end

M.open = function(state)
	local node = current_node(state)
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
		return ops.open_repo(state, node, common.toggle_node)
	end
	if node.type == "view_section" or node.type == "section" or node.type == "folder" then
		return common.toggle_node(state)
	end
end

M.refresh_source = function(state)
	ops.refresh(state, true)
end

M.toggle_show_clean = function(state)
	ops.toggle_show_clean(state)
end

M.toggle_repo_visibility = function(state)
	ops.toggle_repo_visibility(state)
end

M.edit_commit_message = function(state)
	ops.edit_commit_message(state)
end

M.smart_e = function(state)
	local node = current_node(state)
	if node and node.type == "commit_input" then
		return ops.edit_commit_message(state, node)
	end
	local result = common.toggle_auto_expand_width(state)
	vim.schedule(function()
		require("lazyvcs.actions").rebalance_tab(state.tabid or vim.api.nvim_get_current_tabpage())
	end)
	return result
end

M.generate_commit_message = function(state)
	ops.generate_commit_message(state)
end

M.commit_repo = function(state)
	ops.commit_repo(state)
end

M.repo_actions = function(state)
	ops.repo_action_picker(state)
end

M.switch_repo = function(state)
	ops.switch_repo(state)
end

M.sync_repo = function(state)
	ops.sync_repo(state)
end

M.stage_file = function(state)
	ops.stage_file(state)
end

M.unstage_file = function(state)
	ops.unstage_file(state)
end

M.revert_file = function(state)
	ops.revert_file(state)
end

M.toggle_changes_view_mode = function(state)
	ops.toggle_changes_view_mode(state)
end

M.cycle_changes_sort = function(state)
	ops.cycle_changes_sort(state)
end

common._add_common_commands(M)

return M
