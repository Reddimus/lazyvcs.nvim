local loader = require("lazyvcs.backends.blame_selection")
local util = require("lazyvcs.util")
local config = require("lazyvcs.config")
local context = require("lazyvcs.blame_context")
local M = {}
local requests = {}
local ns = vim.api.nvim_create_namespace("lazyvcs_blame_selection")

local function owns_report(request)
	return requests[request.source] == request
		and not request.closed
		and util.buf_is_valid(request.buf)
		and util.win_is_valid(request.win)
		and vim.api.nvim_win_get_buf(request.win) == request.buf
end

local function retire_request(request, close_owned_window)
	if request.closed then
		return
	end
	request.closed = true
	if requests[request.source] == request then
		requests[request.source] = nil
	end
	if request.group then
		pcall(vim.api.nvim_del_augroup_by_id, request.group)
		request.group = nil
	end
	if request.handle then
		local handle = request.handle
		request.handle = nil
		pcall(handle.kill, handle)
	end
	local win = request.win
	request.win = nil
	if close_owned_window and util.win_is_valid(win) and vim.api.nvim_win_get_buf(win) == request.buf then
		pcall(vim.api.nvim_win_close, win, true)
	end
	if util.buf_is_valid(request.buf) and #vim.fn.win_findbuf(request.buf) == 0 then
		pcall(vim.api.nvim_buf_delete, request.buf, { force = true })
	end
end

local function protect(request, callback)
	return function(...)
		local ok, err = pcall(callback, ...)
		if not ok then
			retire_request(request, true)
			util.notify("Selection blame failed: " .. tostring(err):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
		end
	end
end

local function close(request)
	retire_request(request, true)
end

local function update(request, lines)
	local ok, err = pcall(function()
		vim.bo[request.buf].modifiable, vim.bo[request.buf].readonly = true, false
		vim.api.nvim_buf_set_lines(request.buf, 0, -1, false, lines)
	end)
	if vim.api.nvim_buf_is_valid(request.buf) then
		pcall(function()
			vim.bo[request.buf].modifiable, vim.bo[request.buf].readonly = false, true
		end)
	end
	return ok, err
end

local function write(request, lines)
	if request.closed or not vim.api.nvim_buf_is_valid(request.buf) then
		return false
	end
	local ok, err = update(request, lines)
	if ok then
		return true
	end
	if not update(request, { "Could not update selection blame report. Select the lines again." }) then
		retire_request(request, true)
		util.notify("Selection blame failed: " .. tostring(err):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
	end
	return false
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
	local captured, capture, contents
	if not target.snapshot then
		captured = context.capture(source, source_win)
		if not captured then
			return util.notify("Blame source changed", vim.log.levels.INFO)
		end
		local err
		contents, err, capture = context.contents(captured, math.min(config.get().signs.max_file_bytes, 1024 * 1024))
		if not contents then
			return util.notify(err, vim.log.levels.INFO)
		end
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
	if request.closed then
		return nil
	end
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
	util.unbind_window(request.win)
	util.set_win_options(request.win, { wrap = false, cursorline = true })
	util.set_win_option(
		request.win,
		"winbar",
		"Blame " .. display(path):gsub("%%", "%%%%") .. " | " .. first .. "-" .. last
	)
	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			close(request)
		end, { buffer = request.buf, silent = true, desc = "Close selection blame" })
	end
	request.group = vim.api.nvim_create_augroup("lazyvcs_blame_selection_" .. source, { clear = true })
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = request.group,
		buffer = source,
		callback = protect(request, function()
			close(request)
		end),
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = request.group,
		pattern = tostring(request.win),
		callback = protect(request, function()
			close(request)
		end),
	})
	vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
		group = request.group,
		buffer = request.buf,
		callback = protect(request, function()
			retire_request(request, false)
		end),
	})
	if captured then
		local changed = protect(request, function()
			if request.handle and not context.valid(captured) then
				local handle = request.handle
				request.handle = nil
				pcall(handle.kill, handle)
				write(request, { "Source changed while loading. Select the lines again." })
			end
		end)
		vim.api.nvim_create_autocmd(
			"OptionSet",
			{ group = request.group, pattern = context.options, callback = changed }
		)
		vim.api.nvim_create_autocmd(
			{ "BufModifiedSet", "TextChanged", "TextChangedI" },
			{ group = request.group, buffer = source, callback = changed }
		)
	end
	local check = protect(request, function()
		if not request.closed and not owns_report(request) then
			retire_request(request, false)
		end
	end)
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = request.group,
		callback = check,
	})
	vim.api.nvim_create_autocmd("BufWinLeave", {
		group = request.group,
		buffer = request.buf,
		callback = protect(request, function()
			vim.schedule(check)
		end),
	})
	protect(request, function()
		request.handle = loader.load(
			target,
			contents or target.bytes or util.join_lines(lines),
			protect(request, function(entries, blame_err)
				if not owns_report(request) then
					retire_request(request, false)
					return
				end
				request.handle = nil
				if
					not vim.api.nvim_buf_is_valid(source)
					or vim.api.nvim_buf_get_changedtick(source) ~= request.tick
					or (captured and not context.valid(captured))
					or (target.valid and not target.valid())
					or (not target.snapshot and util.buf_path(source) ~= path)
				then
					write(request, { "Source changed while loading. Select the lines again." })
					return
				end
				if not entries then
					local diagnostics = vim.split(
						(blame_err or "No blame information is available for this path."):gsub("\r\n", "\n"),
						"\n",
						{ plain = true }
					)
					write(request, vim.tbl_map(display, diagnostics))
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
							or table.concat(
								{ display(entry.revision), display(entry.author), display(entry.date) },
								"  "
							)
					end
					out[#out + 1] = string.format("%d  %s | %s", number, metadata, display(lines[number]))
				end
				if not write(request, out) then
					return
				end
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
			end),
			capture
		)
	end)()
	request.origin_win = source_win
	return request
end
function M._test_requests()
	return requests
end
return M
