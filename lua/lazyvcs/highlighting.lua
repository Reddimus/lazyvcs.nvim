local util = require("lazyvcs.util")
local api = vim.api
local M = {}
local windows, pool = {}, {}
local group
local hidden = "LazyVcsSemanticHidden"
local writing = false
local max_overlay_bytes = 256 * 1024
local mapping_records, filler_slots = {}, {}
local owner_source, owner_prefix = "LazyVcsDiffOwner", "LazyVcsDiffOwner"
local write_mapping, user_mappings, strip_unowned, release_filler
local derived = {}

local function invalidate(state)
	state.revision = (state.revision or 0) + 1
	state.suspension = nil
end

local function marker_record(value, buf)
	local found
	for from, to in value:gmatch("([^,:]+):([^,]+)") do
		local id = from == owner_source and tonumber(to:match("^" .. owner_prefix .. "(%d+)$"))
		local record = id and filler_slots[id] and filler_slots[id].record
		if record and record.buf == buf and windows[record.win] == record.state and record.state.filler == record then
			found = record
		end
	end
	return found
end

local function defaults(refresh)
	local definitions = {
		LazyVcsDiffFiller = { link = "NonText" },
		LazyVcsDiffRemoved = api.nvim_get_hl(0, { name = "DiffDelete", link = false }),
	}
	for name, value in pairs(definitions) do
		local current = api.nvim_get_hl(0, { name = name, create = false })
		-- :highlight clear may drop the default flag without changing the colors.
		current.default = nil
		if refresh and derived[name] and vim.deep_equal(current, derived[name]) then
			api.nvim_set_hl(0, name, {})
		end
		value.default = true
		---@diagnostic disable-next-line: param-type-mismatch
		api.nvim_set_hl(0, name, value)
		if not next(current) or (derived[name] and vim.deep_equal(current, derived[name])) then
			derived[name] = api.nvim_get_hl(0, { name = name })
			derived[name].default = nil
		else
			derived[name] = nil
		end
	end
end

local function local_filler(win)
	return api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
end

-- Also used while projecting the pre-diff window into a saved session.
function M.user_fillchars(win)
	local value = local_filler(win)
	local buf = api.nvim_win_get_buf(win)
	local state = windows[win]
	local record = state and state.buf == buf and state.filler
		or marker_record(util.get_win_option(win, "winhighlight"), buf)
	return record and value == record.written and record.raw or value
end

