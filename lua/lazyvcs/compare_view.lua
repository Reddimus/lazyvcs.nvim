local util = require("lazyvcs.util")
local M = {}
local ns = vim.api.nvim_create_namespace("lazyvcs_compare_rows")
local marker_ns = vim.api.nvim_create_namespace("lazyvcs_compare_marker")
local links = {
	Title = "Title",
	Base = "Directory",
	Path = "Comment",
	Hint = "Special",
	Add = "Added",
	Change = "Changed",
	Delete = "Removed",
	Conflict = "DiagnosticError",
	Current = "Special",
	Property = "DiagnosticInfo",
}
local statuses =
	{ A = "Add", ["?"] = "Add", M = "Change", T = "Change", R = "Change", C = "Change", D = "Delete", U = "Conflict" }

function M.highlights()
	for name, link in pairs(links) do
		vim.api.nvim_set_hl(0, "LazyVcsCompare" .. name, { default = true, link = link })
	end
end

function M.display(value)
	return (tostring(value):gsub("[%z\1-\31\127]", function(char)
		return string.format("\\x%02x", char:byte())
	end))
end

function M.write(buf, lines)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.bo[buf].modifiable, vim.bo[buf].readonly = true, false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].modified = false, true, false
end

function M.build(items)
	local out = { lines = {}, marks = {}, entries = {}, by_path = {}, width = 0 }
	for i, item in ipairs(items) do
		local parent, name = item.relpath:match("^(.*)/([^/]+)$")
		name = M.display(name or item.relpath)
		local line = "  " .. item.status .. " " .. name
		local marks = { { 2, 3, statuses[item.status] or "Change" } }
		if item.properties then
			marks[#marks + 1] = { #line, #line + 8, "Property" }
			line = line .. " [props]"
		end
		if item.property_check_error then
			local start = #line
			line = line .. " [property check failed]"
			marks[#marks + 1] = { start, #line, "Conflict" }
		end
		if parent then
			local start = #line
			line = line .. "  " .. M.display(parent)
			marks[#marks + 1] = { start, #line, "Path" }
		end
		out.lines[i], out.marks[i], out.entries[i] = line, marks, item
		out.by_path[item.relpath] = i
		out.width = math.max(out.width, vim.api.nvim_strwidth(line))
	end
	return out
end

function M.marker(s)
	vim.api.nvim_buf_clear_namespace(s.sidebar, marker_ns, 0, -1)
	local row = s.shown_item and s.row_by_path[s.shown_item.relpath]
	if row then
		vim.api.nvim_buf_set_extmark(s.sidebar, marker_ns, row - 1, 0, {
			virt_text = { { ">", "LazyVcsCompareCurrent" } },
			virt_text_pos = "overlay",
		})
	end
end

function M.hints(s)
	if vim.api.nvim_win_is_valid(s.sidewin) then
		util.set_win_option(
			s.sidewin,
			"statusline",
			" e " .. (s.auto_width and "restore" or "widen") .. "  ? help  q close"
		)
	end
end

function M.render(s)
	if not s.rows_cache or s.rows_cache.items ~= s.items then
		s.rows_cache = M.build(s.items or {})
		s.rows_cache.items = s.items
	end
	local cache = s.rows_cache
	local root = s.root and vim.fs.basename(s.root) or "repository"
	local lines =
		{ "Compare " .. M.display(root), "Base " .. M.display(s.base or "Select a base"), M.display(s.message or "") }
	if s.snapshot then
		lines[2] = lines[2] .. " @ " .. M.display(s.snapshot.revision):sub(1, 12)
	end
	if s.uncounted then
		lines[#lines + 1] = s.uncounted .. " without counts"
	end
	local hint_start = #lines + 1
	lines[#lines + 1] = "Enter review  P preview  o edit"
	local opts = require("lazyvcs.config").get()
	if opts.session_keymaps then
		local keys = {}
		for _, key in ipairs({ opts.keymaps.next_file, opts.keymaps.prev_file }) do
			if key then
				keys[#keys + 1] = M.display(key)
			end
		end
		if #keys > 0 then
			lines[#lines + 1] = table.concat(keys, " / ") .. " files"
		end
	end
	lines[#lines + 1] = "R refresh  b base  ? help"
	lines[#lines + 1] = ""
	local offset = #lines
	s.rows, s.row_by_path = {}, {}
	for i, line in ipairs(cache.lines) do
		lines[#lines + 1] = line
		s.rows[offset + i] = cache.entries[i]
		s.row_by_path[cache.entries[i].relpath] = offset + i
	end
	M.write(s.sidebar, lines)
	vim.api.nvim_buf_clear_namespace(s.sidebar, ns, 0, -1)
	local function mark(row, a, b, hl)
		vim.api.nvim_buf_set_extmark(s.sidebar, ns, row - 1, a, { end_col = b, hl_group = "LazyVcsCompare" .. hl })
	end
	mark(1, 0, #lines[1], "Title")
	mark(2, 0, #lines[2], "Base")
	for a, token in lines[3]:gmatch("()([+-]%d+)") do
		mark(3, a - 1, a - 1 + #token, token:sub(1, 1) == "+" and "Add" or "Delete")
	end
	for row = 4, offset do
		mark(row, 0, #lines[row], "Path")
	end
	for row = hint_start, offset - 1 do
		for a, key in lines[row]:gmatch("()(%S+)%s+%S+") do
			mark(row, a - 1, a - 1 + #key, "Hint")
		end
	end
	for i, marks in ipairs(cache.marks) do
		for _, span in ipairs(marks) do
			mark(offset + i, span[1], span[2], span[3])
		end
	end
	M.marker(s)
	M.hints(s)
	util.set_win_option(
		s.sidewin,
		"winbar",
		"%#LazyVcsComparePath#%<" .. M.display(s.root or s.path):gsub("%%", "%%%%")
	)
end

---@param constraints? { min_width: integer, min_height: integer, height: integer }
---@return integer width, boolean stacked, string? err
function M.layout(columns, manual, auto, content, constraints)
	constraints = constraints or { min_width = 1, min_height = 1, height = vim.o.lines - 4 }
	local minimum = math.max(1, constraints.min_width)
	local compact = math.max(minimum, manual)
	local can_stack = constraints.height >= 2 * math.max(1, constraints.min_height) + 3
	local can_columns = columns >= 3 * minimum + 2
	local stacked = (columns - compact - 2 < 90 or not can_columns) and can_stack
	if columns < 2 * minimum + 1 or (not stacked and not can_columns) then
		return minimum, stacked, "Not enough room for comparison panes"
	end
	local available = columns - (stacked and minimum + 1 or 2 * minimum + 2)
	compact = math.min(compact, available)
	local cap = math.min(math.floor(columns / 2), available)
	if not stacked then
		cap = math.min(cap, math.max(compact, columns - 92))
	end
	local width = auto and math.max(compact, math.min(cap, content + 1)) or compact
	return math.max(minimum, math.min(width, available)), stacked
end

M.highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("lazyvcs_compare_highlights", { clear = true }),
	callback = M.highlights,
})
return M
