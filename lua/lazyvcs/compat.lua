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
