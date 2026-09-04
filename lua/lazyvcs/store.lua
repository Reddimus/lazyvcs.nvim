-- Small persisted key/value store for lazyvcs UI preferences that should survive
-- across Neovim sessions (e.g. whether inline blame is enabled). State lives in a
-- single JSON file under stdpath("state"); writes are atomic (temp file + rename)
-- so an interrupted write can never leave a corrupt file behind.
--
-- This is intentionally separate from source_control/persist.lua, which stores
-- per-workspace sidebar layout keyed by repository root.

local json_file = require("lazyvcs.json_file")

local M = {}

local cache
local override_dir

local function state_dir()
	if override_dir then
		return override_dir
	end
	return vim.fs.normalize(vim.fn.stdpath("state") .. "/lazyvcs")
end

local function state_path()
	return state_dir() .. "/state.json"
end

local function load_cache()
	if cache ~= nil then
		return cache
	end

	cache = json_file.read(state_path())
	return cache
end

-- Warn once per session; see the matching note in source_control/persist.lua.
local warned = false

local function save_cache()
	if cache == nil then
		return
	end

	local ok, err = json_file.write(state_path(), cache)
	if not ok and not warned then
		warned = true
		require("lazyvcs.util").notify("Could not persist LazyVCS state: " .. tostring(err), vim.log.levels.WARN)
	end
end

--- Read a persisted value, returning `default` when the key is absent.
function M.get(key, default)
	local value = load_cache()[key]
	if value == nil then
		return default
	end
	if type(value) == "table" then
		return vim.deepcopy(value)
	end
	return value
end

--- Persist a value. Passing nil removes the key.
function M.set(key, value)
	local all = load_cache()
	if value == nil then
		all[key] = nil
	elseif type(value) == "table" then
		all[key] = vim.deepcopy(value)
	else
		all[key] = value
	end
	save_cache()
end

--- Absolute path of the backing state file (surfaced in :checkhealth).
function M.path()
	return state_path()
end

-- Test seam: redirect the backing directory and drop the in-memory cache so
-- specs can exercise persistence against a throwaway tempdir.
function M._test_set_dir(dir)
	override_dir = dir and vim.fs.normalize(dir) or nil
	cache = nil
end

return M
