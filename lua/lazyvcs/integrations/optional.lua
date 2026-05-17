local M = {}

local integrations = {
	{
		key = "gitsigns",
		label = "gitsigns.nvim",
		module = "gitsigns",
		feature = "Git hunk reset delegation",
		fallback = "plugin-owned hunk replacement",
	},
	{
		key = "snacks",
		label = "snacks.nvim",
		module = "snacks.picker.select",
		feature = "enhanced action, switch, and SVN file pickers",
		fallback = "vim.ui.select",
	},
	{
		key = "fzf_lua",
		label = "fzf-lua",
		module = "fzf-lua",
		feature = "SVN modified-file picker fallback",
		fallback = "vim.ui.select",
	},
	{
		key = "copilotchat",
		label = "CopilotChat.nvim",
		module = "CopilotChat",
		feature = "AI commit-message generation",
		fallback = "manual commit-message editing",
	},
	{
		key = "claude",
		label = "Claude CLI",
		executable = "claude",
		feature = "AI commit-message generation",
		fallback = "manual commit-message editing",
	},
	{
		key = "codex",
		label = "Codex CLI",
		executable = "codex",
		feature = "AI commit-message generation",
		fallback = "manual commit-message editing",
	},
	{
		key = "gemini",
		label = "Gemini CLI",
		executable = "gemini",
		feature = "AI commit-message generation",
		fallback = "manual commit-message editing",
	},
	{
		key = "copilot_cli",
		label = "GitHub Copilot CLI",
		executable = "copilot",
		feature = "AI commit-message generation",
		fallback = "manual commit-message editing",
	},
}

local function has_module(name)
	return package.loaded[name] ~= nil or pcall(require, name)
end

function M.status(checker)
	checker = checker or has_module
	local items = {}
	local enhanced = false
	for _, item in ipairs(integrations) do
		local available
		if item.executable then
			available = checker == has_module and vim.fn.executable(item.executable) == 1
				or checker(item.executable, item)
		else
			available = checker(item.module, item)
		end
		enhanced = enhanced or available
		items[#items + 1] = vim.tbl_extend("force", item, {
			available = available,
		})
	end
	return {
		mode = enhanced and "enhanced" or "vanilla",
		items = items,
	}
end

return M
