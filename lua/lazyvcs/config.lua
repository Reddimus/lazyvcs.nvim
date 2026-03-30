local M = {}

local defaults = {
	debounce_ms = 120,
	base_window = {
		width = 0.5,
	},
	use_gitsigns = true,
	set_winbar = true,
	session_keymaps = true,
	keymaps = {
		close = "q",
		next_hunk = "]v",
		prev_hunk = "[v",
		revert_hunk = "<leader>vr",
	},
}

local options = vim.deepcopy(defaults)

local function normalize_width(width)
	if width <= 0 then
		error("lazyvcs base_window.width must be greater than 0")
	end

	if width <= 1 then
		return width
	end

	return math.floor(width)
end

local function normalize(opts)
	vim.validate({
		debounce_ms = { opts.debounce_ms, "number" },
		use_gitsigns = { opts.use_gitsigns, "boolean" },
		set_winbar = { opts.set_winbar, "boolean" },
		session_keymaps = { opts.session_keymaps, "boolean" },
		keymaps = { opts.keymaps, "table" },
		base_window = { opts.base_window, "table" },
	})

	vim.validate({
		close = { opts.keymaps.close, "string" },
		next_hunk = { opts.keymaps.next_hunk, "string" },
		prev_hunk = { opts.keymaps.prev_hunk, "string" },
		revert_hunk = { opts.keymaps.revert_hunk, "string" },
		width = { opts.base_window.width, "number" },
	})

	opts.debounce_ms = math.max(0, math.floor(opts.debounce_ms))
	opts.base_window.width = normalize_width(opts.base_window.width)
	return opts
end

function M.setup(opts)
	options = normalize(vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {}))
	return options
end

function M.get()
	return options
end

return M
