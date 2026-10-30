-- Real buffers are borrowed, never scratch resources. A buffer created here may
-- be discarded only until the user modifies, lists, or displays it elsewhere.
local text = require("lazyvcs.compare_text")
local util = require("lazyvcs.util")
local M = {}
local records = {}
local attachments = {}
local pane_labels = {}
local installed = false

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
		for owner in pairs(record.jump_owners or {}) do
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
			local current = records[changed_buf]
			reread(current)
			vim.schedule(util.safe_callback(function()
				if current and records[changed_buf] == current then
					changed(current)
				end
			end))
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

---Whether a winbar value is a label Compare showed with the buffer.
function M.is_label(buf, winbar)
	local labels = pane_labels[buf]
	return labels ~= nil and labels[winbar] == true
end

---Clear a copied Compare label without changing a live diff's options.
function M.reset_label(win)
	if M.is_label(vim.api.nvim_win_get_buf(win), util.get_win_option(win, "winbar")) then
		util.set_win_option(win, "winbar", "")
	end
end

---Turn off what Compare set in a pane before the pane releases a real buffer
---or Compare closes, so the option record Neovim saves for the buffer carries
---no diff mode, scroll binding, or Compare label. :diffoff restores the
---options saved at :diffthis; folds stay as Neovim leaves them.
function M.reset_pane(win)
	util.unbind_window(win)
	util.set_win_option(win, "winbar", "")
end

local trials = 0

