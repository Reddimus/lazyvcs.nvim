-- Real buffers are borrowed, never scratch resources. A buffer created here may
-- be discarded only until the user modifies, lists, or displays it elsewhere.
local text = require("lazyvcs.compare_text")
local util = require("lazyvcs.util")
local M = {}
local records = {}
local attachments = {}
local installed = false

local function valid(record)
	return record and vim.api.nvim_buf_is_valid(record.buf)
end

local function adopt(record)
	if not valid(record) or record.loading then
		return
	end
	if vim.bo[record.buf].modified then
		record.retained = true
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
				adopt(record)
				for owner, callback in pairs(record.owners) do
					if not owner.closed and owner.worktree == record then
						callback("saved", record)
					end
				end
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
