local config = require("lazyvcs.config")
local util = require("lazyvcs.util")

local M = {}

local last_error_by_provider = {}
local privacy_accepted = false
local executable_checker = function(name)
	return vim.fn.executable(name) == 1
end

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

local function executable(name)
	return executable_checker(name)
end

local function provider_available(provider)
	if provider == "copilotchat" then
		return load_copilot_chat() ~= nil
	end
	if provider == "copilot_cli" then
		return executable("copilot")
	end
	return executable(provider)
end

local function configured_providers()
	local opts = config.get().ai.commit_message
	if opts.provider == "off" then
		return {}
	end
	if opts.provider == "auto" then
		return opts.provider_order or {}
	end
	return { opts.provider }
end

local function run_context_commands(commands, index, callback)
	local command = commands[index]
	if not command then
		return callback("")
	end
	util.system_start(command.args, { cwd = command.cwd, timeout = command.timeout }, function(result)
		local stdout = result and util.trim(result.stdout) or ""
		if stdout ~= "" then
			return callback(result.stdout)
		end
		run_context_commands(commands, index + 1, callback)
	end)
end

local function git_context(repo_root, callback)
	local timeout = config.get().source_control.background.status_timeout_ms
	run_context_commands({
		{
			args = { "git", "diff", "--staged", "--stat", "--patch", "--minimal", "--unified=1" },
			cwd = repo_root,
			timeout = timeout,
		},
		{
			args = { "git", "diff", "--stat", "--patch", "--minimal", "--unified=1" },
			cwd = repo_root,
			timeout = timeout,
		},
		{
			args = { "git", "status", "--short" },
			cwd = repo_root,
			timeout = timeout,
		},
	}, 1, callback)
end

local function svn_context(repo_root, callback)
	local timeout = config.get().source_control.background.status_timeout_ms
	run_context_commands({
		{ args = { "svn", "diff", repo_root }, cwd = repo_root, timeout = timeout },
		{ args = { "svn", "status", repo_root }, cwd = repo_root, timeout = timeout },
	}, 1, callback)
end

