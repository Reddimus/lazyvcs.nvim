local backends = require("lazyvcs.backends")
local common = require("lazyvcs.backends.comparison")
local util = require("lazyvcs.util")
local json = require("lazyvcs.json_file")
local M = {}
local sessions = {}

local function state_path()
	return vim.fn.stdpath("state") .. "/lazyvcs/comparisons.json"
end

local function write(buf, lines)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.bo[buf].modifiable, vim.bo[buf].readonly = true, false
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].modified = false, true, false
end

local function display(value)
	return (value:gsub("[%z\1-\31\127]", function(char)
		return string.format("\\x%02x", char:byte())
	end))
end

local function alive(s)
	return not s.closed and vim.api.nvim_tabpage_is_valid(s.tab)
end

local function resize(s)
	if not alive(s) or vim.api.nvim_get_current_tabpage() ~= s.tab then
		return
	end
	local stacked = vim.o.columns < 110
	if stacked ~= s.stacked then
		local focused = vim.api.nvim_get_current_win()
		local right_focused = focused == s.rightwin
		if vim.api.nvim_win_is_valid(s.rightwin) then
			vim.api.nvim_win_close(s.rightwin, true)
		end
		vim.api.nvim_win_call(s.leftwin, function()
			vim.cmd(stacked and "rightbelow split" or "rightbelow vsplit")
			s.rightwin = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(s.rightwin, s.right)
			vim.cmd("diffthis")
			vim.wo.winbar = s.right_label or "SAVED WORKTREE"
		end)
		s.stacked = stacked
		if right_focused then
			vim.api.nvim_set_current_win(s.rightwin)
		end
	end
	local width = math.min(38, math.max(20, math.floor(vim.o.columns / 4)))
	vim.api.nvim_win_set_width(s.sidewin, width)
	if stacked then
		vim.api.nvim_win_set_height(s.leftwin, math.max(3, math.floor((vim.o.lines - 5) / 2)))
	else
		vim.api.nvim_win_set_width(s.leftwin, math.max(10, math.floor((vim.o.columns - width - 2) / 2)))
	end
end

local function cancel(s, field)
	if s[field] then
		s[field]:kill()
		s[field] = nil
	end
end

