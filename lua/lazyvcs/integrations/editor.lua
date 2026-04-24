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
		return
	end

	vim.b[bufnr].snacks_scope = false
	vim.b[bufnr].snacks_indent = false
	pcall(vim.treesitter.stop, bufnr)
end

function M.guard_markdown_buffer(bufnr, path)
	if not util.buf_is_valid(bufnr) then
		return
	end

	if not (markdown_filetypes[vim.bo[bufnr].filetype] or M.is_markdown_path(path or util.buf_path(bufnr))) then
		return
	end

	vim.b[bufnr].snacks_scope = false
	vim.b[bufnr].snacks_indent = false
	pcall(vim.treesitter.stop, bufnr)
end

return M
