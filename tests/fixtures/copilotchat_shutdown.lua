local root, dir, mode = arg[1], arg[2], arg[3]
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
local process = require("process_helpers")
local model = assert(loadfile(root .. "/tests/fixtures/ai_transport_helpers.lua"))()
local async = model.async()
local curl, chat, Job, jobs = model.transport(dir, root .. "/tests/fixtures/ai_transport.lua", async)
package.loaded["plenary.async"], package.loaded["plenary.job"] = async, Job
package.loaded["plenary.curl"], package.loaded["CopilotChat.utils.curl"] = curl, chat
package.loaded["lazy"] = { load = function() end }
package.loaded["CopilotChat"] = { config = { model = "fixture" } }
package.loaded["CopilotChat.client"] = {
	models = function() end,
	get_providers = function() end,
	ask = function()
		local response = chat.post("offline://fixture", {
			headers = { Authorization = "fixture" },
			ignore_term = true,
			json_request = true,
			body = { diff = "PRIVATE_DIFF_SENTINEL" },
		})
		return { message = { content = response and response.body or "late" } }
	end,
}
local began, callbacks = nil, 0
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		began = vim.uv.hrtime()
	end,
})
local adapter = require("lazyvcs.source_control.copilotchat")
local registry = require("lazyvcs.source_control.ai_requests")
local handles = {}
for index = 1, 3 do
	local handle = adapter.start("literal", { timeout_ms = 10000 }, function()
		callbacks = callbacks + 1
	end)
	handles[index] = handle
	registry.register(dir, handle, function()
		handle:cancel()
	end)
end
assert(
	vim.wait(15000, function()
		for _, item in ipairs(jobs) do
			if not process.pid(item.path) then
				return false
			end
		end
		return #jobs == 3
	end, 10),
	"children did not start"
)
if mode == "cancelled" then
	for _, handle in ipairs(handles) do
		handle:cancel()
	end
elseif mode == "success" then
	for _, item in ipairs(jobs) do
		item.job:shutdown(0, 0)
	end
end
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		local runtime = require("lazyvcs.process_runtime")
		local count = #jobs
		adapter.start("late", { timeout_ms = 10000 }, function()
			callbacks = callbacks + 1
		end)
		local late_scope = require("lazyvcs.source_control.copilotchat_transport").new_scope()
		vim.wait(20)
		local reaped, files_removed = true, true
		for _, item in ipairs(jobs) do
			reaped = reaped and process.reaped(item.job.pid)
			files_removed = files_removed and vim.uv.fs_stat(item.job.options.body) == nil
		end
		vim.fn.writefile({
			vim.json.encode({
				closed = runtime.is_shutting_down(),
				reaped = reaped,
				files_removed = files_removed,
				rejected = #jobs == count and late_scope == nil,
				callbacks = callbacks,
				elapsed_ms = (vim.uv.hrtime() - began) / 1e6,
			}),
		}, dir .. "/shutdown.json")
	end,
})
vim.cmd("qa!")
