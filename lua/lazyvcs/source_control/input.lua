local Input = require("nui.input")
local event = require("nui.utils.autocmd").event

local M = {}

local function popup_options(opts)
	opts = opts or {}
	local width = opts.width or math.max(50, math.floor(vim.o.columns * 0.45))
	local title = opts.title or " Input "

	return {
		position = "50%",
		size = {
			width = width,
		},
		relative = "editor",
		border = {
			style = "rounded",
			text = {
				top = title,
				top_align = "left",
			},
		},
		buf_options = {
			modifiable = true,
			readonly = false,
		},
		win_options = {
			winblend = 0,
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
		enter = true,
	}
end

function M.open_text(opts, on_submit)
	opts = opts or {}
	local input = Input(popup_options(opts), {
		prompt = opts.prompt or " ",
		default_value = opts.default_value or "",
		on_submit = function(value)
			if type(on_submit) == "function" then
				on_submit(value)
			end
		end,
	})

	input:mount()
	input:on(event.BufLeave, function()
		if input._.mounted then
			input:unmount()
		end
	end, { once = true })

	input:map("i", "<esc>", function()
		input:unmount()
	end, { noremap = true })
	input:map("n", "<esc>", function()
		input:unmount()
	end, { noremap = true })
	input:map("n", "q", function()
		input:unmount()
	end, { noremap = true })
end

function M.open(state, repo, default_value, on_submit)
	local title = string.format(" Commit Message: %s ", repo.name)
	if repo.branch and repo.branch ~= "" then
		title = string.format(" Commit Message: %s (%s) ", repo.name, repo.branch)
	end

	return M.open_text({
		title = title,
		prompt = " ",
		default_value = default_value or "",
	}, on_submit)
end

return M
