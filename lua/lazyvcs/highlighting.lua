local util = require("lazyvcs.util")
local api = vim.api
local M = {}
local windows, pool = {}, {}
local group
local hidden = "LazyVcsSemanticHidden"
local writing = false
local filler_writes = 0
local max_overlay_bytes = 256 * 1024
local filler_slots = {}
local owner_source, owner_prefix = "LazyVcsDiffOwner", "LazyVcsDiffOwner"
local write_mapping, user_mappings, strip_unowned, release_filler
local derived = {}
local aliases = { LazyVcsDiffFiller = "LazyVcsOverlayFiller", LazyVcsDiffRemoved = "LazyVcsOverlayRemoved" }
local private_targets = {
	lazyvcssemantichidden = true,
	lazyvcsoverlayfiller = true,
	lazyvcsoverlayremoved = true,
}

local function private_entry(from, to)
	return private_targets[to:lower()]
		or from:lower() == owner_source:lower() and to:lower():match("^lazyvcsdiffowner%d+$") ~= nil
end

local function has_private(value)
	for from, to in value:gmatch("([^,:]+):([^,]+)") do
		if private_entry(from, to) then
			return true
		end
	end
	return false
end

local function invalidate(state)
	state.revision = (state.revision or 0) + 1
	state.suspension = nil
end

local function marker_record(value, buf)
	local found
	for from, to in value:gmatch("([^,:]+):([^,]+)") do
		local id = from:lower() == owner_source:lower() and tonumber(to:lower():match("^lazyvcsdiffowner(%d+)$"))
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
	for public, alias in pairs(aliases) do
		local current = api.nvim_get_hl(0, { name = alias, create = false })
		if (current.link or ""):lower() ~= public:lower() then
			-- Registered defaults survive :highlight clear. These names are private;
			-- reassert a cleared or replaced link without rewriting an unchanged one.
			api.nvim_set_hl(0, alias, { link = public, default = true, force = true })
		end
	end
end

local function local_filler(win)
	return api.nvim_get_option_value("fillchars", { win = win, scope = "local" })
end

local function current_state(win, state)
	return windows[win] == state and api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == state.buf
end

local function current_filler(win, state, record)
	return current_state(win, state) and state.filler == record and record.slot.record == record
end

local function write_filler(win, value)
	filler_writes = filler_writes + 1
	local ok, err = pcall(util.set_win_option, win, "fillchars", value)
	filler_writes = filler_writes - 1
	if not ok then
		error(err)
	end
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

local function mark_filler(win, state, record)
	if not current_filler(win, state, record) then
		return false
	end
	local revision = state.revision
	record.user = user_mappings(util.get_win_option(win, "winhighlight"))
	record.mapping = (record.user ~= "" and record.user .. "," or "") .. owner_source .. ":" .. state.owner_tag
	write_mapping(win, record.mapping)
	return current_filler(win, state, record)
		and state.revision == revision
		and marker_record(util.get_win_option(win, "winhighlight"), state.buf) == record
end

local function apply_filler(win, state, style)
	if not state.role or not style.enabled then
		release_filler(win, state)
		return
	end
	if state.filler and not state.filler.suspended then
		local record = state.filler
		if
			current_filler(win, state, record)
			and marker_record(util.get_win_option(win, "winhighlight"), state.buf) ~= record
		then
			-- A user WinHL edit can remove the marker without changing this filler.
			-- Restore its existing copy provenance, including on the pooled path.
			if not mark_filler(win, state, record) and current_filler(win, state, record) then
				-- A native callback may overwrite the marker without replacing us.
				-- Keep its user mapping and release filler that cannot identify copies.
				release_filler(win, state)
			end
		end
		return
	end
	local previous_slot = state.filler and state.filler.slot
	release_filler(win, state)
	if not current_state(win, state) then
		return
	end
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
	-- Value equality cannot identify a copied window's raw origin. This inert mapping
	-- follows native clones even when WinNew regenerates their namespace ID.
	local record = state.filler
	-- Publish before either observable write so nested cleanup can settle it.
	if not mark_filler(win, state, record) then
		if current_filler(win, state, record) then
			release_filler(win, state)
		end
		return
	end
	local ok, err = pcall(write_filler, win, value)
	if not ok then
		if not tostring(err):find("E1512", 1, true) then
			error(err)
		end
		if current_filler(win, state, record) then
			record.written = prefix .. "diff:/"
			write_filler(win, record.written)
		end
	end
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

user_mappings = function(value)
	local entries = {}
	for entry in value:gmatch("[^,]+") do
		local from, to = entry:match("^([^:]+):(.+)$")
		if not (from and to and private_entry(from, to)) then
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
	return user_mappings(record and value == record.mapping and record.user or value)
