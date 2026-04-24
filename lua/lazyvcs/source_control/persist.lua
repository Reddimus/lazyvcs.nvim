local M = {}

local cache

local function state_path()
	return vim.fs.normalize(vim.fn.stdpath("state") .. "/lazyvcs/source_control.json")
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
	local fd = vim.uv.fs_open(path, "w", 420)
	if not fd then
		return
	end

	local ok, encoded = pcall(vim.json.encode, cache)
	if ok and encoded then
		vim.uv.fs_write(fd, encoded, 0)
	end
	vim.uv.fs_close(fd)
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

return M
