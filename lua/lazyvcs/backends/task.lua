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