end

local function strip_window(win, preserve_filler, copied)
	if api.nvim_win_is_valid(win) and not windows[win] then
		local mapping = util.get_win_option(win, "winhighlight")
		if not has_private(mapping) then
			return
		end
		local buf = api.nvim_win_get_buf(win)
		local raw = local_filler(win)
		if copied and (copied.buf ~= buf or copied.mapping ~= mapping) then
			return
		end
		local original = copied and raw == copied.record.written and copied.record.raw or M.user_fillchars(win)
		if raw ~= original and not preserve_filler then
			write_filler(win, original)
		end
		if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf or windows[win] then
			return
		end
		local value = util.get_win_option(win, "winhighlight")
		---@cast value string
		if has_private(value) then
			local retained = copied and value == copied.mapping and copied
			local origin = retained and retained.record or marker_record(value, api.nvim_win_get_buf(win))
			local native = api.nvim_get_hl_ns({ winid = win }) > 0 and not explicit(win)
			local user = retained and retained.user or buffer_mappings(win, value)
			if value ~= user then
				write_mapping(win, user)
			end
			if
				api.nvim_win_is_valid(win)
				and api.nvim_win_get_buf(win) == buf
				and not windows[win]
				and native
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

strip_unowned = function(record)
	local wins, copies = api.nvim_list_wins(), {}
	if record then
		-- Nested release can reuse this slot before later copies are visited.
		-- Capture only this lifetime's copies before the first observable restore.
		for _, win in ipairs(wins) do
			if api.nvim_win_is_valid(win) and not windows[win] then
				local buf = api.nvim_win_get_buf(win)
				local mapping = util.get_win_option(win, "winhighlight")
				if marker_record(mapping, buf) == record then
					copies[win] =
						{ buf = buf, mapping = mapping, record = record, user = buffer_mappings(win, mapping) }
				end
			end
		end
	end
	for _, win in ipairs(wins) do
		strip_window(win, false, copies[win])
	end
end

release_filler = function(win, state)
	local record = state.filler
	if not record then
		return
	end
	local releasing, restoring = record.releasing, record.restoring
	record.releasing = true
	local ok, err = pcall(function()
		if not releasing then
			strip_unowned(record)
		end
		if state.filler ~= record or record.slot.record ~= record then
			return
		end
		if current_state(win, state) then
			if not restoring and local_filler(win) == record.written then
				-- During copy cleanup, an inner release still restores this origin.
				-- During this setter, its new raw value is already visible to callbacks.
				record.restoring = true
				write_filler(win, record.raw)
			end
			if not current_filler(win, state, record) then
				return
			end
			local current_mapping = util.get_win_option(win, "winhighlight")
			local user = user_mappings(current_mapping)
			if current_mapping ~= user then
				write_mapping(win, user)
			end
		end
		if state.filler == record then
			state.filler, state.owner_tag = nil, nil
		end
		if record.slot.record == record then
			record.slot.record = nil
		end
	end)
	record.releasing, record.restoring = releasing, restoring
	if not ok then
		error(err)
	end
end

local function overlay(win, state)
	local current = util.get_win_option(win, "winhighlight")
	state.user = user_mappings(current)
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
	if current ~= state.overlay then
		write_mapping(win, state.overlay)
	end
	if current_state(win, state) then
		state.native_ns = api.nvim_get_hl_ns({ winid = win })
	end
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
	return windows[win] and user_mappings(value) or buffer_mappings(win, value)
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

local function lookup(graph, name, folded)
	local value = graph[name]
	if not value then
		if not folded then
			folded = {}
			for key, definition in pairs(graph) do
				folded[key:lower()] = definition
			end
		end
		value = folded[name:lower()]
	end
	return value, folded
end

