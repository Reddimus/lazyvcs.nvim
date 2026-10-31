local util = require("lazyvcs.util")
local text = require("lazyvcs.compare_text")
local compat = require("lazyvcs.compat")

local M = {}

-- Use native diff's split/ignore rules for ranges exposed beside native panes.
function M.native_options()
	local result = { algorithm = "myers", result_type = "indices" }
	for part in vim.o.diffopt:gmatch("[^,]+") do
		local algorithm = part:match("^algorithm:(.+)$")
		local linematch = part:match("^linematch:(%d+)$")
		if algorithm then
			result.algorithm = algorithm
		elseif linematch then
			result.linematch = tonumber(linematch)
		elseif part == "indent-heuristic" then
			result.indent_heuristic = true
		elseif part == "iwhite" then
			result.ignore_whitespace_change = true
		elseif part == "iwhiteall" then
			result.ignore_whitespace = true
		elseif part == "iwhiteeol" then
			result.ignore_whitespace_change_at_eol = true
		elseif part == "iblank" then
			result.ignore_blank_lines = true
		end
	end
	return result
end

-- Native icase has Unicode behavior that differs from tolower(), and the Lua
-- diff API exposes no equivalent flag. Never act on unrepresentable ranges.
function M.native_hunks_supported()
	if ("," .. vim.o.diffopt .. ","):find(",icase,", 1, true) then
		return false, "Native hunk commands are unavailable with diffopt icase; use :set diffopt-=icase"
	end
	return true
end

local function normalize_hunk(item)
	return {
		base_start = item[1],
		base_count = item[2],
		current_start = item[3],
		current_count = item[4],
	}
end

