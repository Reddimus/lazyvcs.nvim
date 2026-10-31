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

local guards = {}

function M.refresh_guard(token)
	local state = token and guards[token.bufnr]
	if not state or not util.buf_is_valid(token.bufnr) then
		return
	end
	local highlighter = vim.treesitter.highlighter
	local active = highlighter and highlighter.active and highlighter.active[token.bufnr]
	if active and not state.treesitter_active then
		state.treesitter_active = true
		state.treesitter_language = active.tree:lang()
	end
	vim.b[token.bufnr].snacks_scope = false
	vim.b[token.bufnr].snacks_indent = false
	pcall(vim.treesitter.stop, token.bufnr)
end

function M.guard_markdown_buffer(bufnr, path)
	if not util.buf_is_valid(bufnr) then
		return nil
	end
	if not (markdown_filetypes[vim.bo[bufnr].filetype] or M.is_markdown_path(path or util.buf_path(bufnr))) then
		return nil
	end
	local state = guards[bufnr]
	if not state then
		state = {
			bufnr = bufnr,
			snacks_scope = capture_var(bufnr, "snacks_scope"),
			snacks_indent = capture_var(bufnr, "snacks_indent"),
			owners = {},
		}
		guards[bufnr] = state
		state.cleanup = vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = bufnr,
			once = true,
			callback = function()
				if guards[bufnr] == state then
					guards[bufnr] = nil
				end
			end,
		})
	end
	local token = { bufnr = bufnr }
	state.owners[token] = true
	M.refresh_guard(token)
	return token
end

function M.restore_buffer(token)
	if not token then
		return
	end
	local state = guards[token.bufnr]
	if not state or not state.owners[token] then
		return
	end
	state.owners[token] = nil
	if next(state.owners) then
		return
	end
	guards[token.bufnr] = nil
	if state.cleanup then
		pcall(vim.api.nvim_del_autocmd, state.cleanup)
	end
	if not util.buf_is_valid(token.bufnr) then
		return
	end
	restore_var(token.bufnr, "snacks_scope", state.snacks_scope)
	restore_var(token.bufnr, "snacks_indent", state.snacks_indent)
	if state.treesitter_active then
		pcall(vim.treesitter.start, token.bufnr, state.treesitter_language)
	end
end

return M