local function build_prompt(repo, context)
	local opts = config.get().ai.commit_message
	local lines = {
		"Write a concise imperative commit message subject for the following " .. repo.vcs .. " changes.",
		"Use the supplied diff/status only. Do not inspect files, run commands, edit files, or add explanations.",
		"Return only one subject line with no quotes, no bullet points, and no markdown.",
	}
	if opts.instructions and util.trim(opts.instructions) ~= "" then
		lines[#lines + 1] = "Follow these user instructions: " .. util.trim(opts.instructions)
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = util.truncate(context, opts.max_context_chars)
	return table.concat(lines, "\n")
end

local function clean_message(text)
	local message = util.trim(text or "")
	message = message:gsub("^```%w*\n?", ""):gsub("\n?```$", "")
	message = util.trim(message)
	local first_line = message:match("([^\r\n]+)")
	return util.trim(first_line or "")
end

local function run_cli_provider(provider, repo, prompt, callback)
	local opts = config.get().ai.commit_message
	local args
	local run_opts = {
		cwd = repo.root,
		timeout = opts.timeout_ms,
		stdin = prompt,
	}

	if provider == "claude" then
		args =
			{ "claude", "-p", prompt, "--output-format", "text", "--no-session-persistence", "--disallowedTools", "*" }
		run_opts.stdin = nil
	elseif provider == "codex" then
		args = {
			"codex",
			"exec",
			"--skip-git-repo-check",
			"--ephemeral",
			"--sandbox",
			"read-only",
			"--ask-for-approval",
			"never",
			"-",
		}
	elseif provider == "gemini" then
		args = { "gemini", "-p", prompt, "--output-format", "text", "--skip-trust", "--approval-mode", "plan" }
		run_opts.stdin = nil
	elseif provider == "copilot_cli" then
		args =
			{ "copilot", "-p", prompt, "--output-format", "text", "--no-custom-instructions", "--available-tools", "" }
		run_opts.stdin = nil
	else
		return callback(nil, "Unsupported commit message provider: " .. provider)
	end

	util.system_start(args, run_opts, function(result, err)
		if err then
			return callback(nil, err)
		end
		local message = clean_message(result and result.stdout or "")
		if message == "" then
			return callback(nil, provider .. " returned an empty commit message")
		end
		callback(message)
	end)
end

local function run_provider(provider, repo, prompt, callback)
	if provider == "copilotchat" then
		local chat, err = load_copilot_chat()
		if not chat then
			return callback(nil, err)
		end
		chat.ask(prompt, {
			headless = true,
			callback = function(response)
				local message = clean_message(response and response.content or "")
				if message == "" then
					return callback(nil, "CopilotChat returned an empty commit message")
				end
				callback(message)
			end,
		})
		return
	end
	run_cli_provider(provider, repo, prompt, callback)
end

local function confirm_privacy(callback)
	local opts = config.get().ai.commit_message
	if privacy_accepted or opts.confirm_privacy == false then
		return callback(true)
	end
	vim.ui.select({
		"Send diff to configured AI provider",
		"Cancel",
	}, {
		prompt = "Generate commit message? Diffs may be sent to the configured AI provider.",
	}, function(choice)
		if choice == "Send diff to configured AI provider" then
			privacy_accepted = true
			callback(true)
		else
			callback(false)
		end
	end)
end

local function try_provider(providers, index, repo, prompt, callback)
	local provider = providers[index]
	if not provider then
		local errors = {}
		for name, err in pairs(last_error_by_provider) do
			errors[#errors + 1] = name .. ": " .. err
		end
		table.sort(errors)
		return callback(nil, #errors > 0 and table.concat(errors, "; ") or "No AI commit-message provider is available")
	end
	if not provider_available(provider) then
		last_error_by_provider[provider] = "not available"
		return try_provider(providers, index + 1, repo, prompt, callback)
	end
	run_provider(provider, repo, prompt, function(message, err)
		if message then
			last_error_by_provider[provider] = nil
			return callback(message, nil, provider)
		end
		last_error_by_provider[provider] = err or "failed"
		if config.get().ai.commit_message.provider == "auto" then
			return try_provider(providers, index + 1, repo, prompt, callback)
		end
		callback(nil, err or "Failed to generate commit message")
	end)
end

function M.available()
	for _, provider in ipairs(configured_providers()) do
		if provider_available(provider) then
			return true
		end
	end
	return false
end

function M.generate(repo, callback)
	if config.get().ai.commit_message.provider == "off" then
		return nil, "AI commit-message generation is disabled"
	end

	local providers = configured_providers()
	if #providers == 0 then
		return nil, "No AI commit-message provider is configured"
	end

	confirm_privacy(function(accepted)
		if not accepted then
			if type(callback) == "function" then
				callback(nil, nil)
			end
			return
		end
		local context_callback = function(context)
			if util.trim(context) == "" then
				return callback(nil, "No changes available to summarize")
			end
			local prompt = build_prompt(repo, context)
			try_provider(providers, 1, repo, prompt, callback)
		end
		if repo.vcs == "git" then
			git_context(repo.root, context_callback)
		else
			svn_context(repo.root, context_callback)
		end
	end)

	return true
end

function M.status()
	local items = {}
	for _, provider in ipairs({ "copilotchat", "claude", "codex", "gemini", "copilot_cli" }) do
		items[#items + 1] = {
			provider = provider,
			available = provider_available(provider),
			last_error = last_error_by_provider[provider],
		}
	end
	return items
end

function M._test_reset_privacy()
	privacy_accepted = false
	last_error_by_provider = {}
	executable_checker = function(name)
		return vim.fn.executable(name) == 1
	end
end

function M._test_set_executable_checker(checker)
	executable_checker = checker
end

return M
