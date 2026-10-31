local util = require("lazyvcs.util")
local M = {}
local records = {}
local group, donor
local keys = { "wrap", "foldenable", "scrollbind", "cursorbind", "conceallevel" }

local function protect(callback)
	return function(...)
		local ok, err = pcall(callback, ...)
		if not ok then
			util.notify("Blame options failed: " .. tostring(err):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
		end
	end
end

local function remove(record)
	local windows = records[record.win]
	if windows and windows[record.buf] == record then
		windows[record.buf] = nil
		if not next(windows) then
			records[record.win] = nil
		end
	end
	record.lease.records[record] = nil
	if not next(records) and group then
		pcall(vim.api.nvim_del_augroup_by_id, group)
		group, donor = nil, nil
	end
end

local function restore(record)
	if not util.win_is_valid(record.win) or not util.buf_is_valid(record.buf) then
		remove(record)
		return
	end
	if not records[record.win] or records[record.win][record.buf] ~= record then
		return
	end
	if vim.api.nvim_win_get_buf(record.win) ~= record.buf then
		return
	end
	local current = util.capture_win_options(record.win, keys)
	local values = {}
	for name, value in pairs(record.installed) do
		if current[name] == value then
			values[name] = record.baseline[name]
		end
	end
	util.set_win_options(record.win, values)
	remove(record)
end

local function register(lease, win, baseline, installed)
	local record = { lease = lease, win = win, buf = lease.buf, baseline = baseline, installed = installed }
	records[win] = records[win] or {}
	records[win][lease.buf] = record
	lease.records[record] = true
	return record
end

local function observe()
	if group then
		return
	end
	group = vim.api.nvim_create_augroup("lazyvcs_blame_source_options", { clear = true })
	vim.api.nvim_create_autocmd("WinLeave", {
		group = group,
		callback = protect(function()
			local win = vim.api.nvim_get_current_win()
			donor = records[win] and { win = win, tab = vim.api.nvim_win_get_tabpage(win), records = records[win] }
		end),
	})
	vim.api.nvim_create_autocmd("WinNew", {
		group = group,
		callback = protect(function()
			local parent = donor
			donor = nil
			local win = vim.api.nvim_get_current_win()
			if
				not parent
				or win == parent.win
				or vim.api.nvim_win_get_tabpage(win) ~= parent.tab
				or vim.api.nvim_win_get_config(win).relative ~= ""
			then
				return
			end
			-- Splits also copy saved options for buffers hidden in the donor.
			for buf, record in pairs(parent.records) do
				local baseline, installed = vim.deepcopy(record.baseline), vim.deepcopy(record.installed)
				if vim.api.nvim_win_get_buf(win) == buf then
					local current = util.capture_win_options(win, keys)
					for name, value in pairs(installed) do
						if current[name] ~= value then
							baseline[name], installed[name] = current[name], nil
						end
					end
				end
				register(record.lease, win, baseline, installed)
			end
		end),
	})
	vim.api.nvim_create_autocmd("WinEnter", {
		group = group,
		callback = protect(function()
			donor = nil
		end),
	})
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = group,
		callback = protect(function(args)
			local windows = records[vim.api.nvim_get_current_win()]
			local record = windows and windows[args.buf]
			if record and record.lease.released then
				restore(record)
			end
		end),
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = protect(function(args)
			local windows = records[tonumber(args.match)] or {}
			for _, record in pairs(windows) do
				remove(record)
			end
		end),
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = protect(function(args)
			for _, windows in pairs(records) do
				if windows[args.buf] then
					remove(windows[args.buf])
				end
			end
		end),
	})
end

function M.acquire(bufnr, winid)
	local old = records[winid] and records[winid][bufnr]
	if old then
		restore(old)
	end
	local lease = { buf = bufnr, records = {}, released = false }
	lease.source = register(lease, winid, util.capture_win_options(winid, keys), {})
	observe()
	return lease
end

function M.apply(lease, values)
	if not lease or lease.released then
		return
	end
	for name, value in pairs(values) do
		local installed = lease.source.installed[name]
		local current = util.get_win_option(lease.source.win, name)
		if installed ~= nil and current ~= installed then
			lease.source.baseline[name] = current
		end
		lease.source.installed[name] = value
	end
	util.set_win_options(lease.source.win, values)
end

function M.release(lease)
	if not lease or lease.released then
		return
	end
	lease.released = true
	for record in pairs(lease.records) do
		restore(record)
	end
end

function M._test_records()
	return records
end

return M
