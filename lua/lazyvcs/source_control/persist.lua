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

---@return table<string, any>
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
	return ok
end

function M.mark(state, key)
	state.lazyvcs_preference_changes = state.lazyvcs_preference_changes or {}
	state.lazyvcs_preference_changes[key] = true
end

function M.save_state(state)
	if not state.path or state.path == "" then
		return
	end
	local value = serialize_state(state)
	local baseline = state.lazyvcs_preferences_baseline or {}
	local changed = state.lazyvcs_preference_changes or {}
	for key in pairs(value) do
		if not vim.deep_equal(value[key], baseline[key]) then
			changed[key] = true
		end
	end
	for key in pairs(baseline) do
		if not vim.deep_equal(value[key], baseline[key]) then
			changed[key] = true
		end
	end
	if not next(changed) then
		return
	end
	local saved = normalize_preferences(M.load(state.path))
	for key in pairs(changed) do
		if key ~= "visible_repos" and key ~= "hidden_repos" then
			saved[key] = value[key]
		end
	end
	if changed.visible_repos or changed.hidden_repos then
		local function visibility(preferences)
			local result = {}
			for _, root in ipairs(preferences.visible_repos or {}) do
				result[root] = true
			end
			for _, root in ipairs(preferences.hidden_repos or {}) do
				result[root] = false
			end
			return result
		end
		local old, current, merged = visibility(baseline), visibility(value), visibility(saved)
		local roots = vim.tbl_extend("force", {}, old, current)
		for root in pairs(roots) do
			if old[root] ~= current[root] then
				merged[root] = current[root]
			end
		end
		saved.visible_repos, saved.hidden_repos = {}, {}
		for root, enabled in pairs(merged) do
			local list = enabled and saved.visible_repos or saved.hidden_repos
			list[#list + 1] = root
		end
		table.sort(saved.visible_repos)
		table.sort(saved.hidden_repos)
	end
	if M.save(state.path, saved) then
		state.lazyvcs_preferences_baseline = vim.deepcopy(value)
		state.lazyvcs_preference_changes = {}
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
	state.lazyvcs_selection_mode = nil
	state.lazyvcs_changes_view_mode = saved.changes_view_mode
	state.lazyvcs_changes_sort = saved.changes_sort
	local defaults = require("lazyvcs.config").get().source_control
	state.lazyvcs_preferences_baseline = serialize_state(state)
	for _, key in ipairs({ "show_clean", "changes_view_mode", "changes_sort" }) do
		if state.lazyvcs_preferences_baseline[key] == nil then
			state.lazyvcs_preferences_baseline[key] = defaults[key]
		end
	end
	state.lazyvcs_preference_changes = {}
end

return M
