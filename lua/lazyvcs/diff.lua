local util = require("lazyvcs.util")

local M = {}

local function normalize_hunk(item)
	return {
		base_start = item[1],
		base_count = item[2],
		current_start = item[3],
		current_count = item[4],
	}
end

function M.compute_hunks(base_lines, current_lines)
	local raw = vim.diff(util.join_lines(base_lines), util.join_lines(current_lines), {
		algorithm = "histogram",
		result_type = "indices",
	})

	local hunks = {}
	for _, item in ipairs(raw) do
		hunks[#hunks + 1] = normalize_hunk(item)
	end
	return hunks
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
		if hunk.current_count == 0 and line == math.max(start_line - 1, 1) then
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

function M.reset_hunk(bufnr, base_lines, hunk)
	local start_idx = math.max(hunk.current_start - 1, 0)
	local end_idx = start_idx + hunk.current_count

	if hunk.current_count == 0 and hunk.base_count > 0 then
		start_idx = math.max(hunk.current_start, 0)
		end_idx = start_idx
	end

	local replacement = util.slice(base_lines, hunk.base_start, hunk.base_count)
	vim.api.nvim_buf_set_lines(bufnr, start_idx, end_idx, false, replacement)
end

return M
