local loader = require("lazyvcs.backends.blame_selection")
local util = require("lazyvcs.util")
local config = require("lazyvcs.config")
local M = {}
local requests = {}
local ns = vim.api.nvim_create_namespace("lazyvcs_blame_selection")

local function close(request)
	if request.closed then
		return
	end
	request.closed = true
	if request.handle then
		request.handle:kill()
	end
	if request.group then
		vim.api.nvim_del_augroup_by_id(request.group)
	end
	if request.win and vim.api.nvim_win_is_valid(request.win) then
		vim.api.nvim_win_close(request.win, true)
	end
	if requests[request.source] == request then
		requests[request.source] = nil
	end
end

local function write(request, lines)
	if request.closed or not vim.api.nvim_buf_is_valid(request.buf) then
		return
	end
	vim.bo[request.buf].modifiable, vim.bo[request.buf].readonly = true, false
	vim.api.nvim_buf_set_lines(request.buf, 0, -1, false, lines)
	vim.bo[request.buf].modifiable, vim.bo[request.buf].readonly = false, true
end

local function display(text)
	return (
		tostring(text or ""):gsub("[%z\1-\31\127]", function(char)
			return string.format("\\x%02x", char:byte())
		end)
	)
end

function M.open(first, last)
	local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
	local mode = vim.fn.mode()
	if first == nil and (mode == "v" or mode == "V" or mode == "\22") then
		first, last = vim.fn.line("v"), vim.fn.line(".")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
	end
	first, last = first or vim.fn.line("."), last or first or vim.fn.line(".")
	if type(first) ~= "number" or type(last) ~= "number" or first % 1 ~= 0 or last % 1 ~= 0 then
		return util.notify("Blame selection requires integer line numbers", vim.log.levels.ERROR)
	end
	if first > last then
		first, last = last, first
	end
	if first < 1 or last > vim.api.nvim_buf_line_count(source) then
		return util.notify("Blame selection is outside the buffer", vim.log.levels.ERROR)
	end
	local compare = package.loaded["lazyvcs.compare"]
	local target, target_err
	if compare then
		target, target_err = compare.blame_target(source)
	end
	if not target then
		if target_err or not util.is_real_file_buffer(source) then
			return util.notify(target_err or "Selection blame requires a file buffer", vim.log.levels.INFO)
		end
		target = { path = util.buf_path(source) }
	end
	target.first, target.last = first, last
	local path = target.path
	local bytes = target.snapshot and util.buffer_size(source)
		or math.max(util.file_size(path), util.buffer_size(source))
	if bytes > math.min(config.get().signs.max_file_bytes, 1024 * 1024) then
		return util.notify("Selection blame is limited to files of 1 MiB", vim.log.levels.INFO)
	end
	if requests[source] then
		close(requests[source])
	end
	local lines = util.get_buf_lines(source)
	local request = { source = source, tick = vim.api.nvim_buf_get_changedtick(source), first = first, last = last }
	requests[source] = request
	request.buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(request.buf, "lazyvcs://blame-selection/" .. source)
	vim.bo[request.buf].bufhidden, vim.bo[request.buf].swapfile = "wipe", false
	vim.bo[request.buf].filetype = "lazyvcs-blame-selection"
	write(request, { "Loading blame for lines " .. first .. "-" .. last .. "..." })
	vim.bo[request.buf].readonly = true
	request.win = vim.api.nvim_open_win(request.buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		row = 1,
		col = 1,
		width = math.max(1, math.min(120, vim.o.columns - 4)),
		height = math.max(1, math.min(last - first + 4, vim.o.lines - 5)),
	})
	vim.wo[request.win].wrap, vim.wo[request.win].cursorline = false, true
	vim.wo[request.win].winbar = "Blame " .. display(path):gsub("%%", "%%%%") .. " | " .. first .. "-" .. last
	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			close(request)
		end, { buffer = request.buf, silent = true, desc = "Close selection blame" })
	end
	request.group = vim.api.nvim_create_augroup("lazyvcs_blame_selection_" .. source, { clear = true })
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = request.group,
		buffer = source,
		callback = function()
			close(request)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = request.group,
		pattern = tostring(request.win),
		callback = function()
			close(request)
		end,
	})
	request.handle = loader.load(target, util.join_lines(lines), function(entries, blame_err)
		if request.closed then
			return
		end
		request.handle = nil
		if
			not vim.api.nvim_buf_is_valid(source)
			or vim.api.nvim_buf_get_changedtick(source) ~= request.tick
			or (target.valid and not target.valid())
			or (not target.snapshot and util.buf_path(source) ~= path)
		then
			write(request, { "Source changed while loading. Select the lines again." })
			return
		end
		if not entries then
			write(request, { blame_err or "No blame information is available for this path." })
			return
		end
		local label = target.snapshot
				and (target.side == "base" and "Base @ " .. target.snapshot.revision or "Saved worktree")
			or "Buffer at request time"
		local out = { label .. "  |  q close", "" }
		request.entries = {}
		for number = first, last do
			local entry = entries[number]
			request.entries[number] = entry
			local metadata = "No attribution"
			if entry then
				metadata = entry.uncommitted and config.get().blame.uncommitted_text
					or table.concat({ display(entry.revision), display(entry.author), display(entry.date) }, "  ")
			end
			out[#out + 1] = string.format("%d  %s | %s", number, metadata, display(lines[number]))
		end
		write(request, out)
		for i = 3, #out do
			local ending = out[i]:find(" | ", 1, true)
			vim.api.nvim_buf_set_extmark(
				request.buf,
				ns,
				i - 1,
				0,
				{ end_col = ending and ending - 1 or #out[i], hl_group = "Comment" }
			)
		end
	end)
	request.origin_win = source_win
	return request
end
return M