function M.compute_hunks(base_lines, current_lines, options)
	local raw = compat.diff(util.join_lines(base_lines), util.join_lines(current_lines), options or M.native_options())

	local hunks = {}
	if type(raw) ~= "table" then
		return hunks
	end
	for _, item in ipairs(raw) do
		hunks[#hunks + 1] = normalize_hunk(item)
	end
	return hunks
end

function M.decode_base(bufnr, payload, limit)
	local profile, err = text.profile(bufnr)
	if not profile then
		return nil, err
	end
	local document, rejection
	if payload.base_bytes ~= nil then
		local decode_profile =
			vim.tbl_extend("force", profile, { fileencoding = payload.base_encoding or profile.fileencoding })
		document, err, rejection = text.decode(payload.base_bytes, decode_profile, limit)
	else
		local lines = payload.base_lines or {}
		local size = 0
		for _, line in ipairs(lines) do
			size = size + #line + 1
			if size > limit then
				return nil, "Decoded base exceeds the editable content limit", "too_large"
			end
		end
		document = {
			lines = lines,
			eol = true,
			empty = #lines == 0,
			encoding = "utf-8",
			bom = false,
			profile_key = profile.key,
		}
	end
	if document then
		payload.base_bytes = nil
	end
	return document, err, rejection
end

---@param base LazyVcsText
---@param current LazyVcsText
---@return table[] hunks
function M.compute_text_hunks(base, current, options)
	local raw = compat.diff(text.serialize(base), text.serialize(current), options or M.native_options())
	return M.text_hunks(raw, base, current)
end

-- A final empty physical row without EOL serializes as the preceding record's
-- newline. Extend terminal diff ranges back through that physical row.
local function record_count(document)
	return #document.lines - (not document.eol and document.lines[#document.lines] == "" and 1 or 0)
end

local function physical_range(start, count, document)
	local records = record_count(document)
	local terminal = start + math.max(count - 1, 0) >= records
	if terminal and #document.lines > records then
		if count == 0 then
			start = start + 1
		end
		count = count + #document.lines - records
	end
	return start, count, terminal
end

function M.text_hunks(raw, base, current)
	local hunks = {}
	for _, item in ipairs(type(raw) == "table" and raw or {}) do
		local hunk = normalize_hunk(item)
		local base_eof, current_eof
		hunk.base_start, hunk.base_count, base_eof = physical_range(hunk.base_start, hunk.base_count, base)
		hunk.current_start, hunk.current_count, current_eof =
			physical_range(hunk.current_start, hunk.current_count, current)
		hunk.covers_eof = base_eof and current_eof
		hunks[#hunks + 1] = hunk
	end
	if (base.eof_marker or false) ~= (current.eof_marker or false) then
		local last = hunks[#hunks]
		if not last or not last.covers_eof then
			hunks[#hunks + 1] = {
				base_start = math.max(#base.lines, 1),
				base_count = base.empty and 0 or 1,
				current_start = math.max(#current.lines, 1),
				current_count = current.empty and 0 or 1,
				covers_eof = true,
			}
		end
	end
	return hunks
end

---@param bufnr integer
---@param base LazyVcsText
---@param current LazyVcsText
---@param hunk table
function M.reset_text_hunk(bufnr, base, current, hunk)
	local start_row = hunk.current_count == 0 and hunk.current_start or math.max(hunk.current_start - 1, 0)
	local end_row = current.empty and -1 or start_row + hunk.current_count
	local base_eol
	if hunk.covers_eof and not base.empty then
		base_eol = base.eol
	end
	M.reset_hunk_lines(bufnr, start_row, end_row, util.slice(base.lines, hunk.base_start, hunk.base_count), base_eol)
	if hunk.covers_eof then
		vim.bo[bufnr].endoffile = base.eof_marker or false
		if base.eof_marker then
			vim.bo[bufnr].fixendofline = false
			vim.bo[bufnr].modified = true
		end
	end
end

---@param bufnr integer
---@param start_row integer
---@param end_row integer
---@param replacement string[]
---@param base_eol boolean?
function M.reset_hunk_lines(bufnr, start_row, end_row, replacement, base_eol)
	vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, replacement)
	if base_eol ~= nil then
		local changed = vim.bo[bufnr].endofline ~= base_eol
		vim.bo[bufnr].endofline = base_eol
		if not base_eol then
			vim.bo[bufnr].fixendofline = false
		end
		-- With 'fixendofline' set, Neovim ignores 'endofline' when deciding whether the
		-- buffer is modified, so :update and autosave would skip an EOF-only revert.
		if changed then
			vim.bo[bufnr].modified = true
		end
	end
end

function M.hunk_anchor(hunk)
	return math.max(hunk.current_start, 1)
end

function M.hunk_last_line(hunk)
	if hunk.current_count == 0 then
		return M.hunk_anchor(hunk)
	end
	return hunk.current_start + hunk.current_count - 1
end

function M.find_current_hunk(hunks, line)
	for _, hunk in ipairs(hunks) do
		local start_line = M.hunk_anchor(hunk)
		local end_line = M.hunk_last_line(hunk)
		if line >= start_line and line <= end_line then
			return hunk
		end
	end
	return nil
end

function M.find_neighbor_hunk(hunks, line, direction)
	if direction == "next" then
		for _, hunk in ipairs(hunks) do
			if M.hunk_anchor(hunk) > line then
				return hunk
			end
		end
		return hunks[1]
	end

	for idx = #hunks, 1, -1 do
		local hunk = hunks[idx]
		if M.hunk_last_line(hunk) < line then
			return hunk
		end
	end
	return hunks[#hunks]
end

function M.compute_target_view(hunk, win_height, line_count)
	local anchor = M.hunk_anchor(hunk)
	local hunk_end = M.hunk_last_line(hunk)
	local hunk_height = math.max(hunk_end - anchor + 1, 1)
	local visible_height = math.max(win_height, 1)
	local max_topline = math.max(line_count - visible_height + 1, 1)

	local topline
	if hunk_height >= visible_height then
		topline = anchor
	else
		local top_padding = math.floor((visible_height - hunk_height) / 2)
		topline = anchor - top_padding
	end

	return {
		lnum = math.max(1, math.min(anchor, line_count)),
		col = 0,
		curswant = 0,
		topline = math.max(1, math.min(topline, max_topline)),
	}
end

function M.focus_hunk(winid, bufnr, hunk)
	local view = M.compute_target_view(hunk, vim.api.nvim_win_get_height(winid), vim.api.nvim_buf_line_count(bufnr))
	vim.api.nvim_win_call(winid, function()
		vim.api.nvim_win_set_cursor(winid, { view.lnum, 0 })
		vim.cmd("normal! zv")
		vim.fn.winrestview(view)
	end)
end

return M
