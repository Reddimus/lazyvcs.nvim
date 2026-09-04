local compat = require("lazyvcs.compat")
local config = require("lazyvcs.config")
local modal = require("lazyvcs.source_control.modal")

local M = {}
local mutation_prompts_suppressed = false

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

	local owner = modal.new({
		bufnr = bufnr,
		winid = winid,
		previous_win = previous_win,
		previous_cursor = previous_cursor,
		cancel_value = "cancel",
		before_finish = function(value)
			if
				(value == "confirm" or value == "confirm_session")
				and type(opts.before_confirm) == "function"
				and opts.before_confirm() ~= true
			then
				return "cancel"
			end
			return value
		end,
		on_finish = on_choice,
	})

	local function choose(index)
		local item = options[index]
		owner:finish(item and item.action or "cancel")
	end

	local function move(delta)
		selected = ((selected - 1 + delta) % #options) + 1
		if vim.api.nvim_win_is_valid(winid) then
			vim.api.nvim_win_set_cursor(winid, { selected, 0 })
		end
	end

	local map_opts = { buffer = bufnr, nowait = true, silent = true }
	for index, item in ipairs(options) do
		compat.keymap_set("n", item.key, function()
			choose(index)
		end, map_opts)
	end
	compat.keymap_set("n", "<CR>", function()
		choose(selected)
	end, map_opts)
	compat.keymap_set("n", "j", function()
		move(1)
	end, map_opts)
	compat.keymap_set("n", "<Down>", function()
		move(1)
	end, map_opts)
	compat.keymap_set("n", "k", function()
		move(-1)
	end, map_opts)
	compat.keymap_set("n", "<Up>", function()
		move(-1)
	end, map_opts)
	compat.keymap_set("n", "q", function()
		owner:finish("cancel")
	end, map_opts)
	compat.keymap_set("n", "<Esc>", function()
		owner:finish("cancel")
	end, map_opts)

	render()
	return {
		bufnr = bufnr,
		winid = winid,
		close = function()
			owner:finish("cancel")
		end,
		owner = owner,
	}
end

function M.mutation(opts, on_confirm, on_cancel)
	opts = opts or {}
	local validation_ran = false
	local function validate()
		validation_ran = true
		return type(opts.before_confirm) ~= "function" or opts.before_confirm() == true
	end
	local function cancel()
		if on_cancel then
			return on_cancel()
		end
	end
	if not config.get().source_control.confirm_mutations or mutation_prompts_suppressed then
		if not validate() then
			return cancel()
		end
		return on_confirm()
	end
	local open_opts = vim.tbl_extend("force", opts, { before_confirm = validate })
	return M.open(open_opts, function(choice)
		if choice == "confirm" or choice == "confirm_session" then
			if not validation_ran and not validate() then
				return cancel()
			end
			if choice == "confirm_session" then
				mutation_prompts_suppressed = true
			end
			return on_confirm()
		end
		return cancel()
	end)
end

function M._test_reset_session()
	mutation_prompts_suppressed = false
end

return M
