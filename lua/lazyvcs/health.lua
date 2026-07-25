local M = {}

local health = vim.health

function M.check()
	health.start("lazyvcs.nvim")

	-- Requirements ----------------------------------------------------------
	if vim.fn.has("nvim-0.11") == 1 then
		health.ok("Neovim 0.11+ (vim.system, vim.diff, vim.uv and the current vim.validate signature)")
	else
		health.error("Neovim 0.11+ is required (config validation uses the 0.11 vim.validate signature)")
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

	if cfg.signs.enabled then
		health.ok("Gutter signs are enabled")
		if cfg.use_gitsigns then
			local has_gitsigns = package.loaded["gitsigns"] ~= nil or pcall(require, "gitsigns")
			if has_gitsigns then
				health.ok("gitsigns.nvim detected; Git gutter signs are delegated to it")
			else
				health.ok("gitsigns.nvim not installed; lazyvcs renders Git signs natively")
			end
		else
			health.ok("use_gitsigns is false; lazyvcs renders Git signs natively")
		end
	else
		health.warn("Gutter signs are disabled by config (signs.enabled = false)")
	end

	health.ok("Inline blame mode: " .. cfg.blame.mode)
	if cfg.blame.persist then
		health.ok("Blame state persists across sessions (" .. require("lazyvcs.store").path() .. ")")
	else
		health.ok("Blame state persistence is disabled by config")
	end

	-- Integrations ----------------------------------------------------------
	health.start("lazyvcs.nvim: integrations")
	local optional = require("lazyvcs.integrations.optional").status()
	health.ok("Integration mode: " .. optional.mode)
	for _, item in ipairs(optional.items) do
		if item.available then
			health.ok(string.format("%s available for %s", item.label, item.feature))
		else
			health.ok(string.format("%s not installed; using %s", item.label, item.fallback))
		end
	end

	-- AI commit messages ----------------------------------------------------
	health.start("lazyvcs.nvim: AI commit messages")
	local ai = require("lazyvcs.source_control.ai")
	health.ok("Provider: " .. cfg.ai.commit_message.provider)
	if cfg.ai.commit_message.provider == "auto" then
		health.ok("Auto provider order: " .. table.concat(cfg.ai.commit_message.provider_order, ", "))
	end
	for _, item in ipairs(ai.status()) do
		if item.available then
			health.ok(string.format("Provider %s available", item.provider))
		elseif item.last_error then
			health.warn(string.format("Provider %s unavailable: %s", item.provider, item.last_error))
		else
			health.ok(string.format("Provider %s not available", item.provider))
		end
	end
end

return M
