local util = require("lazyvcs.util")
local backends = require("lazyvcs.backends")
local text = require("lazyvcs.compare_text")
local Task = require("lazyvcs.backends.task")
local M = {}

function M.new(changes)
	local requests = {}
	local gate = {}
	local function identity(path, entry, ignorecase)
		local canonical = entry and util.canonical_entry_path(path) or util.canonical_path(path)
		return ignorecase and canonical:lower() or canonical
	end
	local function matches(change, request)
		local path = identity(request.path, true, change.ignorecase)
		return (not request.root or identity(request.root, false, change.ignorecase) == change.root)
			and (not change.paths or change.paths[path])
			and util.relative_literal_path(change.root, path, change.ignorecase) ~= nil
	end
	local function active_change(request)
		for change in pairs(changes) do
			if matches(change, request) then
				return true
			end
		end
		return false
	end
	function gate.load_async(path, done, context)
		local owner, child, events
		local request = { path = path, generation = 0, overlaps = {} }
		local function stop_child()
			local old = child
			child = nil
			if old and type(old.kill) == "function" then
				pcall(old.kill, old, 15)
			end
		end
		local function cleanup()
			requests[request] = nil
			for _, id in ipairs(events or {}) do
				pcall(vim.api.nvim_del_autocmd, id)
			end
			events = nil
			stop_child()
		end
		owner = Task.new(function(...)
			cleanup()
			done(...)
		end)
		owner:on_cancel(cleanup)
		local function protected(fn)
			return function(...)
				local ok, err = pcall(fn, ...)
				if not ok then
					if owner:is_active() then
						owner:finish(nil, err)
					else
						util.notify(util.truncate(tostring(err):gsub("%s+", " "), 200), vim.log.levels.ERROR)
					end
				end
			end
		end
		local function check_context()
			if
				not util.buf_is_valid(context.bufnr)
				or (
					context.winid
					and (
						not util.win_is_valid(context.winid)
						or vim.api.nvim_win_get_tabpage(context.winid) ~= context.tabpage
						or vim.api.nvim_win_get_buf(context.winid) ~= context.bufnr
					)
				)
			then
				owner:kill()
				return false
			end
			local reason
			if util.buf_path(context.bufnr) ~= path then
				reason = "Buffer path changed while loading"
			else
				local profile = text.profile(context.bufnr)
				if not profile or profile.key ~= context.profile then
					reason = "Buffer decoding context changed while loading"
				end
			end
			if reason then
				-- The owning transfer must complete so it can pause or reconcile the
				-- changed target, including while this request has no child read.
				owner:finish(nil, reason, { code = "context_changed" })
				return false
			end
			return true
		end
		local function current(generation)
			if not owner:is_active() then
				return false
			end
			if not check_context() then
				return false
			end
			return request.generation == generation
		end
		local function adopt(handle, generation)
			if current(generation) and not request.waiting then
				child = handle
			elseif handle and type(handle.kill) == "function" then
				pcall(handle.kill, handle, 15)
			end
		end
		local attempt
		attempt = protected(function()
			if not owner:is_active() then
				return
			end
			if not check_context() then
				return
			end
			request.generation = request.generation + 1
			local generation = request.generation
			request.waiting = nil
			if active_change(request) then
				if request.root then
					request.waiting = true
					request.overlaps = {}
					return
				end
				-- Resolve ownership before waiting, so a parent repository's mutation does
				-- not block a file owned by an unrelated nested working copy.
				local handle = backends.resolve_async(
					path,
					protected(function(backend, root, err)
						if not current(generation) then
							return
						end
						child = nil
						if not backend then
							return owner:finish(nil, err, { code = "repository_unavailable" })
						end
						request.root = root
						attempt()
					end)
				)
				adopt(handle, generation)
				return
			end
			request.overlaps = {}
			local handle = backends.load_async(
				path,
				protected(function(result, err, rejection)
					if not current(generation) then
						return
					end
					child = nil
					if result then
						request.root = result.root
					end
					local changed = active_change(request)
					for change in pairs(request.overlaps) do
						changed = changed or matches(change, request)
					end
					if changed then
						request.overlaps = {}
						return attempt()
					end
					owner:finish(result, err, rejection)
				end)
			)
			adopt(handle, generation)
		end)
		request.attempt = attempt
		request.invalidate = function(change)
			if not matches(change, request) then
				return
			end
			request.overlaps[change] = true
			if request.root then
				request.generation = request.generation + 1
				stop_child()
				request.waiting = true
				request.overlaps = {}
			end
		end
		requests[request] = true
		events = {
			vim.api.nvim_create_autocmd(
				{ "BufEnter", "BufWinEnter", "BufFilePost", "BufWipeout", "WinClosed", "OptionSet" },
				{
					desc = "LazyVCS pending base read",
					callback = function()
						vim.schedule(function()
							if owner:is_active() then
								check_context()
							end
						end)
					end,
				}
			),
		}
		attempt()
		return owner
	end
	function gate.begin(change)
		for _, request in ipairs(vim.tbl_keys(requests)) do
			if requests[request] then
				request.invalidate(change)
			end
		end
	end
	function gate.finish(change)
		for _, request in ipairs(vim.tbl_keys(requests)) do
			if requests[request] and request.waiting and matches(change, request) and not active_change(request) then
				request.attempt()
			end
		end
	end
	return gate
end
return M