local function resolver(theme, global)
	local resolved, resolving = {}, {}
	local theme_folded, global_folded
	local function inherited(name)
		local key = name:lower()
		if resolved[key] then
			return resolved[key]
		end
		if resolving[key] then
			return {}
		end
		resolving[key] = true
		-- A differently cased source definition still precedes a global one.
		-- These indexes are local to this graph snapshot and built only on misses.
		local value
		value, theme_folded = lookup(theme, name, theme_folded)
		if not value then
			value, global_folded = lookup(global, name, global_folded)
		end
		if not value and name:sub(1, 1) == "@" and name:find("%.") then
			value = inherited((name:gsub("%.[^.]+$", "")))
		elseif value and value.link then
			if value.link:lower() == key then
				value, global_folded = lookup(global, name, global_folded)
				value = vim.deepcopy(value or {})
				value.link = nil
			else
				value = inherited(value.link)
			end
		end
		value = vim.deepcopy(value or {})
		value.default = nil
		resolved[key], resolving[key] = value, nil
		return resolved[key]
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
		local user = user_mappings(util.get_win_option(win, "winhighlight"))
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
	local revision = state.revision
	apply_filler(win, state, style)
	if not current_state(win, state) then
		if windows[win] == state then
			M.release(win)
		end
		return
	end
	if state.revision ~= revision then
		return
	end
	local global = api.nvim_get_hl(0, {})
	local source = state.previous == -1 and api.nvim_get_hl_ns({}) or state.previous
	local theme = source and source > 0 and api.nvim_get_hl(source, {}) or {}
	if state.native and state.previous == -1 and source > 0 then
		state.user = user_mappings(util.get_win_option(win, "winhighlight"))
		write_mapping(win, state.user)
		if not current_state(win, state) or state.revision ~= revision then
			return
		end
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
		state.user = user_mappings(util.get_win_option(win, "winhighlight"))
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
			user[from:lower()] = to
		end
		local inherited = resolver(theme, global)
		local targets = { DiffDelete = "LazyVcsDiffFiller" }
		if state.role == "old" and style.removed then
			targets.DiffAdd = "LazyVcsDiffRemoved"
		elseif user.diffadd then
			-- Explicit namespaces take precedence over winhighlight. Reproduce
			-- the user's addition mapping even on a pane with no color override.
			targets.DiffAdd = "DiffAdd"
		end
		for from, to in pairs(targets) do
			if state.native then
				if not user[from:lower()] then
					state.diff_mappings[from] = aliases[to] or to
				end
			else
				local value = inherited(user[from:lower()] or to)
				if not user[from:lower()] and to == "LazyVcsDiffRemoved" and derived[to] then
					local themed = lookup(theme, to)
					if not (themed and next(themed)) then
						value = inherited("DiffDelete")
					end
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
		if not current_state(win, state) or state.revision ~= revision then
			return
		end
		if state.native_ns <= 0 and next(state.suppressed) then
			write_mapping(win, state.user)
			if not current_state(win, state) or state.revision ~= revision then
				return
			end
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
	local nested_filler_release = state.filler and state.filler.releasing
	invalidate(state)
	release_filler(win, state)
	if windows[win] ~= state then
		return
	end
	local same_buffer = current_state(win, state)
	windows[win] = nil
	if state.native then
		if same_buffer then
			local restore = owned(win, state)
			local user = user_mappings(util.get_win_option(win, "winhighlight"))
			write_mapping(win, user)
			-- Older runtimes stop activating native overlays after restoring inheritance.
			if
				not windows[win]
				and api.nvim_win_is_valid(win)
				and api.nvim_win_get_buf(win) == state.buf
				and restore
				and user == ""
				and vim.version.ge(vim.version(), { 0, 11, 7 })
			then
				restore_namespace(win, state)
			end
		end
	elseif same_buffer and not state.preserved and owned(win, state) then
		restore_namespace(win, state)
	end
	if state.slot then
		state.slot.busy = false
	end
	if not nested_filler_release then
		strip_unowned()
	end
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

-- Clean self-describing private mappings when Neovim restores saved window
-- options, including after the last view closes.
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
		write_filler(win, saved.filler.written)
		if unchanged(win, state, saved, saved.filler.written, saved.suspended_ns, saved.user) then
			write_mapping(win, saved.overlay)
			if unchanged(win, state, saved, saved.filler.written, saved.active_ns, saved.overlay) then
				saved.filler.suspended = nil
				return
			end
		end
	end
	if current_state(win, state) then
		M.refresh(win)
	end
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
			local user = user_mappings(current)
			if local_filler(win) == record.written then
				write_filler(win, record.raw)
			end
			if not current_filler(win, state, record) then
				return
			end
			if current ~= user then
				write_mapping(win, user)
			end
			if not current_filler(win, state, record) then
				return
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

local function listen()
	if group then
		return
	end
	group = api.nvim_create_augroup("LazyVCSDiffHighlighting", { clear = true })
	api.nvim_create_autocmd(
		{ "WinEnter", "WinNew" },
		{ group = group, callback = protected(function()
			strip_unowned()
		end) }
	)
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
	api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "fillchars",
		callback = protected(function()
			if filler_writes > 0 or vim.v.option_command == "setglobal" then
				return
			end
			local win = api.nvim_get_current_win()
			local state = windows[win]
			if state and current_state(win, state) and state.filler then
				-- Equal writes are still explicit local preferences. Session projection
				-- and copied windows must use this latest raw value too.
				state.filler.raw = local_filler(win)
				invalidate(state)
			elseif not state then
				strip_window(win, true)
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
		if current_state(win, state) then
			listen()
		end
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
	if windows[win] and current_state(win, windows[win]) then
		listen()
	end
end

return M
