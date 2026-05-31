-- Small persisted key/value store for lazyvcs UI preferences that should survive
-- across Neovim sessions (e.g. whether inline blame is enabled). State lives in a
-- single JSON file under stdpath("state"); writes are atomic (temp file + rename)
-- so an interrupted write can never leave a corrupt file behind.
--
-- This is intentionally separate from source_control/persist.lua, which stores
-- per-workspace sidebar layout keyed by repository root.

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

	cache = {}
	local path = state_path()
	local stat = vim.uv.fs_stat(path)
	if not stat then
		return cache
	end

	local fd = vim.uv.fs_open(path, "r", 420)
	if not fd then
		return cache
	end

	local data = vim.uv.fs_read(fd, stat.size, 0)
	vim.uv.fs_close(fd)
	if not data or data == "" then
		return cache
	end

	local ok, decoded = pcall(vim.json.decode, data)
	if ok and type(decoded) == "table" then
		cache = decoded
	end
	return cache
end

local function save_cache()
	if cache == nil then
		return
	end

	local path = state_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

	local ok, encoded = pcall(vim.json.encode, cache)
	if not ok or not encoded then
		return
	end

	-- Write to a sibling temp file then rename over the target so readers always
	-- observe either the old or the new file, never a partial write.
	local tmp = path .. ".tmp"
	local fd = vim.uv.fs_open(tmp, "w", 420)
	if not fd then
		return
	end
	vim.uv.fs_write(fd, encoded, 0)
	vim.uv.fs_close(fd)
	if not vim.uv.fs_rename(tmp, path) then
		pcall(vim.uv.fs_unlink, tmp)
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
