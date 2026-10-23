-- Real buffers are borrowed, never scratch resources. A buffer created here may
-- be discarded only until the user modifies, lists, or displays it elsewhere.
local text = require("lazyvcs.compare_text")
local util = require("lazyvcs.util")
local M = {}
local records = {}
local attachments = {}
local pane_labels = {}
-- Buffer -> the window state a pane got for it from Neovim, before Compare
-- changed it: the user's folds and fold options for that buffer.
local states = {}
local fold_ns = vim.api.nvim_create_namespace("lazyvcs_compare_user_folds")
local installed = false
-- compare_marker.lua tells windows that copied pane state from windows whose
-- options are their own.
local marker = require("lazyvcs.compare_marker")

-- Without a saved state, remove what Compare sets. :diffoff restores the
-- options saved before diff mode, such as an ftplugin fold method. Under
-- 'foldmethod' manual it also leaves the diff folds behind as disabled manual
-- folds, which Neovim then saves and copies with the window options.
local function reset(win, clear_winbar)
	util.diff_off(win)
	util.set_win_options(win, { scrollbind = false, cursorbind = false })
	if util.get_win_option(win, "foldmethod") == "manual" then
		vim.api.nvim_win_call(win, function()
			vim.cmd("silent! normal! zE")
		end)
		util.set_win_option(
			win,
			"foldenable",
			vim.api.nvim_get_option_value("foldenable", { win = win, scope = "global" })
		)
	end
	if clear_winbar then
		util.set_win_option(win, "winbar", "")
	end
	if util.get_win_option(win, "foldmethod") == "diff" then
		for _, name in ipairs({ "foldmethod", "foldcolumn", "foldenable" }) do
			util.set_win_option(win, name, vim.api.nvim_get_option_value(name, { win = win, scope = "global" }))
		end
	end
end

local function quiet_global(name, value)
	vim.api.nvim_cmd(
		{ cmd = "let", args = { "&" .. name .. " = " .. vim.fn.string(value) }, mods = { noautocmd = true } },
		{}
	)
end