local function message(s, text)
	if not alive(s) then
		return
	end
	s.message = text
	local lines = {
		"Comparison",
		display(s.base or "Select a base"),
		display(text),
		"R refresh  b base",
		"Enter view  e edit  ? help",
	}
	for _, item in ipairs(s.items or {}) do
		lines[#lines + 1] =
			string.format("%s %s%s", item.status, display(item.relpath), item.properties and " [properties]" or "")
	end
	write(s.sidebar, lines)
end

local function selected(s)
	if not vim.api.nvim_win_is_valid(s.sidewin) then
		return
	end
	return s.items and s.items[vim.api.nvim_win_get_cursor(s.sidewin)[1] - 5]
end

local function file_stamp(path)
	local stat = vim.uv.fs_lstat(path)
	return stat and table.concat({ stat.type, stat.size, stat.mtime.sec, stat.mtime.nsec, stat.mode }, ":") or "missing"
end

local function preview(s)
	local item = selected(s)
	if not item or not s.snapshot then
		return
	end
	cancel(s, "preview_job")
	s.preview_generation = (s.preview_generation or 0) + 1
	local generation = s.preview_generation
	s.preview_result = nil
	local path = s.root .. "/" .. item.relpath
	local stamp = file_stamp(path)
	write(s.left, { "Loading " .. display(item.relpath) .. "..." })
	write(s.right, {})
	s.preview_job = s.provider.preview(s.snapshot, item, function(result, err)
		if not alive(s) or generation ~= s.preview_generation then
			return
		end
		s.preview_job = nil
		if stamp ~= file_stamp(path) then
			result, err = nil, "File changed during preview; press R to refresh"
		end
		if not result then
			write(s.left, vim.list_extend({ "Preview unavailable" }, util.split_lines(tostring(err))))
			write(s.right, {})
			return
		end
		write(s.left, result.left)
		write(s.right, result.right)
		s.preview_result = result
		s.right_label = display(result.right_label):gsub("%%", "%%%%")
		for _, pair in ipairs({ { s.leftwin, result.left_label }, { s.rightwin, result.right_label } }) do
			if vim.api.nvim_win_is_valid(pair[1]) then
				vim.wo[pair[1]].winbar = display(pair[2]):gsub("%%", "%%%%")
			end
		end
		local ft = vim.filetype.match({ filename = path }) or ""
		vim.bo[s.left].filetype, vim.bo[s.right].filetype = ft, ft
		vim.api.nvim_win_call(s.leftwin, function()
			vim.cmd("diffupdate")
		end)
		s.selected_path = path
	end)
end

local function choose_base(s)
	vim.ui.input({
		prompt = s.vcs == "git" and "Comparison base (branch or commit): " or "SVN base URL@revision: ",
		default = s.base or s.context.suggestion or "",
	}, function(value)
		if not alive(s) or not value or value == "" then
			return
		end
		s.base = value
		s.explicit_base = true
		M.refresh(s)
	end)
end

function M.refresh(s, context_checked)
	s = s or sessions[vim.api.nvim_get_current_tabpage()]
	if not s or not alive(s) or not s.provider then
		return
	end
	if not context_checked then
		cancel(s, "job")
		cancel(s, "preview_job")
		s.generation = (s.generation or 0) + 1
		local generation = s.generation
		s.job = s.provider.context(s, function(context, err)
			if not alive(s) or generation ~= s.generation then
				return
			end
			s.job = nil
			if not context then
				return message(s, tostring(err))
			end
			if s.context.branch ~= context.branch and not s.explicit_base then
				s.base = context.branch and json.read(state_path())[s.root .. "\n" .. context.branch] or nil
			end
			s.context = context
			M.refresh(s, true)
		end)
		return
	end
	s.explicit_base = false
	if not s.base then
		return choose_base(s)
	end
	cancel(s, "job")
	cancel(s, "preview_job")
	s.generation = (s.generation or 0) + 1
	s.preview_generation = (s.preview_generation or 0) + 1
	local generation = s.generation
	s.items, s.snapshot = {}, nil
	message(s, "Loading saved changes...")
	write(s.left, {})
	write(s.right, {})
	s.job = s.provider.resolve(s, s.base, function(snapshot, err)
		if not alive(s) or generation ~= s.generation then
			return
		end
		if not snapshot then
			s.job = nil
			return message(s, tostring(err))
		end
		s.job = s.provider.list(snapshot, s.include_untracked, function(items, list_err)
			if not alive(s) or generation ~= s.generation then
				return
			end
			s.job = nil
			if not items then
				return message(s, tostring(list_err))
			end
			s.snapshot, s.items = snapshot, items
			if s.context.branch and s.context.branch ~= "" then
				local saved = json.read(state_path())
				saved[s.root .. "\n" .. s.context.branch] = s.base
				local ok, save_err = json.write(state_path(), saved)
				if not ok then
					util.notify(save_err, vim.log.levels.WARN)
				end
			end
			local added, deleted, unknown = 0, 0, 0
			for _, item in ipairs(items) do
				if item.added and item.deleted then
					added, deleted = added + item.added, deleted + item.deleted
				else
					unknown = unknown + 1
				end
			end
			message(
				s,
				#items == 0 and "No saved changes"
					or string.format(
						"%d paths  +%d -%d%s",
						#items,
						added,
						deleted,
						unknown > 0 and string.format("; %d without line counts", unknown) or ""
					)
			)
			if #items > 0 then
				vim.api.nvim_win_set_cursor(s.sidewin, { 6, 0 })
				preview(s)
			end
		end)
	end)
end

function M.base()
	local s = sessions[vim.api.nvim_get_current_tabpage()]
	if s and s.context then
		choose_base(s)
	else
		M.open()
	end
end

function M.close(s)
	s = s or sessions[vim.api.nvim_get_current_tabpage()]
	if not s then
		return
	end
	s.closed = true
	cancel(s, "job")
	cancel(s, "preview_job")
	sessions[s.tab] = nil
	if vim.api.nvim_tabpage_is_valid(s.tab) then
		pcall(vim.api.nvim_set_current_tabpage, s.tab)
		pcall(vim.cmd.tabclose)
	end
	for _, buf in ipairs({ s.sidebar, s.left, s.right }) do
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
	end
	if vim.api.nvim_win_is_valid(s.origin_win) then
		vim.api.nvim_set_current_win(s.origin_win)
	end
end

local function edit(s)
	local item = selected(s)
	if not item then
		return
	end
	local path = s.root .. "/" .. item.relpath
	if not vim.uv.fs_lstat(path) then
		return message(s, "This path is deleted from the working tree")
	end
	if not vim.api.nvim_win_is_valid(s.origin_win) then
		vim.cmd("tabnew")
		s.origin_win = vim.api.nvim_get_current_win()
	end
	vim.api.nvim_set_current_win(s.origin_win)
	local buf = vim.fn.bufadd(path)
	vim.fn.bufload(buf)
	vim.api.nvim_win_set_buf(s.origin_win, buf)
end

local function help(s)
	write(s.left, {
		"Comparison help",
		"",
		"Enter / double-click: preview selected saved file",
		"e: edit the real file in the original editing window",
		"p: show SVN property changes for the selected file; Enter returns to text",
		"R: refresh and pin the base again",
		"b: choose a base",
		"q: close comparison",
		"",
		"Both preview panes are read-only.",
		"Unsaved buffers are excluded. Save and refresh to include them.",
		"Git compares the common ancestor to the saved worktree.",
		"SVN compares the chosen URL@revision to the saved working copy.",
		"Nonignored untracked files are included by default.",
		"Binary files and files larger than 1 MiB have no text preview.",
	})
	write(s.right, {})
end

function M.open(opts)
	opts = opts or {}
	local existing = sessions[vim.api.nvim_get_current_tabpage()]
	if existing then
		if opts.base then
			existing.base = opts.base
			existing.explicit_base = true
		end
		M.refresh(existing)
		return existing
	end
	local path = opts.path or util.buf_path(vim.api.nvim_get_current_buf()) or vim.fn.getcwd()
	local s = {
		origin_win = vim.api.nvim_get_current_win(),
		base = opts.base,
		include_untracked = opts.include_untracked ~= false,
		items = {},
	}
	vim.cmd("tabnew")
	s.tab, s.sidewin = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
	local function scratch()
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].swapfile = false
		return buf
	end
	s.sidebar, s.left, s.right = scratch(), scratch(), scratch()
	for label, buf in pairs({ files = s.sidebar, base = s.left, saved = s.right }) do
		vim.api.nvim_buf_set_name(buf, "lazyvcs://compare/" .. s.tab .. "/" .. label)
	end
	vim.api.nvim_win_set_buf(s.sidewin, s.sidebar)
	vim.cmd("rightbelow vsplit")
	s.leftwin = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(s.leftwin, s.left)
	vim.cmd("rightbelow vsplit")
	s.rightwin = vim.api.nvim_get_current_win()
	s.stacked = false
	vim.api.nvim_win_set_buf(s.rightwin, s.right)
	for _, win in ipairs({ s.leftwin, s.rightwin }) do
		vim.api.nvim_win_call(win, function()
			vim.cmd("diffthis")
		end)
	end
	vim.api.nvim_win_set_width(s.sidewin, math.min(42, math.max(20, math.floor(vim.o.columns / 4))))
	vim.wo[s.sidewin].winfixwidth = true
	vim.wo[s.sidewin].number, vim.wo[s.sidewin].relativenumber = false, false
	vim.wo[s.sidewin].wrap, vim.wo[s.sidewin].cursorline = false, true
	vim.wo[s.sidewin].signcolumn = "no"
	vim.wo[s.sidewin].statusline = " Comparison  %l/%L"
	sessions[s.tab] = s
	resize(s)
	for _, buf in ipairs({ s.sidebar, s.left, s.right }) do
		for key, fn in pairs({
			q = function()
				M.close(s)
			end,
			R = function()
				M.refresh(s)
			end,
			b = function()
				if s.context then
					choose_base(s)
				end
			end,
			["?"] = function()
				help(s)
			end,
			e = function()
				edit(s)
			end,
			p = function()
				if s.preview_result and s.preview_result.properties then
					write(s.left, {})
					write(s.right, s.preview_result.properties)
					vim.wo[s.rightwin].winbar = "PROPERTY PATCH"
				end
			end,
		}) do
			vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, silent = true })
		end
	end
	vim.keymap.set("n", "<CR>", function()
		preview(s)
	end, { buffer = s.sidebar })
	vim.keymap.set("n", "<2-LeftMouse>", function()
		preview(s)
	end, { buffer = s.sidebar })
	vim.api.nvim_create_autocmd("TabClosed", {
		callback = function()
			if not vim.api.nvim_tabpage_is_valid(s.tab) and not s.closed then
				M.close(s)
				return true
			end
			if s.closed then
				return true
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
		callback = function()
			if s.closed then
				return true
			end
			if alive(s) and vim.api.nvim_win_is_valid(s.leftwin) and vim.api.nvim_win_is_valid(s.sidewin) then
				resize(s)
			end
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		callback = function()
			if s.closed then
				return true
			end
			vim.schedule(function()
				if
					alive(s)
					and (
						not vim.api.nvim_win_is_valid(s.sidewin)
						or not vim.api.nvim_win_is_valid(s.leftwin)
						or not vim.api.nvim_win_is_valid(s.rightwin)
					)
				then
					M.close(s)
				end
			end)
		end,
	})
	vim.api.nvim_set_current_win(s.sidewin)
	message(s, "Finding repository...")
	s.job = backends.resolve_async(path, function(backend, root, err)
		if not alive(s) then
			return
		end
		if not backend then
			s.job = nil
			return message(s, tostring(err))
		end
		s.root, s.vcs, s.provider = root, backend.name, common.provider(backend.name)
		s.job = s.provider.context(s, function(context, context_err)
			if not alive(s) then
				return
			end
			s.job = nil
			if not context then
				return message(s, tostring(context_err))
			end
			s.context = context
			if not s.base and context.branch and context.branch ~= "" then
				s.base = json.read(state_path())[root .. "\n" .. context.branch]
			end
			if s.base then
				M.refresh(s, true)
			else
				choose_base(s)
			end
		end)
	end)
	return s
end

function M._state()
	return sessions[vim.api.nvim_get_current_tabpage()]
end
return M
