local config = require("lazyvcs.config")
local util = require("lazyvcs.util")

local M = {}

local function popup_size(opts)
	local width = opts.width or math.max(50, math.floor(vim.o.columns * 0.45))
	width = math.min(width, math.max(20, vim.o.columns - 8))
	return {
		width = width,
		height = 1,
		row = math.max(1, math.floor((vim.o.lines - 1) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
	}
end

local function footer_text(opts, generating)
	local parts = {}
	if opts.can_generate then
		local cfg = config.get().ai.commit_message
		parts[#parts + 1] = (generating and "Generating..." or cfg.generate_key .. " Generate")
		parts[#parts + 1] = cfg.insert_generate_key .. " Generate"
	end
	parts[#parts + 1] = "Esc Cancel"
	return " " .. table.concat(parts, " • ") .. " "
end

local function set_footer(winid, opts, generating)
	if not util.win_is_valid(winid) then
		return
	end
	pcall(vim.api.nvim_win_set_config, winid, {
		footer = { { footer_text(opts, generating), "Comment" } },
		footer_pos = "right",
	})
end

local function restore_window(winid)
	if util.win_is_valid(winid) then
		pcall(vim.api.nvim_set_current_win, winid)
	end
end

local function line_value(bufnr)
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, 1, false), "\n")
end

local function set_line(bufnr, value)
	if util.buf_is_valid(bufnr) then
		local text = value or ""
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { text })
	end
end

function M.open_text(opts, on_submit)
	opts = opts or {}
	local previous_win = vim.api.nvim_get_current_win()
	local size = popup_size(opts)
	local bufnr = vim.api.nvim_create_buf(false, true)
	local title = opts.title or " Input "
	local closed = false
	local generating = false

	vim.api.nvim_buf_set_name(bufnr, "lazyvcs://commit-input/" .. bufnr)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { opts.default_value or "" })

	local winid = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = { { title, "FloatTitle" } },
		title_pos = "left",
		footer = { { footer_text(opts, false), "Comment" } },
		footer_pos = "right",
		width = size.width,
		height = size.height,
		row = size.row,
		col = size.col,
	})
	vim.wo[winid].winblend = 0
	vim.wo[winid].winhighlight = "Normal:Normal,FloatBorder:FloatBorder,FloatTitle:FloatTitle"
	vim.cmd("startinsert!")

	local function close(value)
		if closed then
			return
		end
		closed = true
		if util.win_is_valid(winid) then
			vim.api.nvim_win_close(winid, true)
		end
		restore_window(previous_win)
		if type(on_submit) == "function" then
			on_submit(value)
		end
	end

	local function cancel()
		close(nil)
	end

	local function submit()
		close(line_value(bufnr))
	end

	local function apply_generated(message)
		if not util.buf_is_valid(bufnr) or closed then
			return
		end
		local current = util.trim(line_value(bufnr))
		if current ~= "" then
			vim.ui.select({ "Replace current message", "Keep current message" }, {
				prompt = "Generated message is ready",
			}, function(choice)
				if choice == "Replace current message" then
					set_line(bufnr, message)
					if util.win_is_valid(winid) then
						pcall(vim.api.nvim_set_current_win, winid)
						pcall(vim.api.nvim_win_set_cursor, winid, { 1, #message })
					end
				end
			end)
		else
			set_line(bufnr, message)
			if util.win_is_valid(winid) then
				pcall(vim.api.nvim_win_set_cursor, winid, { 1, #message })
			end
		end
	end

	local function generate()
		if generating or not opts.can_generate or type(opts.on_generate) ~= "function" then
			return
		end
		generating = true
		set_footer(winid, opts, true)
		opts.on_generate(function(message, err)
			generating = false
			set_footer(winid, opts, false)
			if err then
				util.notify(err, vim.log.levels.WARN)
				return
			end
			if message and util.trim(message) ~= "" then
				apply_generated(message)
			end
		end)
	end

	local map_opts = { buffer = bufnr, nowait = true, silent = true }
	vim.keymap.set({ "n", "i" }, "<CR>", submit, map_opts)
	vim.keymap.set({ "n", "i" }, "<Esc>", cancel, map_opts)
	vim.keymap.set("n", "q", cancel, map_opts)
	if opts.can_generate then
		local cfg = config.get().ai.commit_message
		vim.keymap.set("n", cfg.generate_key, generate, map_opts)
		vim.keymap.set("i", cfg.insert_generate_key, generate, map_opts)
	end

	return {
		bufnr = bufnr,
		winid = winid,
		generate = generate,
		close = close,
	}
end

function M.open(state, repo, default_value, on_submit)
	local title = string.format(" Commit Message: %s ", repo.name)
	if repo.branch and repo.branch ~= "" then
		title = string.format(" Commit Message: %s (%s) ", repo.name, repo.branch)
	end

	local ai = require("lazyvcs.source_control.ai")
	return M.open_text({
		title = title,
		default_value = default_value or "",
		can_generate = ai.available(),
		on_generate = function(done)
			local ok, start_err = ai.generate(repo, function(message, err)
				if message then
					state.lazyvcs_commit_drafts[repo.root] = message
				end
				done(message, err)
			end)
			if not ok then
				done(nil, start_err)
			end
		end,
	}, on_submit)
end

return M
