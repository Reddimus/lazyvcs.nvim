local util = require("lazyvcs.util")
local runtime = require("lazyvcs.process_runtime")

local M = {}

function M.adopt(job, scope, files)
	assert(
		type(job._shutdown) == "function"
			and job.handle
			and type(job.handle.is_active) == "function"
			and type(job.handle.is_closing) == "function"
			and type(job.handle.kill) == "function"
			and type(job.handle.close) == "function"
			and (job.is_shutdown == nil or job.is_shutdown == false),
		"CopilotChat requires cancellable plenary.curl Jobs; update CopilotChat.nvim."
	)
	local handle, finalize = job.handle, job._shutdown
	local owned = { cancelled = false, finished = false }
	local outcome, timer
	function owned:close_timers()
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		timer = nil
	end
	function owned:abandon()
		if files then
			files:abandon()
		end
	end
	function owned:force()
		if not self.finished and not handle:is_closing() and handle:is_active() then
			pcall(handle.kill, handle, 9)
		end
	end
	function owned:stop(reason)
		if self.finished then
			return
		end
		if reason ~= "success" then
			self.cancelled = true
		end
		if handle:is_closing() or not handle:is_active() or timer then
			return
		end
		pcall(handle.kill, handle, 15)
		if runtime.is_shutting_down() then
			return
		end
		timer = vim.uv.new_timer()
		if not timer then
			self:force()
			return
		end
		timer:start(
			2000,
			0,
			util.safe_callback(function()
				self:close_timers()
				self:force()
			end)
		)
	end
	function owned:shutdown()
		self:close_timers()
		self:stop("shutdown")
	end
	job._shutdown = util.safe_callback(function(self, code, signal)
		if owned.finished then
			return
		end
		if not handle:is_closing() and handle:is_active() then
			outcome = outcome or { code = code, signal = signal }
			owned:stop(code == 0 and "success" or "error")
			return
		end
		owned.finished = true
		owned:close_timers()
		if owned.cancelled then
			code = code and code ~= 0 and code or 128 + (signal and signal ~= 0 and signal or 15)
		elseif outcome then
			code, signal = outcome.code, outcome.signal
		elseif code == 0 and signal and signal ~= 0 then
			code = 128 + signal
		end
		-- Plenary owns finalization, but dependency callback failures must not skip cleanup.
		local ok, err = pcall(finalize, self, code, signal)
		if not ok then
			if type(self._stop) == "function" then
				util.safe_callback(self._stop)(self)
			end
			self.is_shutdown = true
			util.safe_callback(function()
				error((tostring(err):gsub("[\r\n]+", " ")), 0)
			end)()
		end
		scope.jobs[job] = nil
		if files then
			files:release(function()
				runtime.untrack(owned)
			end)
		else
			runtime.untrack(owned)
		end
	end)
	scope.jobs[job] = owned
	runtime.track(owned)
	return owned
end

return M
