-- Isolated worker entry point: libuv executes it in a fresh Lua state, so it
-- must not capture upvalues. Prefer the Neovim 0.12 name; 0.11 has only vim.diff.
local M = {}
local function worker(left, right, result_type, packed_options)
	local diff = type(vim.text) == "table" and vim.text.diff or nil
	if type(diff) ~= "function" then
		---@diagnostic disable-next-line: deprecated
		diff = vim.diff
	end
	if type(diff) ~= "function" then
		return false, ""
	end
	local options = packed_options and vim.mpack.decode(packed_options) or { algorithm = "histogram" }
	options.result_type = result_type
	local ok, raw = pcall(diff, left, right, options)
	if not ok then
		return true, "", tostring(raw)
	end
	return true, result_type == "indices" and vim.mpack.encode(raw) or raw
end

M._worker = worker

function M.start(left, right, result_type, done, options)
	options = options
		or (result_type == "indices" and require("lazyvcs.diff").native_options() or { algorithm = "histogram" })
	local work
	local ok, err = pcall(function()
		work = assert(vim.uv.new_work(worker, vim.schedule_wrap(require("lazyvcs.util").safe_callback(done))))
		assert(work:queue(left, right, result_type, vim.mpack.encode(options)))
	end)
	return ok and work or nil, not ok and tostring(err) or nil
end

-- One physical worker and one replaceable pending request per owner. Running
-- libxdiff cannot be interrupted; superseded results never reach the consumer.
function M.latest()
	local queue = {}
	local launch
	launch = function(request)
		queue.running = true
		local work, err = M.start(request.left, request.right, "indices", function(available, raw, failure)
			queue.running = nil
			local pending = queue.pending
			queue.pending = nil
			if queue.closed then
				return
			end
			if pending then
				return launch(pending)
			end
			if not available then
				failure = "Threaded diff is unavailable"
			end
			request.done(not failure and vim.mpack.decode(raw) or nil, failure)
		end, request.options)
		if not work then
			queue.running = nil
			request.done(nil, err)
		end
	end
	function queue:request(left, right, done)
		if self.closed then
			return
		end
		local request = { left = left, right = right, done = done, options = require("lazyvcs.diff").native_options() }
		if self.running then
			self.pending = request
		else
			launch(request)
		end
	end
	function queue:close()
		self.closed, self.pending = true, nil
	end
	return queue
end

return M
