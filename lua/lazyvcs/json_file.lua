local fs = require("lazyvcs.fs")

local M = {}

local VERSION = 1

function M.read(path)
	local stat = vim.uv.fs_stat(path)
	if not stat or stat.type ~= "file" then
		return {}
	end
	local fd = vim.uv.fs_open(path, "r", 420)
	if not fd then
		return {}
	end
	local data = vim.uv.fs_read(fd, stat.size, 0)
	vim.uv.fs_close(fd)
	if not data or data == "" then
		return {}
	end

	local ok, decoded = pcall(vim.json.decode, data)
	if not ok or type(decoded) ~= "table" then
		return {}
	end
	if decoded.version == VERSION and type(decoded.data) == "table" then
		return decoded.data
	end
	-- v0.4.x stored the data table directly. Treat it as schema version zero and
	-- migrate it on the next successful write.
	if decoded.version == nil then
		return decoded
	end
	return {}
end

function M.write(path, value)
	local ok, encoded = pcall(vim.json.encode, {
		version = VERSION,
		data = value or {},
	})
	if not ok or not encoded then
		return nil, "Could not encode persisted LazyVCS state"
	end

	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local suffix = string.format(".tmp.%d.%d", vim.fn.getpid(), vim.uv.hrtime())
	local tmp = path .. suffix
	local fd, open_err = vim.uv.fs_open(tmp, "w", 384)
	if not fd then
		return nil, open_err or "Could not open temporary state file"
	end
	local written, write_err = fs.write_all(fd, encoded, 0)
	if written then
		pcall(vim.uv.fs_fsync, fd)
	end
	vim.uv.fs_close(fd)
	if not written then
		pcall(vim.uv.fs_unlink, tmp)
		return nil, write_err or "Could not write temporary state file"
	end
	local renamed, rename_err = vim.uv.fs_rename(tmp, path)
	if not renamed then
		pcall(vim.uv.fs_unlink, tmp)
		return nil, rename_err or "Could not replace persisted state"
	end
	return true
end

return M
