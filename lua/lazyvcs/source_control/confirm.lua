local util = require("lazyvcs.util")
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

local function popup_content(prompt)
	local max_width = math.max(1, vim.o.columns - 4)
	local content_width = vim.fn.strdisplaywidth(prompt)
	for _, item in ipairs(options) do
		content_width = math.max(content_width, vim.fn.strdisplaywidth(item.key .. ". " .. item.label))
	end
	local width = math.min(math.max(36, content_width + 6), max_width)
	local lines, option_rows, first_option = {}, {}, nil
	local function append(text, index)
		local line, cells = "", 0
		for _, char in ipairs(vim.fn.split(text, "\\zs")) do
			local char_width = vim.fn.strdisplaywidth(char)
			if cells + char_width > width and line ~= "" then
				lines[#lines + 1] = line
				option_rows[#lines] = index
				line, cells = "", 0
			end
			line, cells = line .. char, cells + char_width
		end
		lines[#lines + 1] = line
		option_rows[#lines] = index
	end
	append(prompt)
	lines[#lines + 1] = ""
	for index, item in ipairs(options) do
		first_option = first_option or (#lines + 1)
		append(item.key .. ". " .. item.label, index)
	end
	local height = math.min(#lines, math.max(1, vim.o.lines - 6))
	return lines,
		option_rows,
		first_option,
		{
			width = width,
			height = height,
			row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
			col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		}
end

function M.open(opts, on_choice)
	vim.cmd("stopinsert")
	opts = opts or {}
	local prompt = vim.fn.strtrans(opts.prompt or "Confirm action?")
	local previous_win = vim.api.nvim_get_current_win()
	local previous_cursor = vim.api.nvim_win_is_valid(previous_win) and vim.api.nvim_win_get_cursor(previous_win) or nil
	local bufnr = vim.api.nvim_create_buf(false, true)
	local lines, option_rows, first_option, size = popup_content(prompt)
	local winid = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " Confirm ",
		title_pos = "center",
		row = size.row,
		col = size.col,
		width = size.width,
		height = size.height,
	})
	util.unbind_window(winid)

	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].swapfile = false
	util.set_win_option(winid, "cursorline", true)
	util.set_win_option(winid, "number", false)
	util.set_win_option(winid, "relativenumber", false)
	util.set_win_option(winid, "signcolumn", "no")
	util.set_win_option(winid, "foldcolumn", "0")
	util.set_win_option(winid, "foldenable", false)
	util.set_win_option(winid, "wrap", true)
	util.set_win_option(winid, "winhighlight", "Normal:NormalFloat,FloatBorder:FloatBorder,CursorLine:Visual")

	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	vim.api.nvim_win_set_cursor(winid, { #lines <= size.height and first_option or 1, 0 })

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

	local function selection()
		if not vim.api.nvim_win_is_valid(winid) or vim.api.nvim_win_get_buf(winid) ~= bufnr then
			return nil
		end
		local row = vim.api.nvim_win_get_cursor(winid)[1]
		return option_rows[row]
	end

	local function move(delta)
		if owner:is_live() then
			local row = vim.api.nvim_win_get_cursor(winid)[1]
			vim.api.nvim_win_set_cursor(winid, { math.max(1, math.min(#lines, row + delta)), 0 })
		end
	end

	local map_opts = { buffer = bufnr, nowait = true, silent = true }
	for _, lhs in ipairs({ "j", "<Down>" }) do
		compat.keymap_set("n", lhs, function()
			move(1)
		end, map_opts)
	end
	for _, lhs in ipairs({ "k", "<Up>" }) do
		compat.keymap_set("n", lhs, function()
			move(-1)
		end, map_opts)
	end
	for index, item in ipairs(options) do
		compat.keymap_set("n", item.key, function()
			choose(index)
		end, map_opts)
	end
	compat.keymap_set("n", "<CR>", function()
		choose(selection())
	end, map_opts)
	compat.keymap_set("n", "q", function()
		owner:finish("cancel")
	end, map_opts)
	compat.keymap_set("n", "<Esc>", function()
		owner:finish("cancel")
	end, map_opts)

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

if vim.env.LAZYVCS_TEST_GROUP and vim.env.LAZYVCS_TEST_GROUP ~= "" then
	function M._test_reset_session()
		mutation_prompts_suppressed = false
	end
end

return M
