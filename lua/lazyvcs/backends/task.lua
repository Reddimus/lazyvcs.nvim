-- Cancellable owner for a chain (or fan-out) of asynchronous VCS processes.
-- Backends replace several short-lived child processes while loading a single
-- logical result; exposing only the newest process made cancellation race-prone.
local M = {}

function M.new(on_done, opts)
	opts = opts or {}
	local task = {
		cancelled = false,
		done = false,
		handles = {},
		cancel_callbacks = {},
	}

	local function stop_handle(handle, signal)
		if type(handle) == "table" or type(handle) == "userdata" then
			local ok, cancel = pcall(function()
				return handle.cancel or handle.kill
			end)
			if ok and type(cancel) == "function" then
				pcall(cancel, handle, signal or 15)
			end
		elseif type(handle) == "number" and type(opts.cancel_id) == "function" then
			pcall(opts.cancel_id, handle)
		end
	end

	local deadline_timer
	local function stop_deadline()
		local timer = deadline_timer
		deadline_timer = nil
		if timer then
			timer:stop()
			if not timer:is_closing() then
				timer:close()
			end
		end
	end

	-- A deadline belongs to the whole operation, including non-command
	-- callbacks. Complete before stopping children so cancellation callbacks
	-- cannot deliver a late result or replace the timeout error.
	function task:set_deadline(timeout_ms, message)
		assert(
			type(timeout_ms) == "number"
				and timeout_ms >= 1
				and timeout_ms < 2147483647
				and timeout_ms == math.floor(timeout_ms)
		)
		if not self:is_active() or deadline_timer then
			return self
		end
		deadline_timer = vim.uv.new_timer()
		if not deadline_timer then
			self:finish(nil, "Comparison deadline unavailable")
			return self
		end
		deadline_timer:start(
			timeout_ms,
			0,
			vim.schedule_wrap(function()
				if not self:is_active() then
					stop_deadline()
					return
				end
				self.done = true
				stop_deadline()
				for _, handle in ipairs(self.handles) do
					stop_handle(handle, 15)
				end
				local callbacks = self.cancel_callbacks
				self.cancel_callbacks = {}
				for _, callback in ipairs(callbacks) do
					pcall(callback, self)
				end
				if type(on_done) == "function" then
					on_done(nil, message or "Comparison timed out")
				end
			end)
		)
		return self
	end

	function task:add(handle)
		if handle == nil or self.done then
			return handle
		end
		if self.cancelled then
			stop_handle(handle, 15)
			return handle
		end
		self.handles[#self.handles + 1] = handle
		return handle
	end

	function task:is_active()
		return not self.done and not self.cancelled
	end

	function task:on_cancel(callback)
		if type(callback) ~= "function" then
			return self
		end
		if self.cancelled then
			pcall(callback, self)
		elseif not self.done then
			self.cancel_callbacks[#self.cancel_callbacks + 1] = callback
		end
		return self
	end

	function task:finish(...)
		if self.done or self.cancelled then
			return false
		end
		self.done = true
		stop_deadline()
		self.cancel_callbacks = {}
		if type(on_done) == "function" then
			on_done(...)
		end
		return true
	end

	function task:kill(signal)
		if self.done or self.cancelled then
			return false
		end
		self.cancelled = true
		stop_deadline()
		for _, handle in ipairs(self.handles) do
			stop_handle(handle, signal)
		end
		local callbacks = self.cancel_callbacks
		self.cancel_callbacks = {}
		for _, callback in ipairs(callbacks) do
			pcall(callback, self)
		end
		if opts.callback_on_cancel and type(on_done) == "function" then
			self.done = true
			on_done(nil, opts.cancel_error or "Cancelled")
		end
		return true
	end

	task.cancel = task.kill
	return task
end

return M
