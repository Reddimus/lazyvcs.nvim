local M = {}
local live = {}
local preparations = {}
local closed = false
local initialized = false
local notify

local function protected(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok and notify then
		notify(err, vim.log.levels.ERROR)
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
