-- Dispatch Git/SVN operations here so callers support both backends.
local util = require("lazyvcs.util")
local Task = require("lazyvcs.backends.task")

local git = require("lazyvcs.backends.git")
local svn = require("lazyvcs.backends.svn")

local M = {}

local backends = { git, svn }
local rank = { [git] = 1, [svn] = 2 }

-- Resolving a backend costs one process per backend (`git rev-parse`, `svn info`).
-- That used to run on every call, including per-keystroke sign refreshes. Cache
-- the answer per absolute directory; revalidation detects changed ownership.
local probe_cache = {}
local probe_order, probe_cursor = {}, 0
local in_flight = {}
local cache_generation = 0
local checked_at = {}

local function cache_put(key, value)
	if not probe_cache[key] then
		probe_cursor = probe_cursor % 512 + 1
		local previous = probe_order[probe_cursor]
		if previous then
			probe_cache[previous], checked_at[previous] = nil, nil
		end
		probe_order[probe_cursor] = key
	end
	probe_cache[key] = value
end

-- How long a "no working copy here" answer stays cached.
local NEGATIVE_TTL_MS = 5000

function M.invalidate(path)
	util.invalidate_git_entries()
	if path then
		local key = util.dir_of(vim.fs.abspath(path))
		probe_cache[key], checked_at[key] = nil, nil
		local shared = in_flight[key]
		if shared then
			shared.stale = true
		end
		for slot, entry in pairs(probe_order) do
			if entry == key then
				probe_order[slot] = false
			end
		end
		in_flight[key] = nil
		return
	end
	probe_cache = {}
	checked_at = {}
	probe_order, probe_cursor = {}, 0
	cache_generation = cache_generation + 1
	in_flight = {}
end

--- Resolve the backend owning `path`.
--- The deepest root wins, so a Git checkout nested inside an SVN working copy
--- (or vice versa) resolves to the inner one.
---@return table|nil backend, string|nil root, string|nil err
function M.resolve(path, opts)
	if opts and opts.force_resolve then
		M.invalidate(path)
	end
	-- dir_of, not dirname: callers also pass directories (buffer_ops falls back to
	-- the cwd for non-file buffers), and dirname would probe the PARENT of a
	-- working copy, so a repo root resolved to "no working copy found".
	local key = util.dir_of(vim.fs.abspath(path))
	local hit = probe_cache[key]
	if hit ~= nil then
		if hit.backend then
			return hit.backend, hit.root
		end
		-- Expire negative results so git init and new checkouts work without restart. Avoid
		-- probing every non-repository BufEnter.
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
		cache_put(key, { err = err, at = vim.uv.now() })
		return nil, nil, err
	end

	cache_put(key, best)
	return best.backend, best.root
end

---Return only a still-valid cached resolution. This never spawns a process.
function M.resolve_cached(path)
	local key = util.dir_of(vim.fs.abspath(path))
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

local function repository_failure(err, path, missing_only)
	-- Error messages quote repository paths; words within those paths are not
	-- cancellation, timeout or output-limit diagnostics.
	err = tostring(err or "")
	if path then
		err = err:gsub(vim.pesc(path), "")
	end
	err = err:gsub("(['\"]).-%1", ""):lower()
	if
		err:find("cancel")
		or err:find("timed out")
		or err:find("timeout")
		or err:find("truncat")
		or err:find("output limit")
	then
		return false
	end
	return err:find("not a git repository", 1, true)
		or err:find("not a working copy", 1, true)
		or err:find("e155007", 1, true)
		or (not missing_only and err:find("cannot change to", 1, true))
end