-- :diffthis replaces a window's manual folds and closes the folds the user
-- opened; :diffoff restores the fold options saved at :diffthis but not those
-- folds. Neovim's own :mkview with 'viewoptions' "folds" writes them as
-- commands. Keep the fold commands, with their line numbers tracked by extmarks
-- so edits made in Compare move them. The other fold options are the user's,
-- including changes made in the pane, and stay as they are.
local function capture(win)
	local buf = vim.api.nvim_win_get_buf(win)
	local file = vim.fn.tempname()
	local viewoptions = vim.o.viewoptions
	quiet_global("viewoptions", "folds")
	local ok = pcall(vim.api.nvim_win_call, win, function()
		vim.cmd("silent noautocmd mkview! " .. vim.fn.fnameescape(file))
	end)
	quiet_global("viewoptions", viewoptions)
	local lines = ok and vim.fn.filereadable(file) == 1 and vim.fn.readfile(file) or {}
	vim.fn.delete(file)
	local count = vim.api.nvim_buf_line_count(buf)
	local function mark(line)
		line = tonumber(line)
		if line and line >= 1 and line <= count then
			return vim.api.nvim_buf_set_extmark(buf, fold_ns, line - 1, 0, {})
		end
	end
	local steps, inside = {}, false
	for _, line in ipairs(lines) do
		if line:match("^let &g:so = s:so_save") then
			break
		end
		inside = inside or line:match("^setlocal ") ~= nil
		local command = line:gsub("^sil! ", "")
		if inside and not command:match("^setlocal ") then
			local first, last = command:match("^(%d+),(%d+)fold$")
			if first then
				steps[#steps + 1] = { fold = { mark(first), mark(last) } }
			elseif command:match("^%d+$") then
				steps[#steps + 1] = { line = mark(command) }
			elseif command == "let &fdl = &fdl" then
				-- Recompute folds without copying the level to the window's global value.
				steps[#steps + 1] = { command = "let &l:fdl = &l:fdl" }
			else
				steps[#steps + 1] = { command = command }
			end
		end
	end
	local options = util.capture_win_options(win, { "foldmethod", "foldenable", "winfixbuf", "winbar" })
	return { buf = buf, steps = steps, options = options }
end

local function drop_state(buf)
	if states[buf] then
		states[buf] = nil
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_clear_namespace(buf, fold_ns, 0, -1)
		end
	end
end

-- Give the window the folds a pane got for its buffer, and undo what Compare
-- set. `winbar` restores the winbar too; a statusline plugin may already have
-- replaced a copied label.
local function restore(win, state, winbar)
	util.diff_off(win)
	local buf = state.buf
	local manual = state.options.foldmethod == "manual" and util.get_win_option(win, "foldmethod") == "manual"
	local function row(id)
		local position = id and vim.api.nvim_buf_get_extmark_by_id(buf, fold_ns, id, {})
		return position and position[1] and position[1] + 1
	end
	vim.api.nvim_win_call(win, function()
		local view = vim.fn.winsaveview()
		for _, step in ipairs(state.steps) do
			if step.command then
				-- Without manual folds, only reopen the folds the user had open.
				if manual or not step.command:match("zE$") then
					pcall(vim.api.nvim_command, "noautocmd silent! " .. step.command)
				end
			elseif step.fold then
				local first, last = row(step.fold[1]), row(step.fold[2])
				if manual and first and last and first <= last then
					pcall(vim.api.nvim_command, string.format("noautocmd silent! %d,%dfold", first, last))
				end
			elseif row(step.line) then
				pcall(vim.api.nvim_win_set_cursor, win, { row(step.line), 0 })
			end
		end
		vim.fn.winrestview(view)
	end)
	-- :diffoff turns 'foldenable' off under manual folding.
	if manual then
		util.set_win_option(win, "foldenable", state.options.foldenable)
	end
	util.set_win_option(win, "winfixbuf", state.options.winfixbuf)
	if winbar then
		util.set_win_option(win, "winbar", state.options.winbar)
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
	-- Unloading also moves the change tick, and leaves no text or history.
	if
		vim.bo[record.buf].modified
		or (
			record.tick
			and not record.rereading
			and vim.api.nvim_buf_is_loaded(record.buf)
			and vim.api.nvim_buf_get_changedtick(record.buf) ~= record.tick
		)
	then
		-- List the buffer once for that change; the user may unlist it later.
		record.retained, record.tick = true, nil
		vim.bo[record.buf].buflisted = true
	end
	if vim.bo[record.buf].buflisted then
		record.retained = true
	end
	for _, win in ipairs(vim.fn.win_findbuf(record.buf)) do
		-- Neovim borrows an autocmd window to reread a buffer shown in no window
		-- of the current tab; that is not the user displaying it.
		local owned = vim.fn.win_gettype(win) == "autocmd"
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
			drop_state(record.buf)
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
	-- A range write (:1,1write!) and an append (:write >> %) fire FileWritePost
	-- and FileAppendPost instead of BufWritePost.
	vim.api.nvim_create_autocmd({ "BufWritePost", "FileWritePost", "FileAppendPost" }, {
		group = group,
		callback = util.safe_callback(function(args)
			local record = records[args.buf]
			if record then
				-- Writing the file is editing it, even when the same command made the
				-- change or wrote only part of the buffer. Writing a copy elsewhere is
				-- not; adopt() still catches an edit made by the same command.
				if util.canonical_path(vim.fn.fnamemodify(args.file, ":p")) == util.canonical_path(record.path) then
					record.retained = true
					vim.bo[record.buf].buflisted = true
				end
				adopt(record)
				for owner, callback in pairs(record.owners) do
					if not owner.closed and owner.worktree == record then
						callback("saved", record)
					end
				end
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = util.safe_callback(function(args)
			pane_labels[args.buf] = nil
			states[args.buf] = nil
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

---Keep the state a pane got for the borrowed buffer it now shows, before
---Compare changes it. Call right after the pane switches to the buffer.
function M.enter_pane(win)
	local buf = vim.api.nvim_win_get_buf(win)
	if records[buf] and not states[buf] and not marker.active(win) then
		marker.unmark(win)
		states[buf] = capture(win)
	end
	-- Compare switches pane buffers without BufWinEnter, which takes the
	-- buffer's change baseline once it is displayed.
	if records[buf] then
		changed(records[buf])
	end
end

---Mark a Compare pane's window options before Compare applies pane state.
function M.mark_window(win)
	setup()
	marker.mark(win)
end

---Before a Compare pane stops showing a real buffer, give it back the state it
---had for that buffer, so the option record Neovim saves holds no Compare
---state. A pane that shows another buffer, such as a picker preview, keeps
---that buffer's state.
function M.reset_pane(win)
	if marker.active(win) then
		local buf = vim.api.nvim_win_get_buf(win)
		if states[buf] then
			restore(win, states[buf], true)
		elseif records[buf] then
			reset(win, true)
		end
	end
	marker.unmark(win)
	marker.deactivate(win)
end

---Remove Compare pane state from a window that copied it, restoring the state
---a pane got for the buffer when Compare still has it.
function M.clean_copy(win)
	local buf = vim.api.nvim_win_get_buf(win)
	local labels = pane_labels[buf]
	-- Keep a winbar that a statusline plugin set after the copy.
	local label = labels and labels[util.get_win_option(win, "winbar")] or false
	if states[buf] then
		restore(win, states[buf], label)
	else
		reset(win, label)
	end
	marker.unmark(win)
	return true
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
		drop_state(record.buf)
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
