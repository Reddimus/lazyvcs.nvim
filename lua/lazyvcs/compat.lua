local M = {}

---Use the Neovim 0.12 name while retaining the documented 0.11 floor.
function M.diff(a, b, opts)
	if vim.text and type(vim.text.diff) == "function" then
		return vim.text.diff(a, b, opts)
	end
	---@diagnostic disable-next-line: deprecated
	return vim.diff(a, b, opts)
end

---Set a buffer-local mapping without emitting the 0.12 `buffer` option warning.
function M.keymap_set(mode, lhs, rhs, opts)
	opts = vim.deepcopy(opts or {})
	if opts.buffer ~= nil and vim.fn.has("nvim-0.12") == 1 then
		opts.buf = opts.buffer
		opts.buffer = nil
	end
	return vim.keymap.set(mode, lhs, rhs, opts)
end

---Flag that runs a standalone Lua helper script. Neovim 0.13 removed the -ll
---interpreter; its -l mode likewise skips user config, plugins, shada and swap files.
M.lua_flag = vim.fn.has("nvim-0.13") == 1 and "-l" or "-ll"

---Neovim 0.13 removed BufModifiedSet. Its replacement, `OptionSet modified`,
---runs on the next event-loop tick with the changed buffer current.
M.buf_modified_set = vim.fn.exists("##BufModifiedSet") == 1

---Run `opts.callback(args)` after a buffer's 'modified' flag changes, with
---`args.buf` set to that buffer. `opts.buffer` limits the autocmd to one buffer.
---@param opts { group: integer, buffer?: integer, callback: fun(args: table): any }
---@return integer
function M.on_modified(opts)
	if M.buf_modified_set then
		return vim.api.nvim_create_autocmd("BufModifiedSet", {
			group = opts.group,
			buffer = opts.buffer,
			callback = opts.callback,
		})
	end
	return vim.api.nvim_create_autocmd("OptionSet", {
		group = opts.group,
		pattern = "modified",
		callback = function(args)
			local buf = vim.api.nvim_get_current_buf()
			if opts.buffer == nil or opts.buffer == buf then
				args.buf = buf
				return opts.callback(args)
			end
		end,
	})
end

---Fire the 'modified' change event for `buf`, as Neovim does after an edit.
function M.exec_modified_autocmds(buf)
	if M.buf_modified_set then
		return vim.api.nvim_exec_autocmds("BufModifiedSet", { buffer = buf })
	end
	vim.api.nvim_buf_call(buf, function()
		vim.api.nvim_exec_autocmds("OptionSet", { pattern = "modified" })
	end)
end

---Delete a buffer-local mapping across Neovim 0.11 and 0.12.
function M.keymap_del(mode, lhs, opts)
	opts = vim.deepcopy(opts or {})
	if opts.buffer ~= nil and vim.fn.has("nvim-0.12") == 1 then
		opts.buf = opts.buffer
		opts.buffer = nil
	end
	return vim.keymap.del(mode, lhs, opts)
end

return M
