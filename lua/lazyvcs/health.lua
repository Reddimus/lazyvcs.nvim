local M = {}

function M.check()
	local health = vim.health or require("health")
	local ok = health.ok or health.report_ok
	local warn = health.warn or health.report_warn
	local start = health.start or health.report_start

	start("lazyvcs.nvim")

	if vim.fn.has("nvim-0.10") == 1 then
		ok("Neovim version supports vim.system, vim.diff, and modern Lua APIs")
	else
		warn("Neovim 0.10+ is recommended")
	end

	if vim.fn.executable("git") == 1 then
		ok("git executable found")
	else
		warn("git executable not found; Git backend will be unavailable")
	end

	if vim.fn.executable("svn") == 1 then
		ok("svn executable found")
	else
		warn("svn executable not found; SVN backend will be unavailable")
	end

	local cfg = require("lazyvcs.config").get()
	if cfg.signs.enabled then
		ok("SVN inline signs are enabled")
	else
		ok("SVN inline signs are disabled by config")
	end
	if cfg.compat.svnsigns_commands then
		ok("svnsigns.nvim compatibility commands are enabled")
	else
		ok("svnsigns.nvim compatibility commands are disabled")
	end

	if cfg.blame.persist then
		ok("inline blame state is persisted across sessions (" .. require("lazyvcs.store").path() .. ")")
	else
		ok("inline blame state persistence is disabled by config")
	end

	local optional = require("lazyvcs.integrations.optional").status()
	ok("integration mode: " .. optional.mode)
	for _, item in ipairs(optional.items) do
		if item.available then
			ok(string.format("%s available for %s", item.label, item.feature))
		else
			ok(string.format("%s not installed; using %s", item.label, item.fallback))
		end
	end

	local ai = require("lazyvcs.source_control.ai")
	ok("AI commit-message provider: " .. cfg.ai.commit_message.provider)
	if cfg.ai.commit_message.provider == "auto" then
		ok("AI auto provider order: " .. table.concat(cfg.ai.commit_message.provider_order, ", "))
	end
	for _, item in ipairs(ai.status()) do
		if item.available then
			ok(string.format("AI provider %s available", item.provider))
		elseif item.last_error then
			warn(string.format("AI provider %s unavailable: %s", item.provider, item.last_error))
		else
			ok(string.format("AI provider %s not available", item.provider))
		end
	end

	ok("native source-control sidebar is available without UI plugin dependencies")
	ok("legacy Neo-tree source-control adapter has been removed")
end

return M