---Whether switching `win` to `buf` copies the options of a live pane that shows
---`buf`. Neovim copies a live window's options only into a window that has no
---option record of its own for the buffer. Tag the panes with a one-off token
---in 'foldignore', switch `win` with autocommands off and read the token, then
---switch back and untag; the window gets back the view and fold state of the
---buffer it left. Autocommands later in a real switch, such as a :loadview,
---cannot hide the answer. Returns nil when the trial cannot run.
function M.copies_pane(win, buf, panes)
	local tagged = {}
	for _, pane in ipairs(panes) do
		if vim.api.nvim_win_is_valid(pane) and vim.api.nvim_win_get_buf(pane) == buf then
			tagged[#tagged + 1] = { win = pane, value = util.get_win_option(pane, "foldignore") }
		end
	end
	if #tagged == 0 then
		-- A pane that released the buffer left a reset record behind.
		return false
	end
	trials = trials + 1
	local token = "\28lazyvcs" .. trials .. "\31"
	for _, pane in ipairs(tagged) do
		util.set_win_option_noautocmd(pane.win, "foldignore", pane.value .. token)
	end
	local old = vim.api.nvim_win_get_buf(win)
	local hidden = vim.bo[old].bufhidden
	-- Returning to a buffer applies 'foldlevelstart' even without autocommands.
	local foldlevelstart = vim.o.foldlevelstart
	vim.cmd("noautocmd set foldlevelstart=-1")
	local ok, copied = pcall(vim.api.nvim_win_call, win, function()
		-- Keep the buffer the window leaves, and its view, for the moment.
		local view = vim.fn.winsaveview()
		vim.cmd("noautocmd setlocal bufhidden=hide")
		vim.cmd("noautocmd keepalt keepjumps buffer " .. buf)
		local value = tostring(util.get_win_option(win, "foldignore"))
		local found = value:find(token, 1, true) ~= nil
		if found then
			-- Leave no token in the record the switch back saves.
			util.set_win_option_noautocmd(win, "foldignore", (value:gsub(vim.pesc(token), "")))
		end
		vim.cmd("noautocmd keepalt keepjumps buffer " .. old)
		vim.fn.winrestview(view)
		return found
	end)
	vim.cmd("noautocmd set foldlevelstart=" .. foldlevelstart)
	if vim.api.nvim_buf_is_valid(old) then
		vim.api.nvim_buf_call(old, function()
			vim.cmd("noautocmd setlocal bufhidden=" .. hidden)
		end)
	end
	for _, pane in ipairs(tagged) do
		if vim.api.nvim_win_is_valid(pane.win) then
			util.set_win_option_noautocmd(pane.win, "foldignore", pane.value)
		end
	end
	if not ok or vim.api.nvim_win_get_buf(win) ~= old then
		return nil
	end
	return copied
end

---Turn off pane state that an editor window received with a real buffer from
---a Compare edit action. `before` holds the window's diff and bindings before
---the switch. `copied` says whether its options came from a live pane: then
---diff mode goes and the bindings return to `before`. nil means unknown: turn
---off only what the switch turned on. false leaves the window's own diff.
function M.reset_editor(win, before, copied)
	if copied == nil then
		copied = util.get_win_option(win, "diff") and not before.diff
	end
	-- No trial token stays behind, in the window's local or global value.
	for _, scope in ipairs({ "local", "global" }) do
		local value = tostring(vim.api.nvim_get_option_value("foldignore", { win = win, scope = scope }))
		local stripped = value:gsub("\28lazyvcs%d+\31", "")
		if stripped ~= value then
			vim.api.nvim_win_call(win, function()
				local target = scope == "local" and "&l:foldignore" or "&g:foldignore"
				vim.api.nvim_cmd(
					{ cmd = "let", args = { target .. " = " .. vim.fn.string(stripped) }, mods = { noautocmd = true } },
					{}
				)
			end)
		end
	end
	if copied then
		util.diff_off(win)
		-- :diffoff restores the pane's bindings; the window keeps its own.
		util.set_win_options(win, { scrollbind = before.scrollbind, cursorbind = before.cursorbind })
	end
	M.reset_label(win)
end

function M.capture(record)
	if not valid(record) or record.deleted or record.unloading then
		return nil
	end
	return text.capture(record.buf, 1024 * 1024)
end

-- Match the real buffer's newline interpretation while decoding the base in
-- its own encoding. Snapshot-only previews keep their normalized documents.
function M.result(record, result, current)
	current = current or M.capture(record)
	if not current then
		return nil, "Working buffer is unavailable"
	end
	local disk = result.disk_result or result
	local base = disk.left_document
	if base and disk.left_bytes then
		local profile = assert(text.profile(record.buf))
		local encoding = base.encoding
		local key = encoding .. ":editable:" .. profile.fileformat
		if result.left_document and result.left_document.profile_key == key then
			base = result.left_document
		else
			base = assert(text.decode(disk.left_bytes, {
				fileencoding = encoding,
				fileformat = profile.fileformat,
				bomb = false,
				binary = false,
				key = key,
			}, 1024 * 1024))
		end
	end
	return vim.tbl_extend("force", result, {
		left = base and base.lines or result.left,
		left_document = base,
		right = current.lines,
		right_document = current,
		disk_result = disk,
		profile_key = (base and base.profile_key or "") .. "\0" .. current.profile_key,
	})
end

local function jump_targets(s)
	local targets = {}
	for _, win in ipairs({ s.leftwin, s.rightwin }) do
		if win and vim.api.nvim_win_is_valid(win) then
			for _, jump in ipairs(vim.api.nvim_win_call(win, vim.fn.getjumplist)[1]) do
				targets[jump.bufnr] = true
			end
		end
	end
	return targets
end

function M.trim_jumps(s, closing)
	local targets = not closing and jump_targets(s) or {}
	for buf, record in pairs(s.jump_buffers or {}) do
		if not targets[buf] then
			s.jump_buffers[buf] = nil
			M.release(s, record, true)
		end
	end
end

function M.release(s, record, release_jump)
	if not record then
		return
	end
	adopt(record)
	-- Expiring a jump entry must not release a pane that reacquired the buffer.
	if not release_jump then
		record.owners[s] = nil
	end
	-- Native jump history has at most 100 entries per pane. Keep private
	-- targets only while that history or a live pane needs them.
	record.jump_owners = record.jump_owners or {}
	if not release_jump and not s.closed and not record.retained and jump_targets(s)[record.buf] then
		s.jump_buffers = s.jump_buffers or {}
		s.jump_buffers[record.buf] = record
		record.jump_owners[s] = true
	else
		record.jump_owners[s] = nil
	end
	if next(record.owners) or next(record.jump_owners) then
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
