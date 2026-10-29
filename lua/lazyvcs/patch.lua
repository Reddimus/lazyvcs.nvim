local api = vim.api
local util = require("lazyvcs.util")
local backends = require("lazyvcs.backends")
local Task = require("lazyvcs.backends.task")
local M = {}
local views = {}
local LIMIT = 16 * 1024 * 1024
local MARKER = "# lazyvcs: output truncated at 16 MiB\n"

local function lines(text)
	local result = vim.split(text, "\n", { plain = true })
	if text:sub(-1) == "\n" then
		table.remove(result)
	end
	return result
end

-- Git quotes control bytes even with core.quotepath=false. Decode only for
-- navigation; the displayed and delivered patch bytes are never transformed.
local function git_path(path)
	if path:sub(1, 1) == '"' then
		local escapes =
			{ a = "\a", b = "\b", t = "\t", n = "\n", v = "\v", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\" }
		local decoded, cursor = {}, 2
		while cursor <= #path do
			local char = path:sub(cursor, cursor)
			if char == '"' then
				break
			end
			if char == "\\" then
				local octal = path:sub(cursor + 1, cursor + 3)
				if octal:match("^[0-7][0-7][0-7]$") then
					char, cursor = string.char(tonumber(octal, 8)), cursor + 3
				else
					cursor = cursor + 1
					char = escapes[path:sub(cursor, cursor)] or path:sub(cursor, cursor)
				end
			end
			decoded[#decoded + 1], cursor = char, cursor + 1
		end
		path = table.concat(decoded)
	else
		path = path:gsub("\t.*$", "")
	end
	return path == "/dev/null" and path or path:sub(3)
end

local function git_header_path(header)
	if header:sub(1, 1) == '"' then
		return git_path(header)
	end
	-- Unquoted Git headers may contain spaces. Mode-only changes have the
	-- same path on both sides; find the separator by comparing those paths.
	local cursor = 1
	while true do
		local separator = header:find(" b/", cursor, true)
		if not separator then
			break
		end
		local old, new = header:sub(3, separator - 1), header:sub(separator + 3)
		if old == new then
			return old
		end
		cursor = separator + 1
	end
	return header:match("^a/(.-) b/")
end

local function index_text(text, default_root)
	local rows, hunks, files = {}, {}, {}
	local root, file, hunk = default_root, nil, nil
	local added, deleted = 0, 0
	for number, raw_line in ipairs(lines(text)) do
		local line = raw_line:gsub("\r$", "")
		if line:match("^# Repository: ") then
			root, file, hunk = line:sub(15), nil, nil
		elseif line:match("^diff %-%-git ") or line:match("^Index: ") then
			file = {
				root = root,
				svn = line:match("^Index: ") ~= nil,
				path = line:match("^Index: (.*)$") or git_header_path(line:sub(12)),
				start = number,
				hunks = {},
			}
			files[#files + 1], hunk = file, nil
		elseif file and not hunk and line:match("^rename to ") then
			local name = line:sub(11)
			file.path = name:sub(1, 1) == '"' and git_path(name:gsub('^"', '"b/')) or name
		elseif file and not hunk and line:match("^Binary files ") then
			file.path = line:match(" and b/(.*) differ$") or file.path
		elseif file and not hunk and line:match("^%-%-%- ") then
			file.old = file.svn and file.path or git_path(line:sub(5))
		elseif file and not hunk and line:match("^%+%+%+ ") then
			file.path = file.svn and file.path or git_path(line:sub(5))
		elseif file and line:match("^@@ ") then
			local old, new = line:match("^@@ %-(%d+)[^ ]* %+(%d+)")
			if new then
				hunk = { row = number, line = tonumber(new), old = tonumber(old), offset = 0 }
				file.hunks[#file.hunks + 1], hunks[#hunks + 1] = hunk, number
			end
		elseif hunk then
			local prefix = line:sub(1, 1)
			if prefix == "+" then
				added = added + 1
			end
			if prefix == "-" then
				deleted = deleted + 1
			end
		end
		rows[number] = {
			file = file,
			hunk = hunk,
			line = hunk and math.max(1, hunk.line + hunk.offset) or 1,
			kind = line:sub(1, 1),
		}
		if hunk and number ~= hunk.row and (line:sub(1, 1) == "+" or line:sub(1, 1) == " ") then
			hunk.offset = hunk.offset + 1
		end
	end
	return { rows = rows, hunks = hunks, files = files, added = added, deleted = deleted }
end

local function visible(view)
	if not api.nvim_buf_is_valid(view.buf) then
		return nil
	end
	for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
		if api.nvim_win_is_valid(win) then
			return win
		end
	end
end

local function guard(view, generation, fn)
	return function(...)
		if view.generation ~= generation or not api.nvim_buf_is_valid(view.buf) then
			return
		end
		local ok, err = pcall(fn, ...)
		if not ok then
			util.notify(err, vim.log.levels.ERROR)
		end
	end
end

local function clear_departed_winbars(view)
	local titles = vim.tbl_extend("force", {}, view.winbars)
	vim.schedule(util.safe_callback(function()
		for win, title in pairs(titles) do
			if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= view.buf then
				if api.nvim_win_is_valid(win) and util.get_win_option(win, "winbar") == title then
					util.set_win_option(win, "winbar", "")
				end
				if view.winbars[win] == title then
					view.winbars[win] = nil
				end
			end
		end
	end))
end

local function fill(view, text, loading)
	vim.bo[view.buf].modifiable = true
	api.nvim_buf_set_lines(view.buf, 0, -1, false, lines(text))
	-- Raw patch bytes must survive both :write and yanks, even when the user's
	-- defaults request CRLF, a BOM, or an output encoding.
	vim.bo[view.buf].fileformat = "unix"
	vim.bo[view.buf].fileencoding = ""
	vim.bo[view.buf].bomb = false
	vim.bo[view.buf].endofline = true
	vim.bo[view.buf].fixendofline = false
	vim.bo[view.buf].modified = false
	vim.bo[view.buf].modifiable = false
	local info = view.index or { files = {}, added = 0, deleted = 0 }
	local title = loading and ("PATCH | " .. view.path .. " | LOADING")
		or string.format("PATCH | %s | %d files +%d -%d", view.path, #info.files, info.added, info.deleted)
	title = (title .. " | q close  R reload  Y copy  <CR> file  ]v/[v hunk"):gsub("%%", "%%%%")
	for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do
		util.set_win_option(win, "winbar", title)
		view.winbars[win] = title
	end
end

local function collect(path, opts, done)
	local task = Task.new(util.safe_callback(done))
	local parts, size, truncated, roots = {}, 0, false, {}
	local cap = M._test_output_limit or LIMIT
	local function finish(err)
		local text = table.concat(parts)
		if text ~= "" and text:sub(-1) ~= "\n" then
			text = text .. "\n"
		end
		if truncated then
			text = text .. MARKER
		end
		if err then
			task:finish(nil, err, roots)
		else
			task:finish(text, nil, roots)
		end
	end
	local function checked(fn)
		return function(...)
			if not task:is_active() then
				return
			end
			local ok, result = pcall(fn, ...)
			if not ok then
				finish(tostring(result))
				return false
			end
			return result
		end
	end
	local function append(text, overflow)
		local remaining = cap - size
		if #text > remaining or overflow then
			-- Retain the complete byte prefix. The final marker is outside the
			-- content budget and always starts on its own line.
			parts[#parts + 1] = text:sub(1, remaining)
			size, truncated = cap, true
			return false
		end
		parts[#parts + 1], size = text, size + #text
		return true
	end
	local function repositories(repos, multiple)
		table.sort(repos, function(a, b)
			return a.root < b.root
		end)
		if #repos == 0 then
			return finish("No Git or SVN working copy under " .. path)
		end
		roots = repos
		local number = 0
		local next_repo
		next_repo = checked(function()
			number = number + 1
			local repo = repos[number]
			if not repo or truncated then
				return finish()
			end
			local pending_header = multiple and ("# Repository: " .. repo.root .. "\n") or nil
			task:add(backends.patch_repository_async(
				repo,
				multiple and repo.root or path,
				{
					include_untracked = opts.include_untracked,
					remaining = function()
						return math.max(0, cap - size)
					end,
					append = checked(function(text, overflow)
						-- Clean repositories do not turn an empty patch into nonempty output.
						if text ~= "" and pending_header then
							local header = pending_header
							pending_header = nil
							if not append(header) then
								return false
							end
						end
						return append(text, overflow)
					end),
				},
				checked(function(ok, err)
					if not ok then
						return finish(err)
					end
					next_repo()
				end)
			))
		end)
		next_repo()
	end
	task:add(backends.resolve_async(
		path,
		checked(function(backend, root)
			if backend then
				return repositories({ { root = root, vcs = backend.name } }, false)
			end
			task:add(
				require("lazyvcs.source_control.model").discover_async(
					path,
					require("lazyvcs.config").get().source_control.scan_depth,
					checked(function(repos, err)
						if not repos then
							return finish(err)
						end
						repositories(repos, true)
					end)
				)
			)
		end)
	))
	return task
end

local function position(view)
	local row = view.index and view.index.rows[api.nvim_win_get_cursor(0)[1]]
	return row and row.file and { root = row.file.root, path = row.file.path, line = row.line, kind = row.kind } or nil
end

local function rerun(view)
	if view.task then
		view.task:cancel()
	end
	view.generation = view.generation + 1
	local generation, saved = view.generation, position(view)
	view.text, view.index = nil, nil
	fill(view, "Loading patch for " .. view.path .. "...\n", true)
	view.task = collect(
		view.path,
		view.opts,
		guard(view, generation, function(text, err, repos)
			view.text = text
			view.index = index_text(text or "", repos[1] and repos[1].root)
			fill(view, err or (text == "" and ("No changes under " .. view.path .. "\n") or text))
			if err then
				util.notify(err, vim.log.levels.ERROR)
			end
			local win = visible(view)
			if saved and win then
				local closest, distance
				for row, item in ipairs(view.index.rows) do
					if item.file and item.file.root == saved.root and item.file.path == saved.path then
						local delta = math.abs(item.line - saved.line) * 2 + (item.kind == saved.kind and 0 or 1)
						if not distance or delta < distance then
							closest, distance = row, delta
						end
					end
				end
				if closest then
					api.nvim_win_set_cursor(win, { closest, 0 })
				end
			end
		end)
	)
	return view.task
end

local function open_file(view)
	local item = view.index and view.index.rows[api.nvim_win_get_cursor(0)[1]]
	local file = item and item.file
	if not file or not file.path then
		return
	end
	local rel = file.path == "/dev/null" and file.old or file.path
	local path = rel and util.normalize_literal_path(file.root .. "/" .. rel)
	if not path or not util.relative_literal_path(file.root, path) then
		return
	end
	if not vim.uv.fs_stat(path) then
		return util.notify("Patch file no longer exists: " .. path, vim.log.levels.WARN)
	end
	local editor = require("lazyvcs.editor_target")
	local win = view.editor
	if not (api.nvim_win_is_valid(win) and editor.eligible(win, api.nvim_win_get_tabpage(win))) then
		vim.cmd("belowright new")
		win = api.nvim_get_current_win()
	end
	api.nvim_set_current_win(win)
	util.show_win_buffer(win, vim.fn.bufadd(path))
	vim.fn.bufload(api.nvim_win_get_buf(win))
	api.nvim_win_set_cursor(win, { math.min(item.line, api.nvim_buf_line_count(api.nvim_win_get_buf(win))), 0 })
end

local function mappings(view)
	local function map(key, fn, desc)
		require("lazyvcs.compat").keymap_set(
			"n",
			key,
			util.safe_callback(fn),
			{ buffer = view.buf, silent = true, desc = desc }
		)
	end
	map("q", function()
		vim.cmd.close()
	end, "Close patch")
	map("R", function()
		rerun(view)
	end, "Reload patch")
	map("Y", function()
		if view.text == nil then
			return
		end
		local register = vim.v.register
		vim.fn.setreg(register, view.text == "" and {} or view.text, "V")
		util.notify("Patch copied (" .. (view.text == "" and 0 or #lines(view.text)) .. " lines)")
	end, "Copy whole patch")
	for _, key in ipairs({ "<CR>", "gf" }) do
		map(key, function()
			open_file(view)
		end, "Open patch file")
	end
	for key, direction in pairs({ ["]v"] = 1, ["[v"] = -1 }) do
		map(key, function()
			if not view.index then
				return
			end
			local row, count = api.nvim_win_get_cursor(0)[1], vim.v.count1
			local hunks = direction == 1 and view.index.hunks or vim.fn.reverse(vim.deepcopy(view.index.hunks))
			local target
			for _, hunk in ipairs(hunks) do
				if (hunk - row) * direction > 0 then
					target, count = hunk, count - 1
					if count == 0 then
						break
					end
				end
			end
			if target then
				api.nvim_win_set_cursor(0, { target, 0 })
			end
		end, direction == 1 and "Next patch hunk" or "Previous patch hunk")
	end
end

function M.open(opts)
	opts = vim.tbl_extend("force", {}, opts or {})
	local path = util.canonical_path(opts.path or vim.fn.getcwd())
	if opts.include_untracked == nil then
		opts.include_untracked = require("lazyvcs.config").get().patch.include_untracked
	end
	if opts.on_done then
		return collect(path, opts, opts.on_done)
	end
	local view = views[path]
	local win = view and visible(view)
	if win then
		api.nvim_set_current_win(win)
		view.opts = opts
		return rerun(view)
	end
	local anchor = opts.anchor_winid or api.nvim_get_current_win()
	local destination = require("lazyvcs.editor_target").capture(opts.editor_winid or anchor, anchor)
	-- :new avoids briefly duplicating a wipe-on-hide patch buffer when opening
	-- another view. Use the structured modifiers received from :LazyVCS.
	local mods = vim.tbl_extend("force", {}, opts.smods or {})
	if
		(mods.split == nil or mods.split == "")
		and not mods.vertical
		and not mods.horizontal
		and (mods.tab or -1) < 0
	then
		if destination.fallback then
			mods.tab = 0
		else
			api.nvim_set_current_win(destination.winid)
			mods.split = "aboveleft"
		end
	end
	api.nvim_cmd({ cmd = "new", mods = mods }, {})
	win = api.nvim_get_current_win()
	util.editor_window(win)
	local buf = api.nvim_get_current_buf()
	view = { path = path, buf = buf, editor = destination.winid, opts = opts, generation = 0, winbars = {} }
	views[path] = view
	api.nvim_buf_set_name(buf, "lazyvcs://patch/" .. path)
	vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
	vim.bo[buf].buflisted = false
	vim.bo[buf].filetype = "diff"
	mappings(view)
	api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout", "BufHidden" }, {
		buffer = buf,
		callback = util.safe_callback(function(event)
			clear_departed_winbars(view)
			if event.event == "BufWinLeave" then
				return
			end
			view.generation = view.generation + 1
			if view.task then
				view.task:cancel()
			end
			if views[path] == view then
				views[path] = nil
			end
		end),
	})
	return rerun(view)
end

return M
