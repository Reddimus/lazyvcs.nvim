local M = {}

local health = vim.health

function M.check()
	health.start("lazyvcs.nvim")
	health.info("Running Neovim " .. tostring(vim.version()))

	-- Requirements ----------------------------------------------------------
	if vim.fn.has("nvim-0.11") == 1 then
		health.ok("Neovim 0.11+ (vim.system, vim.text.diff/vim.diff, vim.uv and current vim.validate)")
	else
		health.error("Neovim 0.11+ is required (config validation uses the 0.11 vim.validate signature)")
	end

	if vim.fn.has("win32") == 1 then
		if pcall(require, "ffi") then
			health.ok("LuaJIT FFI is available for Windows command-tree ownership")
		else
			health.error("Windows command-tree ownership requires a standard LuaJIT Neovim build")
		end
	end

	local git = vim.fn.executable("git") == 1
	local svn = vim.fn.executable("svn") == 1
	if git then
		health.ok("git executable found")
	else
		health.warn("git executable not found; the Git backend is unavailable")
	end
	if svn then
		health.ok("svn executable found")
	else
		health.warn("svn executable not found; the SVN backend is unavailable")
	end
	if not git and not svn then
		health.error("Neither git nor svn is available; lazyvcs cannot detect any working copy")
	end

	-- Configuration ---------------------------------------------------------
	health.start("lazyvcs.nvim: configuration")
	local cfg = require("lazyvcs.config").get()
	if not require("lazyvcs").is_initialized() then
		health.warn("setup() has not run; the following settings are defaults, not active features")
	end

	if cfg.signs.enabled then
		health.ok("Gutter signs configured: enabled")
		if cfg.use_gitsigns then
			local has_gitsigns = package.loaded["gitsigns"] ~= nil or pcall(require, "gitsigns")
			if has_gitsigns then
				health.ok(
					"gitsigns.nvim detected; eligible Git buffers delegate signs to it; unattached buffers use native signs"
				)
			else
				health.ok("gitsigns.nvim not installed; lazyvcs renders Git signs natively")
			end
		else
			health.ok("use_gitsigns is false; lazyvcs renders Git signs natively")
		end
	else
		health.warn("Gutter signs are disabled by config (signs.enabled = false)")
	end

	health.ok("Configured blame mode: " .. cfg.blame.mode .. "; inline visibility can be toggled at runtime")
	if cfg.blame.persist and cfg.blame.mode == "inline" then
		health.ok("Blame state persists across sessions (" .. require("lazyvcs.store").path() .. ")")
	else
		health.ok("Blame persistence applies only to inline mode and is disabled for this configuration")
	end

	-- Integrations ----------------------------------------------------------
	health.start("lazyvcs.nvim: integrations")
	local optional = require("lazyvcs.integrations.optional").status()
	health.ok("Integration mode: " .. optional.mode)
	for _, item in ipairs(optional.items) do
		if item.key == "gitsigns" and item.available and not cfg.use_gitsigns then
			health.ok("gitsigns.nvim installed but not selected (use_gitsigns = false); native Git signs are used")
		elseif item.available then
			health.ok(string.format("%s available for %s", item.label, item.feature))
		else
			health.ok(string.format("%s not installed; using %s", item.label, item.fallback))
		end
	end

	-- AI commit messages ----------------------------------------------------
	health.start("lazyvcs.nvim: AI commit messages")
	local ai = require("lazyvcs.source_control.ai")
	local selected = cfg.ai.commit_message.provider
	health.ok("Provider: " .. selected)
	if selected ~= "off" and not ai.available() then
		health.warn(
			"No configured AI provider detected; install the selected provider or select an installed provider (or auto)"
		)
	end
	if cfg.ai.commit_message.provider == "auto" then
		health.ok("Auto provider order: " .. table.concat(cfg.ai.commit_message.provider_order, ", "))
	end
	local selected_providers = {}
	for _, provider in ipairs(selected == "auto" and cfg.ai.commit_message.provider_order or { selected }) do
		selected_providers[provider] = true
	end
	for _, item in ipairs(ai.status()) do
		if item.available then
			health.ok(
				string.format(
					"Provider %s installed%s (authentication not checked)",
					item.provider,
					not selected_providers[item.provider] and ", not selected" or ""
				)
			)
		elseif item.last_error then
			health.warn(string.format("Provider %s unavailable: %s", item.provider, item.last_error))
		else
			health.ok(string.format("Provider %s not available", item.provider))
		end
	end
end

return M
