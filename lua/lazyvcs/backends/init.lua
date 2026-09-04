-- Backend dispatch.
--
-- Callers must go through this module rather than requiring `backends.git` or
-- `backends.svn` directly, so every feature works identically in both VCSes.
local util = require("lazyvcs.util")
local Task = require("lazyvcs.backends.task")

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

---Return only a still-valid cached resolution. This never spawns a process.
function M.resolve_cached(path)
	local key = util.dir_of(path)
	local hit = probe_cache[key]
	if not hit then
		return nil
	end
	if hit.backend then
		return hit.backend, hit.root
	end
	if vim.uv.now() - hit.at < NEGATIVE_TTL_MS then
		return nil, nil, hit.err
	end
	probe_cache[key] = nil
	return nil
end

---Asynchronously resolve the backend owning `path`.
---The callback receives `(backend, root, err)`.
function M.resolve_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	local key = util.dir_of(path)
	local hit = probe_cache[key]
	if hit ~= nil then
		if hit.backend then
			vim.schedule(function()
				task:finish(hit.backend, hit.root, nil)
			end)
			return task
		end
		if vim.uv.now() - hit.at < NEGATIVE_TTL_MS then
			vim.schedule(function()
				task:finish(nil, nil, hit.err)
			end)
			return task
		end
		probe_cache[key] = nil
	end

	local pending = #backends
	local best
	local errors = {}
	local function completed(backend, info, err)
		if info and info.root and (not best or #info.root > #best.root) then
			best = { backend = backend, root = info.root }
		elseif err and err ~= "" then
			errors[#errors + 1] = err
		end
		pending = pending - 1
		if pending > 0 then
			return
		end
		if best then
			probe_cache[key] = best
			return task:finish(best.backend, best.root, nil)
		end
		local generic = "No Git or SVN working copy found for " .. path
		local err = #errors == 0 and generic or (generic .. ": " .. table.concat(errors, "; "))
		probe_cache[key] = { err = err, at = vim.uv.now() }
		task:finish(nil, nil, err)
	end

	for _, backend in ipairs(backends) do
		task:add(backend.probe_async(key, function(info, err)
			completed(backend, info, err)
		end, opts))
	end
	return task
end

--- Full session payload for the live diff (base lines, tracked state, labels).
function M.load(path)
	local backend, _, err = M.resolve(path)
	if not backend then
		return nil, err
	end
	return backend.load(path)
end

---Asynchronous full session payload. No synchronous repository probe occurs.
function M.load_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.resolve_async(path, function(backend, _, err)
		if not task:is_active() then
			return
		end
		if not backend then
			return task:finish(nil, err)
		end
		task:add(backend.load_async(path, function(result, load_err)
			task:finish(result, load_err)
		end, opts))
	end, opts))
	return task
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
function M.load_base_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.resolve_async(path, function(backend, _, err)
		if not task:is_active() then
			return
		end
		if not backend then
			return task:finish(nil, err)
		end
		task:add(backend.load_base_async(path, function(result, load_err)
			task:finish(result, load_err)
		end, opts))
	end, opts))
	return task
end

function M.blame_lines_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.resolve_async(path, function(backend, _, err)
		if not task:is_active() then
			return
		end
		if not backend then
			return task:finish(nil, err)
		end
		task:add(backend.blame_lines_async(path, function(result, load_err, root)
			task:finish(result, load_err, root)
		end, opts))
	end, opts))
	return task
end

function M.line_revision_async(path, line_number, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.resolve_async(path, function(backend, _, err)
		if not task:is_active() then
			return
		end
		if not backend then
			return task:finish(nil, err)
		end
		task:add(backend.line_revision_async(path, line_number, function(revision, load_err)
			task:finish(revision, load_err)
		end, opts))
	end, opts))
	return task
end

function M.revision_log_async(path, revision, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.resolve_async(path, function(backend, _, err)
		if not task:is_active() then
			return
		end
		if not backend then
			return task:finish(nil, err)
		end
		task:add(backend.revision_log_async(path, revision, function(lines, load_err)
			task:finish(lines, load_err)
		end, opts))
	end, opts))
	return task
end

function M.changed_files_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.resolve_async(path, function(backend, _, err)
		if not task:is_active() then
			return
		end
		if not backend then
			return task:finish(nil, err)
		end
		task:add(backend.changed_files_async(path, function(items, load_err)
			task:finish(items, load_err)
		end, opts))
	end, opts))
	return task
end

function M.revert_file_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.resolve_async(path, function(backend, _, err)
		if not task:is_active() then
			return
		end
		if not backend then
			return task:finish(nil, err)
		end
		task:add(backend.revert_file_async(path, function(result, revert_err)
			task:finish(result, revert_err)
		end, opts))
	end, opts))
	return task
end

function M.is_versioned_async(path, on_done, opts)
	opts = opts or {}
	local task = Task.new(on_done)
	task:add(M.resolve_async(path, function(backend, _, err)
		if not task:is_active() then
			return
		end
		if not backend then
			return task:finish(false, err)
		end
		task:add(backend.is_versioned_async(path, function(versioned, check_err)
			task:finish(versioned, check_err)
		end, opts))
	end, opts))
	return task
end

local function normalize_target(target)
	if target and target.extra then
		return vim.tbl_extend("keep", vim.deepcopy(target.extra), {
			path = target.path,
			name = target.name,
		})
	end
	return vim.deepcopy(target or {})
end

---Resolve a source-control file item into a typed, backend-specific comparison.
function M.resolve_diff_target(target)
	target = normalize_target(target)
	local backend
	if target.vcs == "git" then
		backend = git
	elseif target.vcs == "svn" then
		backend = svn
	elseif target.path then
		backend = M.resolve(target.path)
	end
	if not backend then
		return nil, "Diff target requires a Git or SVN backend"
	end
	return backend.resolve_diff_target(target)
end

---Load all immutable sides of a typed comparison. Worktree sides remain paths so
---the caller can attach the user's live buffer.
function M.load_diff_target_async(target, on_done, opts)
	opts = opts or {}
	target = normalize_target(target)
	local task = Task.new(on_done)
	local function load(backend)
		local comparison, err = backend.resolve_diff_target(target)
		if not comparison then
			return task:finish(nil, err)
		end
		task:add(backend.load_diff_target_async(comparison, function(result, load_err)
			task:finish(result, load_err)
		end, opts))
	end
	if target.vcs == "git" then
		load(git)
	elseif target.vcs == "svn" then
		load(svn)
	elseif target.path then
		task:add(M.resolve_async(target.path, function(backend, root, err)
			if not task:is_active() then
				return
			end
			if not backend then
				return task:finish(nil, err)
			end
			target.root = target.root or root
			target.repo_root = target.repo_root or root
			target.vcs = backend.name
			load(backend)
		end, opts))
	else
		vim.schedule(function()
			task:finish(nil, "Diff target requires vcs or path")
		end)
	end
	return task
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
