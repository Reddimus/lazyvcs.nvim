-- Backend dispatch.
--
-- Callers must go through this module rather than requiring `backends.git` or
-- `backends.svn` directly, so every feature works identically in both VCSes.
local util = require("lazyvcs.util")

local git = require("lazyvcs.backends.git")
local svn = require("lazyvcs.backends.svn")

local M = {}

local backends = { git, svn }

-- Resolving a backend costs one process per backend (`git rev-parse`, `svn info`).
-- That used to run on every call, including per-keystroke sign refreshes. Cache
-- the answer per directory; `M.invalidate` clears it on directory changes.
local probe_cache = {}

-- How long a "no working copy here" answer stays cached.
local NEGATIVE_TTL_MS = 5000

function M.invalidate()
	probe_cache = {}
end

--- Resolve the backend owning `path`.
--- The deepest root wins, so a Git checkout nested inside an SVN working copy
--- (or vice versa) resolves to the inner one.
---@return table|nil backend, string|nil root, string|nil err
function M.resolve(path)
	-- dir_of, not dirname: callers also pass directories (buffer_ops falls back to
	-- the cwd for non-file buffers), and dirname would probe the PARENT of a
	-- working copy, so a repo root resolved to "no working copy found".
	local key = util.dir_of(path)
	local hit = probe_cache[key]
	if hit ~= nil then
		if hit.backend then
			return hit.backend, hit.root
		end
		-- Negative results expire: a directory can become a working copy mid-session
		-- (`git init`, a clone, a checkout). Caching those forever left signs, diff
		-- and blame dead there until :cd or a restart, while re-probing every time
		-- would spawn git+svn on each BufEnter in non-repo directories.
		if vim.uv.now() - hit.at < NEGATIVE_TTL_MS then
			return nil, nil, hit.err
		end
		probe_cache[key] = nil
	end

	local best
	for _, backend in ipairs(backends) do
		local info = backend.probe(key)
		if info and (not best or #info.root > #best.root) then
			best = { backend = backend, root = info.root }
		end
	end

	if not best then
		local err = "No Git or SVN working copy found for " .. path
		probe_cache[key] = { err = err, at = vim.uv.now() }
		return nil, nil, err
	end

	probe_cache[key] = best
	return best.backend, best.root
end

--- Full session payload for the live diff (base lines, tracked state, labels).
function M.load(path)
	local backend, _, err = M.resolve(path)
	if not backend then
		return nil, err
	end
	return backend.load(path)
end

-- Thin dispatchers. Each mirrors the identically named backend function.
local function dispatch(fn_name)
	return function(path, ...)
		local backend, _, err = M.resolve(path)
		if not backend then
			return nil, err
		end
		local fn = backend[fn_name]
		if not fn then
			return nil, string.format("%s does not support %s", backend.name, fn_name)
		end
		return fn(path, ...)
	end
end

M.load_base = dispatch("load_base")
M.blame_lines = dispatch("blame_lines")
M.revert_file = dispatch("revert_file")
M.line_revision = dispatch("line_revision")
M.revision_log = dispatch("revision_log")

--- Async variants report failure through `on_done(nil, err)` rather than returning.
function M.load_base_async(path, on_done)
	local backend, _, err = M.resolve(path)
	if not backend then
		vim.schedule(function()
			on_done(nil, err)
		end)
		return nil
	end
	return backend.load_base_async(path, on_done)
end

function M.blame_lines_async(path, on_done)
	local backend, _, err = M.resolve(path)
	if not backend then
		vim.schedule(function()
			on_done(nil, err)
		end)
		return nil
	end
	return backend.blame_lines_async(path, on_done)
end

--- Backend name ("git"/"svn") owning `path`, or nil.
function M.name_for(path)
	local backend = M.resolve(path)
	return backend and backend.name or nil
end

function M.root(path)
	local backend, root, err = M.resolve(path)
	if not backend then
		return nil, err
	end
	return root
end

function M.is_versioned(path)
	local backend = M.resolve(path)
	if not backend then
		return false
	end
	return backend.is_versioned(path)
end

--- Changed files for the working copy containing `path`.
---@return table[]|nil items, string|nil err
function M.changed_files(path)
	local backend, root, err = M.resolve(path)
	if not backend then
		return nil, err
	end
	return backend.changed_files(root)
end

function M.revert_hunk(session, hunk)
	local impl = session and session.backend_impl
	if not impl or not impl.revert_hunk then
		return false
	end
	return impl.revert_hunk(session, hunk)
end

-- Keep the resolved backend accurate when the user changes directory.
vim.api.nvim_create_autocmd("DirChanged", {
	group = vim.api.nvim_create_augroup("lazyvcs_backends", { clear = true }),
	callback = M.invalidate,
})

return M