local function apply_filler(win, state, style)
	if not state.role or not style.enabled then
		release_filler(win, state)
		return
	end
	if state.filler and not state.filler.suspended then
		return
	end
	local previous_slot = state.filler and state.filler.slot
	release_filler(win, state)
	local raw = local_filler(win)
	local global = api.nvim_get_option_value("fillchars", { scope = "global" })
	local effective = raw ~= "" and raw or global
	local has_diff = ("," .. effective):find(",diff:", 1, true)
	if style.filler == "auto" and has_diff then
		return
	end
	local entries = {}
	-- A comma can itself be a fill character (e.g. eob:,,vert:|).
	-- Split only at the separator before an option name, not at glyph bytes.
	for entry in (effective .. ","):gmatch("(.-),%f[%a%z]") do
		if entry ~= "" and not entry:match("^diff:") then
			entries[#entries + 1] = entry
		end
	end
	local prefix = #entries > 0 and table.concat(entries, ",") .. "," or ""
	local value = prefix .. "diff:" .. (style.filler == "auto" and "╱" or style.filler)
	local ok, err = pcall(util.set_win_option, win, "fillchars", value)
	if not ok then
		if not tostring(err):find("E1512", 1, true) then
			error(err)
		end
		value = prefix .. "diff:/"
		util.set_win_option(win, "fillchars", value)
	end
	local slot, id
	for index, candidate in ipairs(filler_slots) do
		if candidate == previous_slot or not previous_slot and not candidate.record then
			slot, id = candidate, index
			break
		end
	end
	if not slot then
		slot, id = {}, #filler_slots + 1
		filler_slots[id] = slot
	end
	state.owner_tag = owner_prefix .. id
	state.filler = {
		raw = raw,
		written = value,
		win = win,
		buf = state.buf,
		state = state,
		slot = slot,
		-- Prove which inputs built this active filler, including changes made before
		-- the next suspension rather than while its resume callback is pending.
		global_ns = api.nvim_get_hl_ns({}),
		global_filler = global,
		style = vim.deepcopy(style),
		policy = state.policy,
		role = state.role,
	}
	slot.record = state.filler
	-- Equal fillchars writes do not identify their raw origin. This inert mapping
	-- follows native clones even when WinNew regenerates their namespace ID.
	local mapping = util.get_win_option(win, "winhighlight")
	state.filler.user = mapping
	state.filler.mapping = (mapping ~= "" and mapping .. "," or "") .. owner_source .. ":" .. state.owner_tag
	write_mapping(win, state.filler.mapping)
end

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
			mappings[from:lower()] = to:lower()
		end
		for name, value in pairs(api.nvim_get_hl(source, {})) do
			if not value.link or value.link:lower() ~= mappings[name:lower()] then
				return true
			end
		end
	end
	return false
end

user_mappings = function(value, state)
	if state and state.filler and value == state.filler.mapping then
		return state.filler.user
	end
	if state and value == state.restored_mapping then
		return value
	end
	if state and value == state.user then
		return value
	end
	if state and value == state.overlay then
		return state.user
	end
	local entries = {}
	for entry in value:gmatch("[^,]+") do
		local from, to = entry:match("^([^:]+):(.+)$")
		local injected = state and state.overlay and (state.diff_mappings or {})[from] == to
		local owner = from == owner_source and state and state.owner_tag == to
		local semantic_hidden = (not state or state.overlay) and to == hidden
		if not semantic_hidden and not injected and not owner then
			entries[#entries + 1] = entry
		end
	end
	return table.concat(entries, ",")
end

write_mapping = function(win, value)
	writing = true
	local ok, err = pcall(util.set_win_option, win, "winhighlight", value)
	writing = false
	if not ok then
		error(err)
	end
end

local function buffer_mappings(win, value)
	local record = marker_record(value, api.nvim_win_get_buf(win))
	if record and value == record.mapping then
		return record.user
	end
	local records = mapping_records[api.nvim_win_get_buf(win)] or {}
	if records[value] then
		return user_mappings(value, records[value])
	end
	for _, saved in pairs(records) do
		if value == saved.user then
			return value
		end
	end
	if record then
		return user_mappings(value, record.state)
	end
	for _, record in pairs(records) do
		value = user_mappings(value, record)
	end
	return user_mappings(value)
end

local function strip_window(win)
	if not windows[win] then
		local raw = local_filler(win)
		local original = M.user_fillchars(win)
		if raw ~= original then
			util.set_win_option(win, "fillchars", original)
		end
		local value = util.get_win_option(win, "winhighlight")
		---@cast value string
		if value:find(hidden, 1, true) or value:find(":LazyVcsDiff", 1, true) then
			local origin = marker_record(value, api.nvim_win_get_buf(win))
			local native = api.nvim_get_hl_ns({ winid = win }) > 0 and not explicit(win)
			local user = buffer_mappings(win, value)
			write_mapping(win, user)
			if
				native
				and user == ""
				and (vim.version.ge(vim.version(), { 0, 11, 7 }) or origin and origin.state.previous == -1)
			then
				-- Marker provenance proves this clone inherited its origin's theme.
				-- Unrelated namespace-zero windows retain the floor compatibility path.
				api.nvim_win_set_hl_ns(win, -1)
			end
		end
	end
end

strip_unowned = function()
	for _, win in ipairs(api.nvim_list_wins()) do
		strip_window(win)
	end
end

release_filler = function(win, state)
	local record = state.filler
	if not record then
		return
	end
	-- Clean all visible copies while this lifetime is still resolvable. BufLeave
	-- removes the same write before Neovim saves hidden window options.
	strip_unowned()
	if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == record.buf then
		if local_filler(win) == record.written then
			util.set_win_option(win, "fillchars", record.raw)
		end
		local current = util.get_win_option(win, "winhighlight")
		local user = user_mappings(current, state)
		state.restored_mapping = user
		if current ~= user then
			write_mapping(win, user)
		end
	end
	state.filler, state.owner_tag = nil, nil
	record.slot.record = nil
end

local function overlay(win, state)
	local current = util.get_win_option(win, "winhighlight")
	state.user = user_mappings(current, state)
	local entries = state.user == "" and {} or { state.user }
	local names = vim.tbl_keys(state.suppressed)
	table.sort(names)
	for _, name in ipairs(names) do
		entries[#entries + 1] = name .. ":" .. hidden
	end
	for from, to in pairs(state.diff_mappings or {}) do
		entries[#entries + 1] = from .. ":" .. to
	end
	if state.filler and not state.filler.suspended then
		entries[#entries + 1] = owner_source .. ":" .. state.owner_tag
	end
	state.overlay = table.concat(entries, ",")
	mapping_records[state.buf] = mapping_records[state.buf] or {}
	mapping_records[state.buf][state.overlay] = {
		overlay = state.overlay,
		user = state.user,
		diff_mappings = state.diff_mappings,
		owner_tag = state.owner_tag,
	}
	if current ~= state.overlay then
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
	return windows[win] and user_mappings(value, windows[win]) or buffer_mappings(win, value)
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

local function restore_namespace(win, state)
	if state.private_ns then
		local user = user_mappings(util.get_win_option(win, "winhighlight"), state)
		api.nvim_win_set_hl_ns(win, 0)
		write_mapping(win, user)
	else
		api.nvim_win_set_hl_ns(win, state.previous)
	end
end

function M.refresh(win)
	local state = windows[win]
	if state then
		invalidate(state)
	end
	if not state or not owned(win, state) then
		return
	end
	defaults()
	local style = state.style
	apply_filler(win, state, style)
	local global = api.nvim_get_hl(0, {})
	local source = state.previous == -1 and api.nvim_get_hl_ns({}) or state.previous
	local theme = source and source > 0 and api.nvim_get_hl(source, {}) or {}
	if state.native and state.previous == -1 and source > 0 then
		state.user = user_mappings(util.get_win_option(win, "winhighlight"), state)
		write_mapping(win, state.user)
		restore_namespace(win, state)
		state.native, state.preserved = nil, true
	end
	if not state.native then
		if requires_source_namespace(theme, global) then
			if state.slot then
				restore_namespace(win, state)
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
	state.diff_mappings = {}
	if state.role and style.enabled then
		local mappings = state.native and state.user or M.user_winhighlight(win)
		local user = {}
		for from, to in mappings:gmatch("([^,:]+):([^,]+)") do
			user[from] = to
		end
		local inherited = resolver(theme, global)
		local targets = { DiffDelete = "LazyVcsDiffFiller" }
		if state.role == "old" and style.removed then
			targets.DiffAdd = "LazyVcsDiffRemoved"
		elseif user.DiffAdd then
			-- Explicit namespaces take precedence over winhighlight. Reproduce
			-- the user's addition mapping even on a pane with no color override.
			targets.DiffAdd = "DiffAdd"
		end
		for from, to in pairs(targets) do
			if state.native then
				if not user[from] then
					state.diff_mappings[from] = to
				end
			else
				local value = inherited(user[from] or to)
				if
					not user[from]
					and to == "LazyVcsDiffRemoved"
					and derived[to]
					and not (theme[to] and next(theme[to]))
				then
					value = inherited("DiffDelete")
				end
				define(slot, from, value)
			end
		end
	end
	if state.policy ~= "editor" then
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
	end
	if state.native then
		overlay(win, state)
		if state.native_ns <= 0 and next(state.suppressed) then
			write_mapping(win, state.user)
			state.native, state.preserved = nil, true
			restore_namespace(win, state)
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
	invalidate(state)
	release_filler(win, state)
	windows[win] = nil
	if state.native then
		if api.nvim_win_is_valid(win) then
			local restore = owned(win, state)
			local user = user_mappings(util.get_win_option(win, "winhighlight"), state)
			write_mapping(win, user)
			-- Older runtimes stop activating native overlays after restoring inheritance.
			if restore and user == "" and vim.version.ge(vim.version(), { 0, 11, 7 }) then
				restore_namespace(win, state)
			end
		end
	elseif not state.preserved and owned(win, state) then
		restore_namespace(win, state)
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

-- A hidden buffer can restore owned values from Neovim's saved window options
-- after the last view closes. Keep its cleanup records until BufWipeout.
local cleanup_group = api.nvim_create_augroup("LazyVCSDiffHighlightCleanup", { clear = true })
-- Filler suspension changes window options, not the semantic highlight graph.
-- Reuse only an exact native overlay or already-owned pooled slot.
local function unchanged(win, state, saved, filler, namespace, mapping)
	return windows[win] == state
		and api.nvim_win_is_valid(win)
		and api.nvim_win_get_buf(win) == state.buf
		and ((saved.native and state.native) or (saved.slot and not state.native and not state.preserved and state.slot == saved.slot))
		and state.filler == saved.filler
		and state.filler.suspended
		and not state.pending
		and state.revision == saved.revision
		and state.overlay == saved.graph_overlay
		and state.policy == saved.policy
		and state.role == saved.role
		and vim.deep_equal(state.style, saved.style)
		and api.nvim_get_hl_ns({ winid = win }) == namespace
		and api.nvim_get_hl_ns({}) == saved.global_ns
		and local_filler(win) == filler
		and api.nvim_get_option_value("fillchars", { scope = "global" }) == saved.global_filler
		and util.get_win_option(win, "winhighlight") == mapping
end

local function resettle(win, state)
	local saved = state.suspension
	state.suspension = nil
	if saved and unchanged(win, state, saved, saved.raw, saved.suspended_ns, saved.user) then
		util.set_win_option(win, "fillchars", saved.filler.written)
		if unchanged(win, state, saved, saved.filler.written, saved.suspended_ns, saved.user) then
			write_mapping(win, saved.overlay)
			if unchanged(win, state, saved, saved.filler.written, saved.active_ns, saved.overlay) then
				saved.filler.suspended = nil
				return
			end
		end
	end
	M.refresh(win)
end

local function resume_filler(win, state)
	if state.resume_pending then
		return
	end
	state.resume_pending = true
	vim.schedule(protected(function()
		state.resume_pending = nil
		if
			windows[win] == state
			and api.nvim_win_is_valid(win)
			and api.nvim_win_get_buf(win) == state.buf
			and state.filler
			and state.filler.suspended
		then
			resettle(win, state)
		end
	end))
end
api.nvim_create_autocmd("BufLeave", {
	group = cleanup_group,
	callback = protected(function(event)
		local win = api.nvim_get_current_win()
		local state = windows[win]
		if state and state.buf == event.buf and state.filler then
			local record = state.filler
			local current = util.get_win_option(win, "winhighlight")
			local namespace = api.nvim_get_hl_ns({ winid = win })
			local native = state.native and current == state.overlay and namespace == state.native_ns
			local slot = not state.preserved and state.slot and current == record.mapping and namespace == state.slot.ns
			local saved
			if (native or slot) and local_filler(win) == record.written and not state.pending then
				saved = {
					native = native,
					slot = slot and state.slot or nil,
					filler = record,
					overlay = current,
					graph_overlay = state.overlay,
					active_ns = namespace,
					global_ns = record.global_ns,
					global_filler = record.global_filler,
					revision = state.revision,
					policy = record.policy,
					role = record.role,
					style = record.style,
				}
			end
			local user = user_mappings(current, state)
			state.restored_mapping = user
			if local_filler(win) == state.filler.written then
				util.set_win_option(win, "fillchars", state.filler.raw)
			end
			if current ~= user then
				write_mapping(win, user)
			end
			record.suspended = true
			if saved and windows[win] == state and state.filler == record and state.revision == saved.revision then
				saved.user, saved.raw = user, record.raw
				saved.suspended_ns = api.nvim_get_hl_ns({ winid = win })
				state.suspension = saved
			end
			resume_filler(win, state)
		end
	end),
})
api.nvim_create_autocmd("WinLeave", {
	group = cleanup_group,
	callback = protected(function()
		local win = api.nvim_get_current_win()
		local state = windows[win]
		-- A focus move leaves this buffer visible. Settle before synchronous
		-- callers such as session save capture its active overlay.
		if state and state.filler and state.filler.suspended and api.nvim_win_get_buf(win) == state.buf then
			resettle(win, state)
		end
	end),
})
api.nvim_create_autocmd({ "BufWinEnter", "WinEnter", "WinNew" }, {
	group = cleanup_group,
	callback = protected(function()
		local win = api.nvim_get_current_win()
		strip_window(win)
		local state = windows[win]
		if state and state.filler and state.filler.suspended then
			resume_filler(win, state)
		end
	end),
})

api.nvim_create_autocmd("ColorScheme", {
	group = cleanup_group,
	callback = protected(function()
		for _, state in pairs(windows) do
			invalidate(state)
		end
		defaults(true)
	end),
})
api.nvim_create_autocmd("BufWipeout", {
	group = cleanup_group,
	callback = function(event)
		mapping_records[event.buf] = nil
	end,
})

local function listen()
	if group then
		return
	end
	group = api.nvim_create_augroup("LazyVCSDiffHighlighting", { clear = true })
	api.nvim_create_autocmd({ "WinEnter", "WinNew" }, { group = group, callback = protected(strip_unowned) })
	local function schedule(win, state, mapping_changed)
		invalidate(state)
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
				if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == event.buf then
					invalidate(state)
				end
				if
					state.policy ~= "editor"
					and not state.preserved
					and owned(win, state)
					and api.nvim_win_get_buf(win) == event.buf
				then
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
					event.event == "ColorScheme"
					or (api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == event.buf)
				then
					invalidate(state)
				end
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

function M.apply(win, policy, role, style)
	style = style or require("lazyvcs.config").get().diff_style
	if policy == "editor" and not (role and style.enabled) then
		M.release(win)
		return
	end
	if not win or not api.nvim_win_is_valid(win) then
		return
	end
	if windows[win] then
		windows[win].policy, windows[win].role, windows[win].style = policy, role, style
		M.refresh(win)
		return
	end
	strip_window(win)
	if not explicit(win) then
		local state = {
			native = true,
			private_ns = api.nvim_get_hl_ns({ winid = win }) > 0 and util.get_win_option(win, "winhighlight") ~= "",
			previous = api.nvim_get_hl_ns({ winid = win }),
			user = util.get_win_option(win, "winhighlight"),
			buf = api.nvim_win_get_buf(win),
			policy = policy,
			role = role,
			style = style,
		}
		windows[win] = state
		M.refresh(win)
		listen()
		return
	end
	windows[win] = {
		preserved = true,
		previous = api.nvim_get_hl_ns({ winid = win }),
		buf = api.nvim_win_get_buf(win),
		policy = policy,
		role = role,
		style = style,
	}
	M.refresh(win)
	listen()
end

return M
