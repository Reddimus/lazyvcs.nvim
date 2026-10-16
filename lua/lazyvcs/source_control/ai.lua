local config = require("lazyvcs.config")
local fs = require("lazyvcs.fs")
local jobs = require("lazyvcs.source_control.jobs")
local util = require("lazyvcs.util")
local runtime = require("lazyvcs.process_runtime")

local M = {}

local last_error_by_provider = {}
local privacy_accepted = false
local executable_checker = function(name)
	return vim.fn.executable(name) == 1
end

local function copilot_chat_installed()
	if package.loaded["CopilotChat"] then
		return true
	end
	if package.searchpath("CopilotChat", package.path) then
		return true
	end
	local ok, lazy_config = pcall(require, "lazy.core.config")
	return ok and lazy_config.plugins and lazy_config.plugins["CopilotChat.nvim"] ~= nil or false
end

local function executable(name)
	return executable_checker(name)
end

local function provider_available(provider)
	if provider == "copilotchat" then
		return copilot_chat_installed()
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

local function new_request(callback)
	local request = {
		active = true,
		cleanups = {},
	}

	function request:set_handle(handle)
		if not self.active then
			if handle and type(handle.kill) == "function" then
				pcall(handle.kill, handle, 15)
			end
			return
		end
		self.handle = handle
	end

	function request:add_cleanup(cleanup)
		self.cleanups[#self.cleanups + 1] = cleanup
	end

	function request:cleanup()
		for _, cleanup in ipairs(self.cleanups) do
			pcall(cleanup)
		end
		self.cleanups = {}
	end

	function request:finish(message, err, provider)
		if not self.active then
			return
		end
		self.active = false
		self.handle = nil
		self:cleanup()
		if type(callback) == "function" then
			local ok, callback_err = pcall(callback, message, err, provider)
			if not ok then
				util.notify(
					"AI callback failed: " .. (tostring(callback_err):gsub("[\r\n]+", " ")),
					vim.log.levels.ERROR
				)
			end
		end
	end

	function request:cancel()
		if not self.active then
			return
		end
		self.active = false
		if self.handle and type(self.handle.kill) == "function" then
			pcall(self.handle.kill, self.handle, 15)
		end
		self.handle = nil
		self:cleanup()
	end

	request.kill = request.cancel
	return request
end

local function start_context_command(request, command, callback)
	local completed = false
	local id = jobs.command(request.repo, "ai_context", command.args, {
		cwd = command.cwd,
		timeout_ms = command.timeout,
		owner = request.owner,
		scope = "ai_context",
		priority = 10,
	}, function(result, err)
		completed = true
		if not request.active then
			return
		end
		request.handle = nil
		if not result or err then
			return request:finish(nil, err or "Could not collect commit context")
		end
		callback(result.stdout or "", result)
	end)
	if not completed then
		request:set_handle({
			kill = function()
				jobs.cancel(function(job)
					return job.id == id
				end, "AI request cancelled")
			end,
		})
	end
end

local function run_context_commands(request, commands, index, callback)
	if not request.active then
		return
	end
	local command = commands[index]
	if not command then
		return callback("")
	end
	start_context_command(request, command, function(stdout)
		if util.trim(stdout) ~= "" then
			return callback(stdout)
		end
		run_context_commands(request, commands, index + 1, callback)
	end)
end

local function collect_context_commands(request, commands, callback)
	local output = {}
	local index = 1
	local function next_command()
		if not request.active then
			return
		end
		local command = commands[index]
		index = index + 1
		if not command then
			return callback(table.concat(output, "\n"))
		end
		start_context_command(request, command, function(stdout, result)
			if result.stdout_truncated or result.stderr_truncated then
				return request:finish(nil, "Commit context exceeded the output limit")
			end
			if util.trim(stdout) ~= "" then
				output[#output + 1] = util.trim(stdout)
			end
			next_command()
		end)
	end
	next_command()
end

local function git_context(request, repo_root, callback)
	local timeout = config.get().source_control.background.status_timeout_ms
	local context = config.get().ai.commit_message.context
	local commands = {
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
	}
	if context == "staged_first" then
		return run_context_commands(request, commands, 1, callback)
	end
	if context == "staged" then
		return run_context_commands(request, { commands[1] }, 1, callback)
	end
	if context == "unstaged" then
		return run_context_commands(request, { commands[2] }, 1, callback)
	end
	if context == "status" then
		return run_context_commands(request, { commands[3] }, 1, callback)
	end
	collect_context_commands(request, commands, callback)
end

local function svn_context(request, repo_root, callback)
	local timeout = config.get().source_control.background.status_timeout_ms
	local commands = {
		{ args = { "svn", "diff", repo_root }, cwd = repo_root, timeout = timeout },
		{ args = { "svn", "status", util.svn_target(repo_root) }, cwd = repo_root, timeout = timeout },
	}
	local context = config.get().ai.commit_message.context
	if context == "status" then
		return run_context_commands(request, { commands[2] }, 1, callback)
	end
	if context == "all" then
		return collect_context_commands(request, commands, callback)
	end
	run_context_commands(request, commands, 1, callback)
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

local function write_private_attachment(prompt)
	local path = vim.fn.tempname() .. "-lazyvcs-ai.txt"
	local fd, err = vim.uv.fs_open(path, "w", 384)
	if not fd then
		return nil, err
	end
	local written, write_err = fs.write_all(fd, prompt, 0)
	if written then
		pcall(vim.uv.fs_fsync, fd)
	end
	vim.uv.fs_close(fd)
	if not written then
		pcall(vim.uv.fs_unlink, path)
		return nil, write_err
	end
	return path
end

local function run_cli_provider(request, provider, repo, prompt, callback)
	local opts = config.get().ai.commit_message
	local args
	local run_opts = {
		cwd = repo.root,
		timeout = opts.timeout_ms,
		stdin = prompt,
		on_exit_during_shutdown = true,
	}

	if provider == "claude" then
		args = {
			"claude",
			"-p",
			"Follow the instructions and change context supplied on standard input.",
			"--output-format",
			"text",
			"--no-session-persistence",
			"--disallowedTools",
			"*",
		}
	elseif provider == "codex" then
		args = {
			"codex",
			"--ask-for-approval",
			"never",
			"exec",
			"--skip-git-repo-check",
			"--ephemeral",
			"--sandbox",
			"read-only",
			"-",
		}
	elseif provider == "gemini" then
		args = { "gemini", "--output-format", "text", "--skip-trust", "--approval-mode", "plan" }
	elseif provider == "copilot_cli" then
		local attachment, attachment_err = write_private_attachment(prompt)
		if not attachment then
			return callback(nil, "Could not create private Copilot context attachment: " .. tostring(attachment_err))
		end
		request:add_cleanup(function()
			pcall(vim.uv.fs_unlink, attachment)
		end)
		args = {
			"copilot",
			"-p",
			"Generate the requested commit subject from the attached context. Return only one line.",
			"--attachment",
			attachment,
			"--output-format",
			"text",
			"--no-custom-instructions",
			"--available-tools",
			"",
		}
		run_opts.stdin = nil
	else
		return callback(nil, "Unsupported commit message provider: " .. provider)
	end

	local handle = util.system_start(args, run_opts, function(result, err)
		if runtime.is_shutting_down() then
			request.active = false
			request.handle = nil
			request:cleanup()
			return
		end
		if not request.active then
			return
		end
		request.handle = nil
		if err then
			return callback(nil, err)
		end
		local message = clean_message(result and result.stdout or "")
		if message == "" then
			return callback(nil, provider .. " returned an empty commit message")
		end
		callback(message)
	end)
	request:set_handle(handle)
end

local function run_provider(request, provider, repo, prompt, callback)
	if provider == "copilotchat" then
		local handle = require("lazyvcs.source_control.copilotchat").start(prompt, {
			timeout_ms = config.get().ai.commit_message.timeout_ms,
		}, function(message, err)
			if not request.active then
				return
			end
			request.handle = nil
			local cleaned = message and clean_message(message)
			if message and cleaned == "" then
				return callback(nil, "CopilotChat returned an empty commit message")
			end
			callback(cleaned, err)
		end)
		request:set_handle(handle)
		return
	end
	run_cli_provider(request, provider, repo, prompt, callback)
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

local function try_provider(request, providers, index, repo, prompt, callback)
	if not request.active then
		return
	end
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
		return try_provider(request, providers, index + 1, repo, prompt, callback)
	end
	run_provider(request, provider, repo, prompt, function(message, err)
		if not request.active then
			return
		end
		if message then
			last_error_by_provider[provider] = nil
			return callback(message, nil, provider)
		end
		last_error_by_provider[provider] = err or "failed"
		if config.get().ai.commit_message.provider == "auto" then
			return try_provider(request, providers, index + 1, repo, prompt, callback)
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

function M.generate(repo, callback, opts)
	opts = opts or {}
	if config.get().ai.commit_message.provider == "off" then
		return nil, "AI commit-message generation is disabled"
	end

	local providers = configured_providers()
	if #providers == 0 then
		return nil, "No AI commit-message provider is configured"
	end

	local request = new_request(callback)
	request.repo = repo
	request.owner = opts.owner or repo.root
	confirm_privacy(function(accepted)
		if not request.active then
			return
		end
		if not accepted then
			return request:finish(nil, nil)
		end
		local context_callback = function(context)
			if not request.active then
				return
			end
			if util.trim(context) == "" then
				return request:finish(nil, "No changes available to summarize")
			end
			local prompt = build_prompt(repo, context)
			try_provider(request, providers, 1, repo, prompt, function(message, err, provider)
				request:finish(message, err, provider)
			end)
		end
		if repo.vcs == "git" then
			git_context(request, repo.root, context_callback)
		else
			svn_context(request, repo.root, context_callback)
		end
	end)

	return request
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
