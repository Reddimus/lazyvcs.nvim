local util = require("lazyvcs.util")
local api = vim.api
local M = {}
local windows, pool = {}, {}
local group
local hidden = "LazyVcsSemanticHidden"
local writing = false
local max_overlay_bytes = 256 * 1024

local function explicit(win)
	local ns = api.nvim_get_hl_ns({ winid = win })
	local source = ns == -1 and api.nvim_get_hl_ns({}) or ns
	for _, named in pairs(api.nvim_get_namespaces()) do
		if named == source then
			return true
		end
	end
	if source > 0 then
		local mappings = {}
		for from, to in tostring(util.get_win_option(win, "winhighlight")):gmatch("([^,:]+):([^,]+)") do
			mappings[from] = to
		end
		for name, value in pairs(api.nvim_get_hl(source, {})) do
			if not value.link or value.link ~= mappings[name] then
				return true
			end
		end
	end
	return false
end

local function user_mappings(value, state)
	if state and value == state.overlay then
		return state.user
	end
	local entries = {}
	for entry in value:gmatch("[^,]+") do
		if entry:match(":([^:]+)$") ~= hidden then
			entries[#entries + 1] = entry
		end
	end
	return table.concat(entries, ",")
end

local function write_mapping(win, value)
	writing = true
	local ok, err = pcall(util.set_win_option, win, "winhighlight", value)
	writing = false
	if not ok then
		error(err)
	end
end

local function strip_window(win)
	if not windows[win] then
		local value = util.get_win_option(win, "winhighlight")
		---@cast value string
		if value:find(hidden, 1, true) then
			local native = api.nvim_get_hl_ns({ winid = win }) > 0 and not explicit(win)
			local user = user_mappings(value)
			write_mapping(win, user)
			if native and user == "" and vim.version.ge(vim.version(), { 0, 11, 7 }) then
				api.nvim_win_set_hl_ns(win, -1)
			end
		end
	end
end

local function strip_unowned()
	for _, win in ipairs(api.nvim_list_wins()) do
		strip_window(win)
	end
end

local function overlay(win, state)
	local entries = state.user == "" and {} or { state.user }
	local names = vim.tbl_keys(state.suppressed)
	table.sort(names)
	for _, name in ipairs(names) do
		entries[#entries + 1] = name .. ":" .. hidden
	end
	state.overlay = table.concat(entries, ",")
	if util.get_win_option(win, "winhighlight") ~= state.overlay then
		write_mapping(win, state.overlay)
	end
	state.native_ns = api.nvim_get_hl_ns({ winid = win })
end

local function owned(win, state)
	return api.nvim_win_is_valid(win)
		and (
			state.native and (api.nvim_get_hl_ns({ winid = win }) == state.native_ns or not explicit(win))
			or state.preserved and api.nvim_get_hl_ns({ winid = win }) == state.previous
			or state.slot and api.nvim_get_hl_ns({ winid = win }) == state.slot.ns
		)
end

---Return user mappings without the native semantic-token overlay.
---@param win integer
---@return string
function M.user_winhighlight(win)
	local value = util.get_win_option(win, "winhighlight")
	---@cast value string
	return user_mappings(value, windows[win])
end

local function semantic(name)
	return name:match("^@lsp%.type%.") or name:match("^@lsp%.mod%.") or name:match("^@lsp%.typemod%.")
end

local function write_pooled_highlight(ns, name, definition)
	local value = vim.deepcopy(definition)
	value.default = nil
	api.nvim_set_hl(ns, name, value)
end

local function define(slot, name, value)
	if slot.native then
		if slot.suppressed[name] then
			return false
		end
		local bytes = #name + #hidden + 2
		if slot.bytes + bytes <= max_overlay_bytes and slot.count < 4096 then
			slot.suppressed[name] = true
			slot.bytes, slot.count = slot.bytes + bytes, slot.count + 1
			return true
		end
		return false
	else
		write_pooled_highlight(slot.ns, name, value)
		slot.names[name] = true
		return true
	end
end

local function suppress(slot, token, ft)
	local added = false
	local function empty(name)
		for _, qualified in ipairs({ name, name .. "." .. ft }) do
			if not slot.suppressed[qualified] and define(slot, qualified, {}) then
				added = true
				if not slot.native then
					slot.suppressed[qualified] = true
				end
			end
		end
	end
	empty("@lsp.type." .. token.type)
	for modifier in pairs(token.modifiers or {}) do
		empty("@lsp.mod." .. modifier)
		empty("@lsp.typemod." .. token.type .. "." .. modifier)
	end
	return added
end

local function resolver(theme, global)
	local resolved, resolving = {}, {}
	local function inherited(name)
		if resolved[name] then
			return resolved[name]
		end
		if resolving[name] then
			return {}
		end
		resolving[name] = true
		local value = theme[name] or global[name]
		if not value and name:sub(1, 1) == "@" and name:find("%.") then
			value = inherited((name:gsub("%.[^.]+$", "")))
		elseif value and value.link then
			if value.link == name then
				value = global[name] or {}
				value = vim.deepcopy(value)
				value.link = nil
			else
				value = inherited(value.link)
			end
		end
		value = vim.deepcopy(value or {})
		value.default = nil
		resolved[name], resolving[name] = value, nil
		return resolved[name]
	end
	return inherited
end

local global_links
local function supports_global_links()
	if global_links == nil then
		local ns = api.nvim_create_namespace("lazyvcs-highlight-capability")
		global_links = pcall(api.nvim_set_hl, ns, "LazyVcsGlobalLinkProbe", { link_global = "Normal" })
	end
	return global_links
end

-- Public highlight definitions omit the distinction between local and global links.
local function requires_source_namespace(theme, global)
	if not supports_global_links() then
		return false
	end
	local local_value, global_value = resolver(theme, global), resolver({}, global)
	local checked = {}
	local function ambiguous(name)
		if checked[name] then
			return false
		end
		checked[name] = true
		local value = theme[name] or global[name]
		if value and value.link and value.link ~= name then
			return not vim.deep_equal(local_value(value.link), global_value(value.link)) or ambiguous(value.link)
		end
		return false
	end
	for name in pairs(theme) do
		if ambiguous(name) then
			return true
		end
	end
	return false
end

local function acquire()
	local slot
	for _, candidate in ipairs(pool) do
		if not candidate.busy then
			slot = candidate
			break
		end
	end
	if not slot then
		slot = { ns = api.nvim_create_namespace("lazyvcs-diff-highlighting-" .. (#pool + 1)), names = {} }
		pool[#pool + 1] = slot
	end
	slot.busy = true
	return slot
end

function M.refresh(win)
	local state = windows[win]
	if not state or not owned(win, state) then
		return
	end
	local global = api.nvim_get_hl(0, {})
	local source = state.previous == -1 and api.nvim_get_hl_ns({}) or state.previous
	local theme = source and source > 0 and api.nvim_get_hl(source, {}) or {}
	if state.native and state.previous == -1 and source > 0 then
		state.user = user_mappings(util.get_win_option(win, "winhighlight"), state)
		write_mapping(win, state.user)
		api.nvim_win_set_hl_ns(win, state.previous)
		state.native, state.preserved = nil, true
	end
	if not state.native then
		if requires_source_namespace(theme, global) then
			if state.slot then
				api.nvim_win_set_hl_ns(win, state.previous)
				state.slot.busy = false
				state.slot = nil
			end
			state.preserved = true
			return
		end
		state.slot = state.slot or acquire()
		state.preserved = nil
	end
	local slot = state.native and state or state.slot
	slot.suppressed, slot.bytes, slot.count = {}, 0, 0
	if state.native then
		state.user = user_mappings(util.get_win_option(win, "winhighlight"), state)
		api.nvim_set_hl(0, hidden, {})
	end
	if not state.native then
		local inherited = resolver(theme, global)
		-- Namespaces cannot delete definitions. Reset through the new owner's graph.
		for name in pairs(slot.names) do
			write_pooled_highlight(slot.ns, name, inherited(name))
		end
		for name in pairs(theme) do
			define(slot, name, inherited(name))
		end
	end
	-- Cleared definitions remain in nvim_get_hl's enumeration.
	for name, value in pairs(global) do
		if semantic(name) and next(value) ~= nil then
			define(slot, name, {})
			if not slot.native then
				slot.suppressed[name] = true
			end
		end
	end
	for name, value in pairs(theme) do
		if semantic(name) and next(value) ~= nil then
			define(slot, name, {})
			if not slot.native then
				slot.suppressed[name] = true
			end
		end
	end
	local buf = api.nvim_win_get_buf(win)
	local ft = vim.bo[buf].filetype
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
		local provider = client.server_capabilities.semanticTokensProvider
		local legend = type(provider) == "table" and provider.legend
		if legend then
			local modifiers = {}
			for _, modifier in ipairs(legend.tokenModifiers or {}) do
				modifiers[modifier] = true
			end
			for _, kind in ipairs(legend.tokenTypes or {}) do
				suppress(slot, { type = kind, modifiers = modifiers }, ft)
			end
		end
	end
	if state.native then
		overlay(win, state)
		if state.native_ns <= 0 and next(state.suppressed) then
			write_mapping(win, state.user)
			state.native, state.preserved = nil, true
			api.nvim_win_set_hl_ns(win, state.previous)
			return M.refresh(win)
		end
	else
		api.nvim_win_set_hl_ns(win, slot.ns)
	end
end

function M.release(win)
	local state = win and windows[win]
	if not state then
		return
	end
	windows[win] = nil
	if state.native then
		if api.nvim_win_is_valid(win) then
			local restore = owned(win, state)
			local user = user_mappings(util.get_win_option(win, "winhighlight"), state)
			write_mapping(win, user)
			-- Older runtimes stop activating native overlays after restoring inheritance.
			if restore and user == "" and vim.version.ge(vim.version(), { 0, 11, 7 }) then
				api.nvim_win_set_hl_ns(win, state.previous)
			end
		end
	elseif not state.preserved and owned(win, state) then
		api.nvim_win_set_hl_ns(win, state.previous)
	end
	if state.slot then
		state.slot.busy = false
	end
	strip_unowned()
	if not next(windows) and group then
		api.nvim_del_augroup_by_id(group)
		group = nil
	end
end

local function protected(callback)
	return function(...)
		local ok, err = pcall(callback, ...)
		if not ok then
			util.notify("Diff highlighting: " .. tostring(err):gsub("%s+", " "), vim.log.levels.WARN)
		end
	end
end

-- Buffer-local window-option records can restore an overlay after its session
-- has closed. Keep this cheap cleanup alive independently of active owners.
local cleanup_group = api.nvim_create_augroup("LazyVCSDiffHighlightCleanup", { clear = true })
api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinNew" }, {
	group = cleanup_group,
	callback = protected(function()
		strip_window(api.nvim_get_current_win())
	end),
})

local function listen()
	if group then
		return
	end
	group = api.nvim_create_augroup("LazyVCSDiffHighlighting", { clear = true })
	api.nvim_create_autocmd({ "WinEnter", "WinNew" }, { group = group, callback = protected(strip_unowned) })
	local function schedule(win, state, mapping_changed)
		state.mapping_changed = state.mapping_changed or mapping_changed
		if state.pending then
			return
		end
		state.pending = true
		vim.schedule(protected(function()
			state.pending = false
			if windows[win] == state then
				if state.slot and state.mapping_changed and api.nvim_win_is_valid(win) then
					state.mapping_changed = false
					-- Recheck ownership after coalescing mapping changes. An explicit
					-- window namespace survives winhighlight writes on Neovim 0.11/0.12.
					if not owned(win, state) and not explicit(win) then
						state.previous = api.nvim_get_hl_ns({ winid = win })
						api.nvim_win_set_hl_ns(win, state.slot.ns)
					end
				end
				local ok, err = pcall(M.refresh, win)
				if not ok then
					M.release(win)
					require("lazyvcs.util").notify(
						"Diff highlighting: " .. tostring(err):gsub("%s+", " "),
						vim.log.levels.WARN
					)
				end
			end
		end))
	end
	api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "winhighlight",
		callback = protected(function()
			if writing then
				return
			end
			local global = api.nvim_get_option_value("winhighlight", { scope = "global" })
			local clean = user_mappings(global)
			if clean ~= global then
				writing = true
				local ok, err = pcall(api.nvim_set_option_value, "winhighlight", clean, { scope = "global" })
				writing = false
				if not ok then
					error(err)
				end
			end
			local win = api.nvim_get_current_win()
			local state = windows[win]
			if state then
				schedule(win, state, true)
			end
		end),
	})
	api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = protected(function(event)
			M.release(tonumber(event.match))
		end),
	})
	api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = protected(function(event)
			local release = {}
			for win, state in pairs(windows) do
				if state.buf == event.buf then
					release[#release + 1] = win
				end
			end
			for _, win in ipairs(release) do
				M.release(win)
			end
		end),
	})
	api.nvim_create_autocmd("LspTokenUpdate", {
		group = group,
		callback = protected(function(event)
			local token = event.data and event.data.token
			if not token then
				return
			end
			for win, state in pairs(windows) do
				if not state.preserved and owned(win, state) and api.nvim_win_get_buf(win) == event.buf then
					local added = suppress(state.native and state or state.slot, token, vim.bo[event.buf].filetype)
					if state.native and added then
						overlay(win, state)
					end
				end
			end
		end),
	})
	api.nvim_create_autocmd({ "ColorScheme", "FileType", "LspAttach", "BufWinEnter" }, {
		group = group,
		callback = protected(function(event)
			for win, state in pairs(windows) do
				if
					event.event == "BufWinEnter"
					and api.nvim_win_is_valid(win)
					and api.nvim_win_get_buf(win) ~= state.buf
				then
					M.release(win)
				end
				if
					owned(win, state)
					and (event.event == "ColorScheme" or api.nvim_win_get_buf(win) == event.buf)
					and not state.pending
				then
					schedule(win, state)
				end
			end
		end),
	})
end

function M.apply(win, policy)
	if policy == "editor" then
		M.release(win)
		return
	end
	if not win or not api.nvim_win_is_valid(win) then
		return
	end
	if windows[win] then
		M.refresh(win)
		return
	end
	if not explicit(win) then
		local state = {
			native = true,
			previous = api.nvim_get_hl_ns({ winid = win }),
			user = util.get_win_option(win, "winhighlight"),
			buf = api.nvim_win_get_buf(win),
		}
		windows[win] = state
		M.refresh(win)
		listen()
		return
	end
	windows[win] = { preserved = true, previous = api.nvim_get_hl_ns({ winid = win }), buf = api.nvim_win_get_buf(win) }
	M.refresh(win)
	listen()
end

return M
