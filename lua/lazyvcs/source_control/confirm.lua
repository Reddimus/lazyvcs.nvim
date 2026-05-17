local M = {}

local options = {
	{ key = "1", label = "Confirm", action = "confirm" },
	{ key = "2", label = "Confirm and do not ask again this session", action = "confirm_session" },
	{ key = "3", label = "Cancel", action = "cancel" },
}

local function clamp(value, min, max)
	return math.max(min, math.min(max, value))
end

local function popup_size(prompt)
	local width = vim.fn.strdisplaywidth(prompt or "")
	for _, item in ipairs(options) do
		width = math.max(width, vim.fn.strdisplaywidth(item.key .. ". " .. item.label))
	end
	local max_width = math.max(10, vim.o.columns - 4)
	local min_width = math.min(36, max_width)
	width = clamp(width + 6, min_width, max_width)
	return {
		width = width,
		height = #options,
		row = math.max(0, math.floor((vim.o.lines - #options) / 2) - 2),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
	}
end

function M.open(opts, on_choice)
	opts = opts or {}
	local prompt = opts.prompt or "Confirm action?"
	local selected = 1
	local previous_win = vim.api.nvim_get_current_win()
	local previous_cursor = vim.api.nvim_win_is_valid(previous_win) and vim.api.nvim_win_get_cursor(previous_win) or nil
	local closed = false
	local bufnr = vim.api.nvim_create_buf(false, true)
	local size = popup_size(prompt)
	local winid = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " " .. prompt .. " ",
		title_pos = "center",
		row = size.row,
		col = size.col,
		width = size.width,
		height = size.height,
	})

	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].swapfile = false
	vim.wo[winid].cursorline = true
	vim.wo[winid].number = false
	vim.wo[winid].relativenumber = false
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].foldcolumn = "0"
	vim.wo[winid].wrap = false
	vim.wo[winid].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:Visual"

	local function render()
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local lines = {}
		for _, item in ipairs(options) do
			lines[#lines + 1] = item.key .. ". " .. item.label
		end
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = false
		if vim.api.nvim_win_is_valid(winid) then
			vim.api.nvim_win_set_cursor(winid, { selected, 0 })
		end
	end

	local function finish(action)
		if closed then
			return
		end
		closed = true
		if vim.api.nvim_win_is_valid(winid) then
			pcall(vim.api.nvim_win_close, winid, true)
		end
		if vim.api.nvim_win_is_valid(previous_win) then
			vim.api.nvim_set_current_win(previous_win)
			if previous_cursor then
				pcall(vim.api.nvim_win_set_cursor, previous_win, previous_cursor)
			end
		end
		if type(on_choice) == "function" then
			on_choice(action)
		end
	end

	local function choose(index)
		local item = options[index]
		finish(item and item.action or "cancel")
	end

	local function move(delta)
		selected = ((selected - 1 + delta) % #options) + 1
		if vim.api.nvim_win_is_valid(winid) then
			vim.api.nvim_win_set_cursor(winid, { selected, 0 })
		end
	end

	local map_opts = { buffer = bufnr, nowait = true, silent = true }
	for index, item in ipairs(options) do
		vim.keymap.set("n", item.key, function()
			choose(index)
		end, map_opts)
	end
	vim.keymap.set("n", "<CR>", function()
		choose(selected)
	end, map_opts)
	vim.keymap.set("n", "j", function()
		move(1)
	end, map_opts)
	vim.keymap.set("n", "<Down>", function()
		move(1)
	end, map_opts)
	vim.keymap.set("n", "k", function()
		move(-1)
	end, map_opts)
	vim.keymap.set("n", "<Up>", function()
		move(-1)
	end, map_opts)
	vim.keymap.set("n", "q", function()
		finish("cancel")
	end, map_opts)
	vim.keymap.set("n", "<Esc>", function()
		finish("cancel")
	end, map_opts)

	render()
	return {
		bufnr = bufnr,
		winid = winid,
		close = function()
			finish("cancel")
		end,
	}
end

return M
