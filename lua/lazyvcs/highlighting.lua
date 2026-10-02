local api = vim.api
local M = {}
local windows, pool = {}, {}
local group

local function owned(win, state)
	return api.nvim_win_is_valid(win) and api.nvim_get_hl_ns({ winid = win }) == state.slot.ns
end

local function semantic(name)
	return name:match("^@lsp%.type%.") or name:match("^@lsp%.mod%.") or name:match("^@lsp%.typemod%.")
end

local function define(slot, name, value)
	api.nvim_set_hl(slot.ns, name, value)
	slot.names[name] = true
end

local function suppress(slot, token, ft)
	local function empty(name)
		for _, qualified in ipairs({ name, name .. "." .. ft }) do
			if not slot.suppressed[qualified] then
				define(slot, qualified, {})
				slot.suppressed[qualified] = true
			end
		end
	end
	empty("@lsp.type." .. token.type)
	for modifier in pairs(token.modifiers or {}) do
		empty("@lsp.mod." .. modifier)
		empty("@lsp.typemod." .. token.type .. "." .. modifier)
	end
end

function M.refresh(win)
	local state = windows[win]
	if not state or not owned(win, state) then
		return
	end
	local slot = state.slot
	slot.suppressed = {}
	local global = api.nvim_get_hl(0, {})
	local resolved = {}
	local function inherited(name)
		if not resolved[name] then
			-- Effective API lookups follow the active window namespace. Resolve raw globals.
			local current, seen, value = name, {}, {}
			while not seen[current] do
				if resolved[current] then
					value = resolved[current]
					break
				end
				seen[current] = true
				value = api.nvim_get_hl(0, { name = current, create = false })
				if not value.link then
					break
				end
				current, value = value.link, {}
			end
			for visited in pairs(seen) do
				resolved[visited] = value
			end
		end
		return resolved[name]
	end
	-- Namespaces cannot delete definitions. Reset pooled names before reuse.
	for name in pairs(slot.names) do
		local fallback = name
		while not global[fallback] and fallback:sub(1, 1) == "@" and fallback:find("%.") do
			fallback = fallback:gsub("%.[^.]+$", "")
		end
		api.nvim_set_hl(slot.ns, name, inherited(fallback))
	end
	local source = state.previous == -1 and api.nvim_get_hl_ns({}) or state.previous
	local theme = source > 0 and api.nvim_get_hl(source, {}) or {}
	local mappings = {}
	for from, to in vim.wo[win].winhighlight:gmatch("([^,:]+):([^,]+)") do
		mappings[from] = to
	end
	local mapped = source > 0 and next(mappings) ~= nil
	for _, ns in pairs(api.nvim_get_namespaces()) do
		if ns == source then
			mapped = false
			break
		end
	end
	for name, value in pairs(theme) do
		if value.link ~= (mappings[name] or name) then
			mapped = false
			break
		end
	end
	if state.mapping_source == nil then
		state.mapping_source = mapped
	end
	-- An explicit namespace overrides winhighlight, so carry its mappings over.
	if state.mapping_source or (source == 0 and state.previous == -1) then
		for from, to in pairs(mappings) do
			define(slot, from, inherited(to))
		end
	else
		for name, value in pairs(theme) do
			define(slot, name, value.link == name and inherited(name) or value)
		end
	end
	for name in pairs(global) do
		if semantic(name) then
			define(slot, name, {})
			slot.suppressed[name] = true
		end
	end
	for name in pairs(theme) do
		if semantic(name) then
			define(slot, name, {})
			slot.suppressed[name] = true
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
	api.nvim_win_set_hl_ns(win, slot.ns)
end

function M.release(win)
	local state = win and windows[win]
	if not state then
		return
	end
	if owned(win, state) then
		if state.mapping_source then
			api.nvim_win_set_hl_ns(win, -1)
			vim.wo[win].winhighlight = vim.wo[win].winhighlight
		else
			api.nvim_win_set_hl_ns(win, state.previous)
		end
	end
	windows[win], state.slot.busy = nil, false
	if not next(windows) and group then
		api.nvim_del_augroup_by_id(group)
		group = nil
	end
end

local function listen()
	if group then
		return
	end
	group = api.nvim_create_augroup("LazyVCSDiffHighlighting", { clear = true })
	local function schedule(win, state, mapping_changed)
		state.mapping_changed = state.mapping_changed or mapping_changed
		if state.pending then
			return
		end
		state.pending = true
		vim.schedule(function()
			state.pending = false
			if windows[win] == state then
				if state.mapping_changed and api.nvim_win_is_valid(win) then
					state.mapping_changed = false
					-- OptionSet runs before Neovim finishes replacing the namespace.
					if not owned(win, state) then
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
		end)
	end
	api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "winhighlight",
		callback = function()
			local win = api.nvim_get_current_win()
			local state = windows[win]
			if state then
				schedule(win, state, true)
			end
		end,
	})
	api.nvim_create_autocmd("WinClosed", {
		group = group,
		callback = function(event)
			M.release(tonumber(event.match))
		end,
	})
	api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(event)
			local release = {}
			for win, state in pairs(windows) do
				if state.buf == event.buf then
					release[#release + 1] = win
				end
			end
			for _, win in ipairs(release) do
				M.release(win)
			end
		end,
	})
	api.nvim_create_autocmd("LspTokenUpdate", {
		group = group,
		callback = function(event)
			local token = event.data and event.data.token
			if not token then
				return
			end
			for win, state in pairs(windows) do
				if owned(win, state) and api.nvim_win_get_buf(win) == event.buf then
					suppress(state.slot, token, vim.bo[event.buf].filetype)
				end
			end
		end,
	})
	api.nvim_create_autocmd({ "ColorScheme", "FileType", "LspAttach", "BufWinEnter" }, {
		group = group,
		callback = function(event)
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
		end,
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
	windows[win] = { slot = slot, previous = api.nvim_get_hl_ns({ winid = win }), buf = api.nvim_win_get_buf(win) }
	api.nvim_win_set_hl_ns(win, slot.ns)
	M.refresh(win)
	listen()
end

return M
