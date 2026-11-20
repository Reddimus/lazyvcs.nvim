local M = {}
local live = {}
local preparations = {}
local closed = false
local initialized = false
local notify
-- Resolve at load; shutdown can run after the working directory changes.
local source = debug.getinfo(1, "S").source:sub(2)
local drain = (vim.uv.fs_realpath(source) or source):gsub("process_runtime%.lua$", "process_drain.lua")

local function protected(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and notify then
		notify(err, vim.log.levels.ERROR)
	end
end

-- The editor holds the only read end of each output pipe. Once it exits, a
-- preserved command's next write fails with EPIPE, and Git, which restores
-- the default SIGPIPE action, dies mid-operation. A detached reader inherits
-- each open pipe and discards its output until every writer closes it.
function M.retain_output(pipes)
	for _, pipe in ipairs(pipes) do
		local ok, closing = pcall(function()
			return pipe:is_closing()
		end)
		if pipe and ok and not closing then
			local reader
			ok, reader = pcall(vim.uv.spawn, vim.v.progpath, {
				args = { "-ll", drain },
				stdio = { pipe },
				detached = true,
				hide = true,
			}, function()
				if reader then
					reader:close()
				end
			end)
			if ok and reader then
				reader:unref()
			end
		end
	end
end

function M.is_shutting_down()
	return closed
end

function M.track(handle)
	live[handle] = true
end

function M.untrack(handle)
	live[handle] = nil
end

function M.before_shutdown(callback)
	preparations[#preparations + 1] = callback
end

function M.shutdown()
	if closed then
		return
	end
	closed = true
	for _, callback in ipairs(preparations) do
		protected(callback)
	end
	for handle in pairs(live) do
		protected(handle.shutdown, handle)
	end
	local function settled()
		return next(live) == nil
	end
	-- These deadlines are shared by all commands, only during editor exit.
	vim.wait(100, settled, 5)
	for handle in pairs(live) do
		protected(handle.force, handle)
	end
	vim.wait(200, settled, 5)
	for handle in pairs(live) do
		if type(handle.abandon) == "function" then
			protected(handle.abandon, handle)
		end
		protected(handle.close_timers, handle)
	end
end

function M.setup(report)
	if initialized then
		return
	end
	initialized, notify = true, report
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("LazyVCSProcesses", { clear = true }),
		once = true,
		callback = function()
			protected(M.shutdown)
		end,
	})
end

return M
