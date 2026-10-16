local util = require("lazyvcs.util")

local M = {}

local REQUIREMENT =
	"CopilotChat commit generation requires the main client API (client:ask, client:models, client:get_providers) and plenary.async.run; update CopilotChat.nvim."

function M.start(prompt, settings, on_done)
	local active, settled, timer = true, false, nil
	local function stop_timer()
		if timer and not timer:is_closing() then
			timer:stop()
			timer:close()
		end
		timer = nil
	end
	local handle = {}
	function handle:cancel()
		active = false
		stop_timer()
	end
	handle.kill = handle.cancel
	local function finish(message, err)
		if not active or settled then
			return
		end
		settled = true
		stop_timer()
		vim.schedule(function()
			if not active then
				return
			end
			active = false
			local ok, callback_err = pcall(on_done, message, err)
			if not ok then
				util.notify(
					("CopilotChat callback failed: " .. tostring(callback_err)):gsub("[\r\n]+", " "),
					vim.log.levels.ERROR
				)
			end
		end)
	end

	local ok_lazy, lazy = pcall(require, "lazy")
	if ok_lazy then
		pcall(lazy.load, { plugins = { "CopilotChat.nvim" } })
	end
	local ok_chat, chat = pcall(require, "CopilotChat")
	local ok_client, client = pcall(require, "CopilotChat.client")
	local ok_async, async = pcall(require, "plenary.async")
	if
		not ok_chat
		or not ok_client
		or not ok_async
		or type(chat) ~= "table"
		or type(client) ~= "table"
		or type(async) ~= "table"
		or type(client.ask) ~= "function"
		or type(client.models) ~= "function"
		or type(client.get_providers) ~= "function"
		or type(async.run) ~= "function"
	then
		finish(nil, REQUIREMENT)
		return handle
	end
	local config = chat.config or {}
	if type(config.model) ~= "string" or config.model == "" then
		finish(nil, "CopilotChat commit generation requires a scalar configured model.")
		return handle
	end
	local model = config.model
	local temperature = type(config.temperature) == "number" and config.temperature or nil
	if settings.timeout_ms > 0 then
		timer = vim.defer_fn(function()
			finish(nil, "CopilotChat timed out")
		end, settings.timeout_ms)
	end
	local ok, run_err = pcall(async.run, function()
		if not active or settled then
			return
		end
		local asked, response = pcall(client.ask, client, {
			headless = true,
			history = { { role = "user", content = prompt } },
			system_prompt = "Generate one commit subject from the supplied literal diff. Return only one line.",
			resources = {},
			tools = {},
			model = model,
			temperature = temperature,
		})
		if not asked then
			return finish(nil, (tostring(response):gsub("[\r\n]+", " ")))
		end
		local message = type(response) == "table" and response.message
		local content = type(message) == "table" and message.content
		if type(content) ~= "string" or util.trim(content) == "" then
			return finish(nil, "CopilotChat returned an empty commit message")
		end
		finish(content)
	end)
	if not ok then
		finish(nil, (tostring(run_err):gsub("[\r\n]+", " ")))
	end
	return handle
end

return M
