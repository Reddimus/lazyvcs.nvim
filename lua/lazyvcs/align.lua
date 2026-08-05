local util = require("lazyvcs.util")

-- Keep corresponding diff lines on the same screen row when the panes soft-wrap.
--
-- Neovim's diff mode aligns the two buffers in *buffer lines*: it inserts filler
-- rows so a change starts opposite its counterpart, and 'scrollbind' keeps the
-- toplines in step. With 'wrap' off that is enough, because one buffer line is
-- exactly one screen row on both sides.
--
-- With 'wrap' on -- which is what `followwrap` in 'diffopt' preserves -- it is
-- not. A line that occupies four screen rows on the left and one on the right
-- pushes everything below it out of alignment, and because nothing ever
-- reconciles the difference the error accumulates down the file. The panes agree
-- on the line and still render pages apart.
--
-- The fix is to pad the shorter side. Corresponding text is grouped into units
-- (one unchanged line pairs with one unchanged line; a changed block pairs with
-- its counterpart as a whole), each unit is measured in screen rows on both
-- sides, and the shorter side gets `virt_lines` rows appended so both units
-- occupy the same height. The unit after it therefore starts on the same row on
-- both sides.
--
-- `virt_lines` are extmarks: they add no text, so undo, marks, and the file on
-- disk are untouched, and the namespace is cleared when the session closes.

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

---Pair the two buffers into units of corresponding text.
---
---`hunks` come from `diff.compute_hunks`, i.e. Neovim's `indices` form: a count
---of 0 means the range is empty and `start` is the line the change sits *after*.
---Between hunks the two buffers hold identical text, so those lines pair one to
---one; a hunk itself pairs as a single block, because its two sides have no
---line-level correspondence at all.
---@param hunks table[]
---@param base_count integer
---@param current_count integer
---@return lazyvcs.align.Unit[]
function M.pair_units(hunks, base_count, current_count)
	local units = {}
	local b, c = 1, 1

	local function pair_unchanged(b_last, c_last)
		local length = math.min(b_last - b + 1, c_last - c + 1)
		for offset = 0, length - 1 do
			units[#units + 1] = {
				base = { b + offset, b + offset },
				current = { c + offset, c + offset },
			}
		end
		b = b + length
		c = c + length
	end

	for _, hunk in ipairs(hunks or {}) do
		-- Where the identical run before this hunk ends. With an empty side the
		-- anchor line itself is still unchanged text, so it belongs to the run.
		local b_stop = hunk.base_count > 0 and (hunk.base_start - 1) or hunk.base_start
		local c_stop = hunk.current_count > 0 and (hunk.current_start - 1) or hunk.current_start
		if b_stop >= b and c_stop >= c then
			pair_unchanged(b_stop, c_stop)
		end

		local base_range = hunk.base_count > 0 and { hunk.base_start, hunk.base_start + hunk.base_count - 1 } or nil
		local current_range = hunk.current_count > 0
				and { hunk.current_start, hunk.current_start + hunk.current_count - 1 }
			or nil
		if base_range or current_range then
			units[#units + 1] = { base = base_range, current = current_range }
		end

		b = base_range and (base_range[2] + 1) or b
		c = current_range and (current_range[2] + 1) or c
	end

	if b <= base_count and c <= current_count then
		pair_unchanged(base_count, current_count)
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
	if (session.opts.base_window.align_wrapped or "auto") ~= "auto" then
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
		return false
	end

	-- Nothing to reconcile when neither pane wraps: one buffer line is one screen
	-- row on both sides and Neovim's own filler already does the whole job.
	if not (vim.wo[base_win].wrap or vim.wo[edit_win].wrap) then
		M.clear(session)
		return false
	end

	local base_first, base_last = visible_range(base_win, base_buf, 10)
	local edit_first, edit_last = visible_range(edit_win, edit_buf, 10)

	local units =
		M.pair_units(session.hunks or {}, vim.api.nvim_buf_line_count(base_buf), vim.api.nvim_buf_line_count(edit_buf))

	-- Build the whole plan before touching the buffers. Measuring is read-only,
	-- so the heights below are all taken against one consistent screen state.
	local plan = { [base_buf] = {}, [edit_buf] = {} }
	for _, unit in ipairs(units) do
		if overlaps(unit.base, base_first, base_last) or overlaps(unit.current, edit_first, edit_last) then
			-- A one-sided unit is a pure insertion or deletion; Neovim's own diff
			-- filler already reserves the opposite space, so padding it too would
			-- double-count the gap.
			local base_range, current_range = unit.base, unit.current
			if base_range and current_range then
				local base_height = range_rows(base_win, base_range[1], base_range[2])
				local edit_height = range_rows(edit_win, current_range[1], current_range[2])
				if base_height < edit_height then
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
	if (session.opts.base_window.align_wrapped or "auto") ~= "auto" then
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
