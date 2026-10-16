local util = require("lazyvcs.util")
local json_file = require("lazyvcs.json_file")

local M = {}

local function state_path()
	return util.normalize_literal_path(vim.fn.stdpath("state") .. "/lazyvcs/source_control.json")
end

local function project_path(root)
	return util.normalize_literal_path(
		vim.fn.stdpath("state") .. "/lazyvcs/source_control/" .. vim.fn.sha256(root) .. ".json"
	)
end

local function normalize_preferences(value)
	value = type(value) == "table" and value or {}
	local result = {}
	for _, key in ipairs({ "visible_repos", "hidden_repos" }) do
		result[key] = {}
		if type(value[key]) == "table" then
			for _, root in ipairs(value[key]) do
				if type(root) == "string" and root ~= "" then
					result[key][#result[key] + 1] = root
				end
			end
		end
	end
	if type(value.focused_repo) == "string" then
		result.focused_repo = value.focused_repo
	end
	if type(value.show_clean) == "boolean" then
		result.show_clean = value.show_clean
	end
	for key, allowed in pairs({
		selection_mode = { "single", "multiple" },
		changes_view_mode = { "list", "tree" },
		changes_sort = { "path", "name", "status" },
	}) do
		if vim.tbl_contains(allowed, value[key]) then
			result[key] = value[key]
		end
	end
	return result
end

local warned = false

local function warn(err)
	if not warned then
		warned = true
		util.notify(
			"Could not persist source-control layout: " .. tostring(err):gsub("[\r\n]+", " "),
			vim.log.levels.WARN
		)
	end
end

local function serialize_state(state)
	local visible = {}
	local hidden = {}
	for root, enabled in pairs(state.lazyvcs_repo_visibility_overrides or {}) do
		if enabled then
			visible[#visible + 1] = root
		elseif enabled == false then
			hidden[#hidden + 1] = root
		end
	end
	table.sort(visible)
	table.sort(hidden)

	return {
		visible_repos = visible,
		hidden_repos = hidden,
		focused_repo = state.lazyvcs_focused_repo,
		show_clean = state.lazyvcs_show_clean,
		selection_mode = state.lazyvcs_selection_mode,
		changes_view_mode = state.lazyvcs_changes_view_mode,
		changes_sort = state.lazyvcs_changes_sort,
	}
end

function M.load(root)
	root = util.normalize_literal_path(root)
	local path = project_path(root)
	if vim.uv.fs_stat(path) then
		local entry = json_file.read(path)
		return normalize_preferences(entry.root == root and entry.preferences or nil)
	end
	return normalize_preferences(json_file.read(state_path())[root])
end

function M.save(root, value)
	root = util.normalize_literal_path(root)
	local path = project_path(root)
	local stored_root = vim.uv.fs_stat(path) and json_file.read(path).root or nil
	if type(stored_root) == "string" and stored_root ~= root then
		warn("Stored project root does not match " .. root)
		return
	end
	local ok, err = json_file.write(path, { root = root, preferences = normalize_preferences(value) })
	if not ok then
		warn(err)
	end
end

function M.save_state(state)
	if state.path and state.path ~= "" then
		M.save(state.path, serialize_state(state))
	end
end

function M.apply_state(state, path)
	local saved = normalize_preferences(M.load(path))
	state.lazyvcs_repo_visibility = {}
	state.lazyvcs_repo_visibility_overrides = {}
	for _, root in ipairs(saved.visible_repos or {}) do
		state.lazyvcs_repo_visibility_overrides[root] = true
	end
	for _, root in ipairs(saved.hidden_repos or {}) do
		state.lazyvcs_repo_visibility_overrides[root] = false
	end
	state.lazyvcs_focused_repo = saved.focused_repo
	state.lazyvcs_show_clean = saved.show_clean
	state.lazyvcs_selection_mode = saved.selection_mode
	state.lazyvcs_changes_view_mode = saved.changes_view_mode
	state.lazyvcs_changes_sort = saved.changes_sort
end

return M
