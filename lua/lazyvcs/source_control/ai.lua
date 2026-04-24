local config = require("lazyvcs.config")
local util = require("lazyvcs.util")

local M = {}

local function load_copilot_chat()
	local ok_lazy, lazy = pcall(require, "lazy")
	if ok_lazy then
		pcall(lazy.load, { plugins = { "CopilotChat.nvim" } })
	end
	local ok, chat = pcall(require, "CopilotChat")
	if not ok or type(chat.ask) ~= "function" then
		return nil, "CopilotChat is not available"
	end
	return chat
end

local function git_context(repo_root)
	local staged = util.system(
		{ "git", "diff", "--staged", "--stat", "--patch", "--minimal", "--unified=1" },
		{ cwd = repo_root }
	)
	if staged and util.trim(staged.stdout) ~= "" then
		return staged.stdout
	end
	local unstaged = util.system(
		{ "git", "diff", "--stat", "--patch", "--minimal", "--unified=1" },
		{ cwd = repo_root }
	)
	if unstaged and util.trim(unstaged.stdout) ~= "" then
		return unstaged.stdout
	end
	local summary = util.system({ "git", "status", "--short" }, { cwd = repo_root })
	return summary and summary.stdout or ""
end

local function svn_context(repo_root)
	local diff = util.system({ "svn", "diff", repo_root }, { cwd = repo_root })
	if diff and util.trim(diff.stdout) ~= "" then
		return diff.stdout
	end
	local summary = util.system({ "svn", "status", repo_root }, { cwd = repo_root })
	return summary and summary.stdout or ""
end

function M.available()
	local provider = config.get().ai.commit_message.provider
	if provider ~= "copilotchat" then
		return false
	end
	local chat = load_copilot_chat()
	return chat ~= nil
end

function M.generate(repo, callback)
	local provider = config.get().ai.commit_message.provider
	if provider ~= "copilotchat" then
		return nil, "Unsupported commit message provider: " .. provider
	end

	local chat, err = load_copilot_chat()
	if not chat then
		return nil, err
	end

	local context = repo.vcs == "git" and git_context(repo.root) or svn_context(repo.root)
	if util.trim(context) == "" then
		return nil, "No changes available to summarize"
	end
	context = util.truncate(context, 12000)

	local prompt = table.concat({
		"Write a concise imperative commit message for the following " .. repo.vcs .. " changes.",
		"Return only the commit subject line with no quotes, no bullet points, and no explanation.",
		"",
		context,
	}, "\n")

	chat.ask(prompt, {
		headless = true,
		callback = function(response)
			local content = util.trim(response and response.content or "")
			if content == "" then
				util.notify("CopilotChat returned an empty commit message", vim.log.levels.WARN)
				return
			end
			if type(callback) == "function" then
				callback(content)
			end
		end,
	})

	return true
end

return M
