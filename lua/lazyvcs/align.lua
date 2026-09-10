local util = require("lazyvcs.util")

-- Native diff filler aligns buffer lines. Optional virtual-line padding also
-- aligns their wrapped screen heights without changing either buffer's text.

local M = {}

local ns = vim.api.nvim_create_namespace("lazyvcs_align")

---Screen rows occupied by one buffer line, excluding anything virtual above it.
---`start_vcol` is what excludes diff filler and our own padding
---(:h nvim_win_text_height) -- without it a measurement includes the padding
---from the previous pass and every run would pad on top of the last one.
local function line_rows(winid, lnum)
	local ok, res = pcall(vim.api.nvim_win_text_height, winid, {
		start_row = lnum - 1,
		end_row = lnum - 1,
		start_vcol = 0,
	})
	if not ok or type(res) ~= "table" then
		return 1
	end
	return math.max(res.all or 1, 1)
end

local function range_rows(winid, first, last)
	local total = 0
	for lnum = first, last do
		total = total + line_rows(winid, lnum)
	end
	return total
end

---An inclusive 1-based line range, `{ first, last }`.
---@alias lazyvcs.align.Range integer[]

---Corresponding text on the two sides. Either side is absent for a pure
---insertion or deletion.
---@class lazyvcs.align.Unit
---@field base lazyvcs.align.Range|nil
---@field current lazyvcs.align.Range|nil

