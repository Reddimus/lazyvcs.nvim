local util = require("lazyvcs.util")

local M = {}

local markdown_filetypes = {
	markdown = true,
	["markdown.mdx"] = true,
	mdx = true,
}

local markdown_extensions = {
	md = true,
	mdown = true,
	mkd = true,
	markdown = true,
	mdx = true,
}

function M.is_markdown_path(path)
	if not path or path == "" then
		return false
	end

	local ext = vim.fn.fnamemodify(path, ":e"):lower()
	return markdown_extensions[ext] == true
end

function M.is_markdown_buffer(bufnr)
	if not util.buf_is_valid(bufnr) then
		return false
	end

	local filetype = vim.bo[bufnr].filetype
	if markdown_filetypes[filetype] then
		return true
	end

	return M.is_markdown_path(util.buf_path(bufnr))
end

function M.guard_scratch_buffer(bufnr)
	if not util.buf_is_valid(bufnr) then
		return nil
	end

	vim.b[bufnr].snacks_scope = false
	vim.b[bufnr].snacks_indent = false
	pcall(vim.treesitter.stop, bufnr)
	return { bufnr = bufnr, scratch = true }
end

local function capture_var(bufnr, name)
	local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
	return { present = ok, value = value }
end

local function restore_var(bufnr, name, captured)
	if captured and captured.present then
		pcall(vim.api.nvim_buf_set_var, bufnr, name, captured.value)
	else
		pcall(vim.api.nvim_buf_del_var, bufnr, name)
	end
end

function M.guard_markdown_buffer(bufnr, path)
	if not util.buf_is_valid(bufnr) then
		return nil
	end

	if not (markdown_filetypes[vim.bo[bufnr].filetype] or M.is_markdown_path(path or util.buf_path(bufnr))) then
		return nil
	end

	local highlighter = vim.treesitter.highlighter
	local state = {
		bufnr = bufnr,
		snacks_scope = capture_var(bufnr, "snacks_scope"),
		snacks_indent = capture_var(bufnr, "snacks_indent"),
		treesitter_active = highlighter and highlighter.active and highlighter.active[bufnr] ~= nil or false,
	}
	vim.b[bufnr].snacks_scope = false
	vim.b[bufnr].snacks_indent = false
	pcall(vim.treesitter.stop, bufnr)
	return state
end

function M.restore_buffer(state)
	if not state or state.scratch or not util.buf_is_valid(state.bufnr) then
		return
	end

	restore_var(state.bufnr, "snacks_scope", state.snacks_scope)
	restore_var(state.bufnr, "snacks_indent", state.snacks_indent)
	if state.treesitter_active then
		pcall(vim.treesitter.start, state.bufnr)
	end
end

return M
