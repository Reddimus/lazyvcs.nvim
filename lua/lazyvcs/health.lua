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

	local has_gitsigns = package.loaded.gitsigns ~= nil or pcall(require, "gitsigns")
	if has_gitsigns then
		ok("gitsigns.nvim available for Git hunk reset delegation")
	else
		warn("gitsigns.nvim not available; Git hunk reset will fall back to plugin-owned replacement")
	end
end

return M
