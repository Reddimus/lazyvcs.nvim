-- Real buffers are borrowed, never scratch resources. A buffer created here may
-- be discarded only until the user modifies, lists, or displays it elsewhere.
local text = require("lazyvcs.compare_text")
local util = require("lazyvcs.util")
local M = {}
local records = {}
local attachments = {}
local pane_labels = {}
local installed = false
-- Compare panes carry this 'winhighlight' entry, a group mapped to itself with
-- no visible effect. Neovim copies it with the pane's other window options
-- (diff, bindings, folds, winbar), so a window that inherits pane options also
-- inherits the marker, whatever path copied them. A window's own options,
-- including a deliberate :diffthis, never carry it. A plugin that replaces
-- 'winhighlight' wholesale before WinNew or BufWinEnter reaches Compare, or a
-- window created with :noautocmd, keeps the copy unnoticed.
local marker = "LazyVcsComparePane:LazyVcsComparePane"

local function highlight_entries(win)
	local entries = {}
	for entry in tostring(util.get_win_option(win, "winhighlight")):gmatch("[^,]+") do
		entries[#entries + 1] = entry
	end
	return entries
end

local function marked(win)
	return vim.tbl_contains(highlight_entries(win), marker)
end

local function unmark(win)
	local kept = vim.tbl_filter(function(entry)
		return entry ~= marker
	end, highlight_entries(win))
	util.set_win_option(win, "winhighlight", table.concat(kept, ","))
end

-- :diffoff restores the options saved before diff mode, such as an ftplugin
-- fold method.
local function reset(win, clear_winbar)
	util.diff_off(win)
	util.set_win_options(win, { scrollbind = false, cursorbind = false })
	if clear_winbar then
		util.set_win_option(win, "winbar", "")
	end
	if util.get_win_option(win, "foldmethod") == "diff" then
		for _, name in ipairs({ "foldmethod", "foldcolumn", "foldenable" }) do
			util.set_win_option(win, name, vim.api.nvim_get_option_value(name, { win = win, scope = "global" }))
		end
	end
end

local function valid(record)
	return record and vim.api.nvim_buf_is_valid(record.buf)
end

local function adopt(record)
	if not valid(record) or record.loading then
		return
	end
	-- A batched edit can save or undo before change autocmds observe 'modified'.
	-- Any change since loading belongs to the user, including its undo history.
	if
		vim.bo[record.buf].modified
		or (record.tick and not record.rereading and vim.api.nvim_buf_get_changedtick(record.buf) ~= record.tick)
	then
		-- List the buffer once for that change; the user may unlist it later.
		record.retained, record.tick = true, nil
		vim.bo[record.buf].buflisted = true
	end
	if vim.bo[record.buf].buflisted then
		record.retained = true
	end
	for _, win in ipairs(vim.fn.win_findbuf(record.buf)) do
		local owned = false
		for owner in pairs(record.owners) do
			owned = owned or (not owner.closed and win == owner.rightwin)
		end
		if not owned then
			record.retained = true
		end
	end
end

local function changed(record)
	if not valid(record) or record.loading or record.deleted or not vim.api.nvim_buf_is_loaded(record.buf) then
		return
	end
	local profile = text.profile(record.buf)
	local bo = vim.bo[record.buf]
	local signature = table.concat({
		vim.api.nvim_buf_get_changedtick(record.buf),
		profile and profile.key or "",
		tostring(bo.endofline),
		tostring(bo.fixendofline),
		tostring(bo.modified),
	}, ":")
	adopt(record)
	if record.signature == signature then
		return
	end
	record.signature = signature
	record.version = (record.version or 0) + 1
	for owner, callback in pairs(record.owners) do
		if not owner.closed and owner.worktree == record then
			callback("changed", record)
		end
	end
end

-- Take the change baseline once an in-place reread has finished.
local function reread(record)
	if record and record.rereading then
		record.rereading = nil
		if record.tick and not vim.api.nvim_get_option_value("modified", { buf = record.buf }) then
			record.tick = vim.api.nvim_buf_get_changedtick(record.buf)
		end
	end
end

local function attach(record)
	local buf = record.buf
	if attachments[buf] then
		return
	end
	attachments[buf] = vim.api.nvim_buf_attach(buf, false, {
		on_lines = function(_, changed_buf)
			if not records[changed_buf] then
				attachments[changed_buf] = nil
				return true
			end
			vim.schedule(util.safe_callback(function()
				local current = records[changed_buf]
				if current then
					changed(current)
				end
			end))
		end,
		on_reload = function(_, changed_buf)
			reread(records[changed_buf])
		end,
		on_detach = function(_, changed_buf)
			attachments[changed_buf] = nil
		end,
	})
end

local function settle(record)
	if record.settling then
		return
	end
	record.settling = true
	vim.schedule(util.safe_callback(function()
		record.settling = nil
		if records[record.buf] ~= record or record.releasing then
			return
		end
		local loaded = valid(record) and vim.api.nvim_buf_is_loaded(record.buf)
		local same = loaded and util.canonical_path(util.buf_path(record.buf)) == util.canonical_path(record.path)
		local reloaded = record.unloading and same
		record.unloading = nil
		if same then
			record.deleted = nil
			-- Rereading the file is not an edit; later changes are. Without a
			-- synchronous reload tick, count the reread as an edit.
			if reloaded and record.tick and record.reload_tick and not vim.bo[record.buf].modified then
				record.tick = record.reload_tick
			end
			record.rereading, record.reload_tick = nil, nil
			adopt(record)
			attach(record)
		else
			record.deleted = true
			record.retained = record.retained or loaded
			records[record.buf] = nil
		end
		for owner, callback in pairs(record.owners) do
			if not owner.closed and owner.worktree == record then
				if record.deleted then
					callback("deleted", record)
				elseif reloaded then
					callback("reloaded", record)
				end
			end
		end
	end))
end

local function setup()
	if installed then
		return
	end
	installed = true
	local group = vim.api.nvim_create_augroup("lazyvcs_compare_worktree", { clear = true })
	vim.api.nvim_create_autocmd({ "BufModifiedSet", "TextChanged", "TextChangedI", "BufWinEnter" }, {
		group = group,
		callback = util.safe_callback(function(args)
			local record = records[args.buf]
			if record then
				changed(record)
			end
		end),
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = {
			"buflisted",
			"fileencoding",
			"fileformat",
			"bomb",
			"binary",
			"endofline",
			"fixendofline",
			"modified",
		},
		callback = util.safe_callback(function()
			local record = records[vim.api.nvim_get_current_buf()]
			if record then
				changed(record)
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		callback = util.safe_callback(function(args)
			local record = records[args.buf]
			if record then
				-- Saving is editing, even when the same command made the change.
				record.retained = true
				vim.bo[record.buf].buflisted = true
				adopt(record)
				for owner, callback in pairs(record.owners) do
					if not owner.closed and owner.worktree == record then
						callback("saved", record)
					end
				end
			end
		end),
	})
	-- A window without its own option record for a buffer copies another
	-- window's options for it, and a new window copies its parent's: :split,
	-- :tab split and nvim_open_win() on the pane's buffer fire WinNew, with the
	-- new window current, but no BufWinEnter. Remove Compare pane state that an
	-- ordinary window copied; the marker travels with it.
	vim.api.nvim_create_autocmd({ "WinNew", "BufWinEnter" }, {
		group = group,
		callback = util.safe_callback(function()
			local win = vim.api.nvim_get_current_win()
			if not vim.w[win].lazyvcs_compare and marked(win) then
				local labels = pane_labels[vim.api.nvim_win_get_buf(win)]
				-- Keep a winbar that a statusline plugin set after the copy.
				reset(win, labels and labels[util.get_win_option(win, "winbar")])
				unmark(win)
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = util.safe_callback(function(args)
			pane_labels[args.buf] = nil
		end),
	})
	-- :checktime and autoread reread a file in place without unloading it. The
	-- change tick moves after BufReadPost but before on_reload and
	-- FileChangedShellPost, which run before any later command. Take the new
	-- baseline there, so an edit that follows in the same macro still counts.
	vim.api.nvim_create_autocmd("BufReadPre", {
		group = group,
		callback = util.safe_callback(function(args)
			local record = records[args.buf]
			if record and not record.loading and not record.unloading and not record.releasing then
				-- An edit earlier in the same batch has not reached Compare yet.
				-- Keep it, and its undo history, before the reread moves the tick.
				adopt(record)
				record.rereading = true
			end
		end),
	})
	vim.api.nvim_create_autocmd("FileChangedShellPost", {
		group = group,
		callback = util.safe_callback(function(args)
			reread(records[args.buf])
		end),
	})
	-- :edit unloads and reads the file again; BufEnter follows with the final
	-- change tick before any later command.
	vim.api.nvim_create_autocmd("BufEnter", {
		group = group,
		callback = util.safe_callback(function(args)
			local record = records[args.buf]
			if record and record.unloading and vim.api.nvim_buf_is_loaded(args.buf) then
				record.reload_tick = vim.api.nvim_buf_get_changedtick(args.buf)
			end
		end),
	})
	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout", "BufUnload", "BufFilePost", "BufReadPost" }, {
		group = group,
		callback = util.safe_callback(function(args)
			local record = records[args.buf]
			if record and not record.releasing then
				if args.event == "BufUnload" or args.event == "BufWipeout" then
					record.unloading, record.deleted = true, true
					record.version = (record.version or 0) + 1
					for owner, callback in pairs(record.owners) do
						if not owner.closed and owner.worktree == record then
							callback("unloading", record)
						end
					end
				elseif args.event == "BufFilePost" then
					record.retained = true
				end
				settle(record)
			end
		end),
	})
end

function M.acquire(s, item, result, callback)
	if not s.editable or s.worktree_deleted == item.relpath then
		return nil
	end
	if
		result.right_source
		or item.status == "D"
		or item.property_only
		or item.kind == "dir"
		or item.kind_before == "dir"
		or item.kind_after == "dir"
		or not (result.left_kind == "regular" or result.left_kind == "missing")
	then
		return nil
	end
	local path = util.normalize_literal_path(s.root .. "/" .. item.relpath)
	local stat = vim.uv.fs_lstat(path)
	if not stat or stat.type ~= "file" or stat.size > 1024 * 1024 then
		return nil
	end
	setup()
	local before = vim.fn.bufnr("$")
	local buf = vim.fn.bufadd(path)
	if buf <= 0 then
		return nil
	end
	local record = records[buf]
	if not record then
		record = { buf = buf, path = path, retained = buf <= before, owners = {}, hidden = vim.bo[buf].bufhidden }
		records[buf] = record
	end
	-- Keep borrowed buffers loaded across pane changes, even with 'nohidden'.
	-- Explicit :bdelete still unloads them and can be distinguished from :close.
	if vim.bo[buf].bufhidden ~= "hide" then
		vim.bo[buf].bufhidden = "hide"
	end
	-- Register the intended destination before filetype/autocmd code can display it.
	record.owners[s] = callback
	record.loading = true
	local ok, err = pcall(vim.fn.bufload, buf)
	record.loading = nil
	if not ok then
		M.release(s, record)
		return nil, tostring(err)
	end
	if not record.retained and not record.tick then
		record.tick = vim.api.nvim_buf_get_changedtick(buf)
	end
	local current = text.capture(buf, 1024 * 1024)
	local loaded_stat = vim.uv.fs_lstat(path)
	if
		not current
		or util.canonical_path(util.buf_path(buf)) ~= util.canonical_path(path)
		or not loaded_stat
		or loaded_stat.type ~= "file"
		or loaded_stat.size > 1024 * 1024
		or vim.bo[buf].buftype ~= ""
		or not vim.bo[buf].modifiable
		or vim.bo[buf].readonly
	then
		record.owners[s] = nil
		M.release(s, record)
		return nil
	end
	adopt(record)
	attach(record)
	return record, current
end

---Record a winbar label that Compare showed with a borrowed buffer.
function M.mark_pane(buf, winbar)
	setup()
	local labels = pane_labels[buf] or {}
	labels[winbar] = true
	pane_labels[buf] = labels
end

---Mark a Compare pane's window options before Compare applies pane state.
function M.mark_window(win)
	setup()
	if not marked(win) then
		local entries = highlight_entries(win)
		entries[#entries + 1] = marker
		util.set_win_option(win, "winhighlight", table.concat(entries, ","))
	end
end

---Reset a Compare pane before it releases a real buffer, so the option record
---Neovim saves for that buffer holds no Compare state.
function M.reset_pane(win)
	reset(win, true)
	unmark(win)
end

function M.capture(record)
	if not valid(record) or record.deleted or record.unloading then
		return nil
	end
	return text.capture(record.buf, 1024 * 1024)
end

function M.release(s, record)
	if not record then
		return
	end
	adopt(record)
	record.owners[s] = nil
	if next(record.owners) then
		return
	end
	if records[record.buf] == record then
		records[record.buf] = nil
	end
	if valid(record) and vim.bo[record.buf].bufhidden == "hide" then
		vim.bo[record.buf].bufhidden = record.hidden
	end
	if
		valid(record)
		and not record.retained
		and #vim.fn.win_findbuf(record.buf) == 0
		and not vim.bo[record.buf].modified
	then
		record.releasing = true
		vim.api.nvim_buf_delete(record.buf, {})
	end
end

return M
