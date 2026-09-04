local json_file = require("lazyvcs.json_file")

local M = {}

local cache

local function state_path()
	return vim.fs.normalize(vim.fn.stdpath("state") .. "/lazyvcs/source_control.json")
end

local function load_cache()
	if cache ~= nil then
		return cache
	end

	cache = json_file.read(state_path())
	return cache
end

-- Warn once per session on a persistence failure. `json_file.write` returns
-- `nil, err` and both persistence layers used to discard it, so an unwritable
-- state directory produced settings that silently never persisted and no way to
-- tell that from "the feature does not work". Once, because this runs on every
-- sidebar layout change and a repeated notification would be worse than the bug.
local warned = false

local function save_cache()
	if cache == nil then
		return
	end

	local ok, err = json_file.write(state_path(), cache)
	if not ok and not warned then
		warned = true
		require("lazyvcs.util").notify(
			"Could not persist source-control layout: " .. tostring(err),
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
	root = vim.fs.normalize(root)
	local all = load_cache()
	local entry = all[root]
	if type(entry) ~= "table" then
		return {}
	end
	return vim.deepcopy(entry)
end

function M.save(root, value)
	root = vim.fs.normalize(root)
	local all = load_cache()
	all[root] = vim.deepcopy(value or {})
	save_cache()
end

function M.save_state(state)
	if state.path and state.path ~= "" then
		M.save(state.path, serialize_state(state))
	end
end

function M.apply_state(state, path)
	local saved = M.load(path)
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
