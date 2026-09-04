local util = require("lazyvcs.util")

local M = {}
local sequence = 0

local function cancel_task(task)
	if not task then
		return
	end
	if type(task.cancel) == "function" then
		pcall(task.cancel, task)
	elseif type(task.kill) == "function" then
		pcall(task.kill, task, 15)
	end
end

function M.new(opts)
	sequence = sequence + 1
	local owner = {
		id = sequence,
		bufnr = opts.bufnr,
		winid = opts.winid,
		previous_win = opts.previous_win,
		previous_cursor = opts.previous_cursor,
		cancel_value = opts.cancel_value,
		on_finish = opts.on_finish,
		closed = false,
	}

	function owner:set_task(task)
		if self.closed then
			cancel_task(task)
			return
		end
		if self.task and self.task ~= task then
			cancel_task(self.task)
		end
		self.task = task
	end

	function owner:is_live()
		return not self.closed and util.buf_is_valid(self.bufnr) and util.win_is_valid(self.winid)
	end

	function owner:finish(value)
		if self.closed then
			return false
		end
		self.closed = true
		cancel_task(self.task)
		self.task = nil
		if self.augroup then
			pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
			self.augroup = nil
		end
		if util.win_is_valid(self.winid) then
			if vim.api.nvim_get_current_win() == self.winid then
				pcall(function()
					vim.cmd("stopinsert")
				end)
			end
			pcall(vim.api.nvim_win_close, self.winid, true)
		end
		if util.win_is_valid(self.previous_win) then
			pcall(vim.api.nvim_set_current_win, self.previous_win)
			if self.previous_cursor then
				pcall(vim.api.nvim_win_set_cursor, self.previous_win, self.previous_cursor)
			end
		end
		if type(self.on_finish) == "function" then
			self.on_finish(value)
		end
		return true
	end

	owner.augroup = vim.api.nvim_create_augroup("lazyvcs_modal_" .. owner.id, { clear = true })
	vim.api.nvim_create_autocmd("WinClosed", {
		group = owner.augroup,
		pattern = tostring(owner.winid),
		callback = function()
			vim.schedule(function()
				owner:finish(owner.cancel_value)
			end)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = owner.augroup,
		buffer = owner.bufnr,
		callback = function()
			vim.schedule(function()
				owner:finish(owner.cancel_value)
			end)
		end,
	})

	return owner
end

return M
