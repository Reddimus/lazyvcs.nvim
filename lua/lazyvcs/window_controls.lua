-- Neovim mappings are buffer-local, while review controls belong to windows.
-- Lease only the focused view's mappings so shared real buffers remain ordinary
-- editors in other windows. Restore a mapping only if this lease still owns it.
local compat = require("lazyvcs.compat")
local M = {}
local owners, active = {}, nil
local initialized, syncing = false, false
local sequence = 0

local function mapping(buf, key)
	local expanded = key:gsub("<leader>", function()
		return vim.g.mapleader or "\\"
	end):gsub("<localleader>", function()
		return vim.g.maplocalleader or "\\"
	end)
	local raw = vim.api.nvim_replace_termcodes(expanded, true, false, true)
	for _, value in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if
			value.lhs == expanded
			or value.lhsraw == raw
			or vim.api.nvim_replace_termcodes(value.lhs, true, false, true) == raw
		then
			return value
		end
	end
end

local function restore(buf, map)
	-- mapset preserves script identity and expression-map flags. The API getter
	-- exposes REMAP_SCRIPT (2), whereas maparg/mapset use noremap=1 plus script=1.
	map = vim.deepcopy(map)
	map.noremap = map.noremap ~= 0 and 1 or 0
	local function apply()
		vim.fn.mapset("n", false, map)
	end
	if vim.api.nvim_get_current_buf() == buf then
		return apply()
	end
	-- mapset has no buffer argument. Suppress temporary-entry autocmds: restoring
	-- a hidden buffer's mapping must not adopt it or trigger file-open routing.
	local ignored = vim.o.eventignore
	vim.o.eventignore = "all"
	local ok, err = pcall(vim.api.nvim_buf_call, buf, apply)
	vim.o.eventignore = ignored
	if not ok then
		error(err)
	end
end

local function release()
	local lease = active
	active = nil
	if not lease or not vim.api.nvim_buf_is_valid(lease.buf) then
		return
	end
	for _, item in ipairs(lease.maps) do
		local current = mapping(lease.buf, item.key)
		if current and current.callback == item.callback then
			compat.keymap_del("n", item.key, { buffer = lease.buf })
			if item.previous then
				restore(lease.buf, item.previous)
			end
		end
	end
end

function M.sync()
	if syncing then
		return
	end
	syncing = true
	local ok, err = pcall(function()
		local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
		-- The highest priority wins. On a tie, the window's owner wins, then the
		-- earliest registration, so the choice never depends on pairs() order.
		local selected, definitions, best
		for owner, record in pairs(owners) do
			local maps = record.resolve(win, buf)
			if maps then
				local rank = { record.priority, record.owns and record.owns(win) and 1 or 0, -record.sequence }
				local better = not best
				for index = 1, #rank do
					if better or rank[index] ~= best[index] then
						better = better or rank[index] > best[index]
						break
					end
				end
				if better then
					selected, definitions, best = owner, maps, rank
				end
			end
		end
		if
			active
			and active.owner == selected
			and active.win == win
			and active.buf == buf
			and active.definitions == definitions
		then
			return
		end
		release()
		if not selected then
			return
		end
		active = { owner = selected, win = win, buf = buf, definitions = definitions, maps = {} }
		for _, definition in ipairs(definitions) do
			if definition.key and definition.key ~= false then
				active.maps[#active.maps + 1] = {
					key = definition.key,
					callback = definition.callback,
					previous = mapping(buf, definition.key),
				}
				compat.keymap_set("n", definition.key, definition.callback, {
					buffer = buf,
					silent = true,
					nowait = definition.nowait,
					desc = definition.desc,
				})
			end
		end
	end)
	syncing = false
	if not ok then
		require("lazyvcs.util").notify("Could not update window controls: " .. tostring(err), vim.log.levels.ERROR)
	end
end

function M.unregister(owner)
	owners[owner] = nil
	if active and active.owner == owner then
		release()
	end
end

---Register `resolve(win, buf)` for `owner`. `owns(win)`, when given, marks the
---windows `owner` owns; it decides ties between resolvers of equal priority.
function M.register(owner, resolve, priority, owns)
	if not initialized then
		initialized = true
		local group = vim.api.nvim_create_augroup("lazyvcs_window_controls", { clear = true })
		vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave", "TabLeave" }, {
			group = group,
			callback = require("lazyvcs.util").safe_callback(function()
				if not syncing then
					release()
				end
			end),
		})
		vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter", "BufWinEnter", "TabEnter" }, {
			group = group,
			callback = M.sync,
		})
	end
	sequence = sequence + 1
	owners[owner] = { resolve = resolve, priority = priority or 0, owns = owns, sequence = sequence }
	M.sync()
end

return M