---Pair unchanged lines and changed blocks intersecting either viewport.
---Empty hunk sides anchor after their start line. Two binary searches and
---bounded walks avoid visiting hunks between distant viewports.
---@param hunks table[]
---@param base_count integer
---@param current_count integer
---@param base_stop integer|nil last base line worth pairing
---@param current_stop integer|nil last current line worth pairing
---@return lazyvcs.align.Unit[]
function M.pair_units(hunks, base_count, current_count, base_stop, current_stop, base_first, current_first)
	hunks = hunks or {}
	local function walk(side, first, stop)
		local units = {}
		local start_key, count_key = side .. "_start", side .. "_count"
		local low, high = 1, #hunks + 1
		while low < high do
			local middle = math.floor((low + high) / 2)
			local hunk = hunks[middle]
			if hunk[start_key] + math.max(hunk[count_key] - 1, 0) < first then
				low = middle + 1
			else
				high = middle
			end
		end
		local b, c = 1, 1
		if low > 1 then
			local previous = hunks[low - 1]
			b = previous.base_start + math.max(previous.base_count, 1)
			c = previous.current_start + math.max(previous.current_count, 1)
		end
		local function position()
			return side == "base" and b or c
		end
		local function unchanged(b_last, c_last)
			local length = math.max(0, math.min(b_last - b + 1, c_last - c + 1))
			local anchor = position()
			for offset = math.max(0, first - anchor), math.min(length - 1, stop - anchor) do
				units[#units + 1] = {
					position = b + c + 2 * offset,
					unit = { base = { b + offset, b + offset }, current = { c + offset, c + offset } },
				}
			end
			b, c = b + length, c + length
		end
		for index = low, #hunks do
			if position() > stop then
				break
			end
			local hunk = hunks[index]
			unchanged(
				hunk.base_start - (hunk.base_count > 0 and 1 or 0),
				hunk.current_start - (hunk.current_count > 0 and 1 or 0)
			)
			local count, start = hunk[count_key], hunk[start_key]
			if count > 0 and start <= stop and start + count - 1 >= first then
				units[#units + 1] = {
					position = b + c,
					unit = {
						base = hunk.base_count > 0 and { hunk.base_start, hunk.base_start + hunk.base_count - 1 }
							or nil,
						current = hunk.current_count > 0
								and { hunk.current_start, hunk.current_start + hunk.current_count - 1 }
							or nil,
					},
				}
			end
			b = hunk.base_start + math.max(hunk.base_count, 1)
			c = hunk.current_start + math.max(hunk.current_count, 1)
		end
		unchanged(base_count, current_count)
		return units
	end

	-- Walk each viewport separately so distant panes never scan the intervening hunks.
	local left = walk("base", base_first or 1, base_stop or base_count)
	local right = walk("current", current_first or 1, current_stop or current_count)
	local units, i, j = {}, 1, 1
	while i <= #left or j <= #right do
		local l, r = left[i], right[j]
		if l and (not r or l.position <= r.position) then
			units[#units + 1] = l.unit
			i = i + 1
			if r and l.position == r.position then
				j = j + 1
			end
		else
			units[#units + 1] = r.unit
			j = j + 1
		end
	end
	return units
end

local function blank_rows(count)
	local rows = {}
	for _ = 1, count do
		rows[#rows + 1] = { { "", "NonText" } }
	end
	return rows
end

---Lines currently on screen, widened by a margin so a scroll of a few rows does
---not immediately fall off the computed range.
local function visible_range(winid, bufnr, margin)
	local first = vim.api.nvim_win_call(winid, function()
		return vim.fn.line("w0")
	end)
	local last = vim.api.nvim_win_call(winid, function()
		return vim.fn.line("w$")
	end)
	local count = vim.api.nvim_buf_line_count(bufnr)
	return math.max(first - margin, 1), math.min(last + margin, count)
end

local function overlaps(range, first, last)
	return range and range[1] <= last and range[2] >= first
end

---@return boolean applied
function M.apply(session)
	if not session or session.closing then
		return false
	end
	if (session.opts.base_window.align_wrapped or "off") ~= "auto" then
		return false
	end

	local base_win, edit_win = session.base_win, session.editable_win
	local base_buf, edit_buf = session.base_bufnr, session.editable_bufnr
	if not (util.win_is_valid(base_win) and util.win_is_valid(edit_win)) then
		return false
	end
	if not (util.buf_is_valid(base_buf) and util.buf_is_valid(edit_buf)) then
		return false
	end
	if vim.api.nvim_win_get_tabpage(base_win) ~= vim.api.nvim_win_get_tabpage(edit_win) then
		-- The panes have been split across tabs (`<C-w>T`), so the padding has no
		-- partner to line up with. Clear it rather than stranding it.
		M.clear(session)
		return false
	end

	-- Nothing to reconcile when neither pane wraps: one buffer line is one screen
	-- row on both sides and Neovim's own filler already does the whole job.
	if not (vim.wo[base_win].wrap or vim.wo[edit_win].wrap) then
		M.clear(session)
		return false
	end

	-- Extmarks are buffer-scoped, not window-scoped, so padding the editable
	-- buffer shows up in every other window displaying that file -- blank rows
	-- injected into the user's ordinary view of their own file, in another split
	-- or tab, for as long as the session lives. Alignment is cosmetic; showing
	-- the file twice is not, so the file wins.
	if #vim.fn.win_findbuf(edit_buf) > 1 then
		M.clear(session)
		return false
	end

	local base_first, base_last = visible_range(base_win, base_buf, 10)
	local edit_first, edit_last = visible_range(edit_win, edit_buf, 10)

	local units = M.pair_units(
		session.hunks or {},
		vim.api.nvim_buf_line_count(base_buf),
		vim.api.nvim_buf_line_count(edit_buf),
		base_last,
		edit_last,
		base_first,
		edit_first
	)

	-- Build the whole plan before touching the buffers. Measuring is read-only,
	-- so the heights below are all taken against one consistent screen state.
	local plan = { [base_buf] = {}, [edit_buf] = {} }
	for _, unit in ipairs(units) do
		if overlaps(unit.base, base_first, base_last) or overlaps(unit.current, edit_first, edit_last) then
			-- A one-sided unit is a pure insertion or deletion; Neovim's own diff
			-- filler already reserves the opposite space, so padding it too would
			-- double-count the gap.
			local base_range, current_range = unit.base, unit.current
			if
				base_range
				and current_range
				and base_range[2] - base_range[1] < 1000
				and current_range[2] - current_range[1] < 1000
			then
				local base_height = range_rows(base_win, base_range[1], base_range[2])
				local edit_height = range_rows(edit_win, current_range[1], current_range[2])
				if math.abs(base_height - edit_height) > 1000 then
					-- Keep native diff filler for unusually large wrapped blocks.
				elseif base_height < edit_height then
					plan[base_buf][base_range[2]] = edit_height - base_height
				elseif edit_height < base_height then
					plan[edit_buf][current_range[2]] = base_height - edit_height
				end
			end
		end
	end

	-- Only rewrite the extmarks when the plan actually differs. Re-applying an
	-- identical plan on every scroll event would make `apply` always report a
	-- change, and the caller re-syncs on change -- which would loop forever.
	if vim.deep_equal(plan, session.align_plan) then
		return false
	end
	session.align_plan = plan

	for buf, rows in pairs(plan) do
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		for lnum, deficit in pairs(rows) do
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, 0, {
				virt_lines = blank_rows(deficit),
				virt_lines_above = false,
				right_gravity = false,
			})
		end
	end

	return true
end

---Coalesce to one pass per event-loop turn. Scroll and edit events arrive in
---bursts, and the whole point is that the result is idempotent, so running once
---after the burst is both cheaper and identical.
function M.schedule(session)
	if not session or session.closing then
		return
	end
	if (session.opts.base_window.align_wrapped or "off") ~= "auto" then
		return
	end
	if session.align_pending then
		return
	end

	session.align_pending = true
	vim.schedule(function()
		session.align_pending = false
		local ok, changed = pcall(M.apply, session)
		if not ok then
			-- Alignment is cosmetic. An error here must never escape into an
			-- autocmd callback, where it would block interactive Neovim on the
			-- hit-enter prompt over a purely visual concern.
			vim.notify_once("lazyvcs: diff alignment failed: " .. tostring(changed), vim.log.levels.DEBUG)
			return
		end
		if changed then
			-- Padding changes each pane's height, so the positions `:syncbind`
			-- computed a moment ago are now stale. Re-sync against the new
			-- geometry; `apply` is idempotent, so the pass this triggers reports
			-- no change and the sequence terminates.
			local layout = require("lazyvcs.layout")
			local focused = vim.api.nvim_get_current_win()
			local source = (focused == session.base_win) and session.base_win or session.editable_win
			pcall(layout.sync_scroll, session, source)
		end
	end)
end

---True when alignment is padding this session right now, i.e. it is enabled, the
---panes wrap, and the layout is one it can act on. Callers use this to decide
---whether Neovim's own binding has already produced the correct result.
function M.is_active(session)
	if not session or session.closing then
		return false
	end
	if (session.opts.base_window.align_wrapped or "off") ~= "auto" then
		return false
	end
	if not (util.win_is_valid(session.base_win) and util.win_is_valid(session.editable_win)) then
		return false
	end
	return vim.wo[session.base_win].wrap or vim.wo[session.editable_win].wrap
end

function M.clear(session)
	if not session then
		return
	end
	-- Drop the plan too, or a session reopened on the same table would compare
	-- equal to the stale plan and skip re-applying padding it no longer has.
	session.align_plan = nil
	for _, bufnr in ipairs({ session.base_bufnr, session.editable_bufnr }) do
		if bufnr and util.buf_is_valid(bufnr) then
			pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
		end
	end
end

function M.namespace()
	return ns
end

return M
