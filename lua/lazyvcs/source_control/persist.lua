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

local function save_cache()
	if cache == nil then
		return
	end

	json_file.write(state_path(), cache)
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

function M._test_reset()
	cache = nil
end

return M