---Asynchronously resolve the backend owning `path`.
---The callback receives `(backend, root, err)`.
function M.resolve_async(path, on_done, opts)
	opts = opts or {}
	if opts.force_resolve then
		M.invalidate(path)
	end
	local task = Task.new(on_done)
	local key = util.dir_of(vim.fs.abspath(path))
	local hit = probe_cache[key]
	if hit ~= nil and not opts.revalidate then
		if hit.backend then
			vim.schedule(util.safe_callback(function()
				task:finish(hit.backend, hit.root, nil)
			end))
			return task
		end
		if vim.uv.now() - hit.at < NEGATIVE_TTL_MS then
			vim.schedule(util.safe_callback(function()
				task:finish(nil, nil, hit.err)
			end))
			return task
		end
		probe_cache[key] = nil
	end

	local shared = in_flight[key]
	if shared then
		shared.listeners[task] = true
	else
		shared = {
			listeners = { [task] = true },
			owner = Task.new(),
			generation = cache_generation,
		}
		in_flight[key] = shared
	end
	task:on_cancel(function()
		shared.listeners[task] = nil
		if next(shared.listeners) == nil then
			shared.owner:kill()
			if in_flight[key] == shared then
				in_flight[key] = nil
			end
		end
	end)
	if shared.started then
		return task
	end
	shared.started = true
	local pending, best, errors = #backends, nil, {}
	local uncertain, roots = {}, {}
	local function completed(backend, info, err)
		if not shared.owner:is_active() then
			return
		end
		if info and info.root then
			roots[backend] = info.root
			if
				not best
				or #info.root > #best.root
				or (#info.root == #best.root and rank[backend] < rank[best.backend])
			then
				best = { backend = backend, root = info.root }
			end
		end
		if not (info and info.root) then
			-- A missing executable, spawn failure or timeout cannot disprove a
			-- previously resolved owner.
			uncertain[backend] = not repository_failure(err, key, true)
			if
				err
				and err ~= ""
				and not repository_failure(err, key, true)
				and not tostring(err):match("executable not found$")
			then
				errors[#errors + 1] = err
			end
		end
		pending = pending - 1
		if pending > 0 then
			return
		end
		if in_flight[key] == shared then
			in_flight[key] = nil
		end
		local generic = "No Git or SVN working copy found for " .. path
		local failure = not best and (#errors == 0 and generic or generic .. ": " .. table.concat(errors, "; ")) or nil
		if shared.generation == cache_generation and not shared.stale then
			checked_at[key] = vim.uv.now()
			local previous = probe_cache[key]
			if
				previous
				and previous.backend
				and not roots[previous.backend]
				and uncertain[previous.backend]
				and (not best or #best.root <= #previous.root)
			then
				best, failure = previous, nil
			end
			if not previous or not best or previous.backend ~= best.backend or previous.root ~= best.root then
				cache_put(key, best or { err = failure, at = vim.uv.now() })
			end
		end
		shared.owner:finish()
		for listener in pairs(shared.listeners) do
			local ok, callback_err =
				pcall(listener.finish, listener, best and best.backend, best and best.root, failure)
			if not ok then
				util.notify("Repository resolution callback failed: " .. tostring(callback_err), vim.log.levels.ERROR)
			end
		end
		shared.listeners = {}
	end
	for _, backend in ipairs(backends) do
		shared.owner:add(backend.probe_async(key, function(info, err)
			completed(backend, info, err)
		end, opts))
	end
	return task
end

local function read_async(method, path, on_done, opts, arguments)
	opts = opts or {}
	local task = Task.new(on_done)
	local function attempt(retry)
		local resolve_opts = vim.tbl_extend("force", opts, { force_resolve = retry or opts.force_resolve })
		task:add(M.resolve_async(path, function(backend, root, err)
			if not backend then
				return task:finish(nil, err, { code = "repository_unavailable" })
			end
			local args = { path }
			vim.list_extend(args, arguments or {})
			args[#args + 1] = function(result, load_err, extra)
				if not result and ((extra and extra.code == "stale_root") or repository_failure(load_err, path)) then
					M.invalidate(path)
					if not retry then
						return attempt(true)
					end
				end
				task:finish(result, load_err, extra)
			end
			args[#args + 1] = vim.tbl_extend("force", opts, { root = root })
			task:add(backend[method](unpack(args)))
		end, resolve_opts))
	end
	attempt(false)
	return task
end

---Asynchronous full session payload. No synchronous repository probe occurs.
function M.load_async(path, on_done, opts)
	return read_async("load_async", path, on_done, opts)
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
		local result, load_err, extra = fn(path, ...)
		if fn_name ~= "revert_file" and not result and repository_failure(load_err, path) then
			M.invalidate(path)
			local fresh, _, resolve_err = M.resolve(path)
			if not fresh then
				return nil, resolve_err
			end
			return fresh[fn_name](path, ...)
		end
		return result, load_err, extra
	end
end

M.load_base = dispatch("load_base")
M.blame_lines = dispatch("blame_lines")
M.revert_file = dispatch("revert_file")
M.line_revision = dispatch("line_revision")
M.revision_log = dispatch("revision_log")

--- Async variants report failure through `on_done(nil, err)` rather than returning.
function M.load_base_async(path, on_done, opts)
	return read_async("load_base_async", path, on_done, opts)
end

---@param path string
---@param base_identity table?
---@param callback fun(valid: boolean, err: string?)
---@param opts? table
---@return table task
function M.validate_editable_base_async(path, base_identity, callback, opts)
	local task = Task.new(callback)
	if not base_identity then
		vim.schedule(util.safe_callback(function()
			task:finish(true)
		end))
		return task
	end
	task:add(M.resolve_async(path, function(backend, root, err)
		if not backend then
			return task:finish(false, err)
		end
		if not backend.validate_editable_base_async then
			return task:finish(false, "Backend cannot validate editable hunks")
		end
		task:add(backend.validate_editable_base_async(path, base_identity, function(valid, why)
			task:finish(valid, why)
		end, vim.tbl_extend("force", opts or {}, { root = root })))
	end, opts))
	return task
end

function M.blame_lines_async(path, on_done, opts)
	return read_async("blame_lines_async", path, on_done, opts)
end

function M.line_revision_async(path, line_number, on_done, opts)
	return read_async("line_revision_async", path, on_done, opts, { line_number })
end

function M.revision_log_async(path, revision, on_done, opts)
	return read_async("revision_log_async", path, on_done, opts, { revision })
end

function M.changed_files_async(path, on_done, opts)
	return read_async("changed_files_async", path, on_done, opts)
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
	return read_async("is_versioned_async", path, on_done, opts)
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
		local comparison, err
		if target.left and target.right then
			comparison = target
		else
			comparison, err = backend.resolve_diff_target(target)
		end
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

vim.api.nvim_create_augroup("lazyvcs_backends", { clear = true })

vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
	group = "lazyvcs_backends",
	callback = util.safe_callback(function(args)
		if not util.is_real_file_buffer(args.buf) then
			return
		end
		local path = util.buf_path(args.buf)
		if not path then
			return
		end
		local key = util.dir_of(vim.fs.abspath(path))
		local now = vim.uv.now()
		if checked_at[key] and now - checked_at[key] < 5000 then
			return
		end
		if probe_cache[key] or in_flight[key] then
			checked_at[key] = now
		end
		M.resolve_async(path, function() end, { revalidate = true })
	end),
})

return M
