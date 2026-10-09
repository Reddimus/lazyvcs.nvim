local compat = require("lazyvcs.compat")
local diff = require("lazyvcs.diff")
local util = require("lazyvcs.util")
local M = {}
local resources = {}
local installed = false
local sequence = 0

local function protected_write(buf, update)
	vim.bo[buf].modifiable, vim.bo[buf].readonly = true, false
	local ok, err = pcall(update)
	vim.bo[buf].modifiable, vim.bo[buf].readonly, vim.bo[buf].modified = false, true, false
	if not ok then
		error(err)
	end
end

local function locked(buf)
	vim.bo[buf].buftype, vim.bo[buf].buflisted, vim.bo[buf].swapfile = "nofile", false, false
	vim.bo[buf].undolevels = -1
	vim.bo[buf].modifiable, vim.bo[buf].readonly = false, true
end

function M.setup()
	if installed then
		return
	end
	installed = true
	local group = vim.api.nvim_create_augroup("lazyvcs_compare_resources", { clear = true })
	vim.api.nvim_create_autocmd("BufReadCmd", {
		group = group,
		pattern = "lazyvcs://compare/*",
		callback = function(args)
			local ok, err = pcall(function()
				local resource = resources[args.buf]
				locked(args.buf)
				if resource and resource.session and not resource.session.closed then
					return resource.session.reload(resource)
				end
				if resource and resource.detached then
					protected_write(args.buf, function()
						vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, resource.lines)
					end)
					return util.notify("This comparison is closed; the snapshot is unchanged", vim.log.levels.INFO)
				end
				protected_write(args.buf, function()
					vim.api.nvim_buf_set_lines(args.buf, 0, -1, false, { "Snapshot no longer available" })
				end)
			end)
			if not ok then
				util.notify("Could not reload snapshot: " .. tostring(err):gsub("[\r\n]+", " "), vim.log.levels.ERROR)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWinLeave", {
		group = group,
		callback = function(args)
			local resource = resources[args.buf]
			if resource and resource.session then
				vim.schedule(function()
					if not resource.session.closed then
						M.trim(resource.session)
					end
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(args)
			resources[args.buf] = nil
		end,
	})
end

function M.scratch()
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "hide"
	locked(buf)
	return buf
end

function M.init(s)
	M.setup()
	sequence = sequence + 1
	s.buffer_id = sequence
	s.buffer_cache = { pairs = {}, count = 0 }
	s.message_left, s.message_right = M.scratch(), M.scratch()
	s.left, s.right = s.message_left, s.message_right
end

function M.swap(s, left, right)
	s.swapping = (s.swapping or 0) + 1
	s.left, s.right = left, right
	local ok, err = pcall(function()
		for _, slot in ipairs({ { s.leftwin, left }, { s.rightwin, right } }) do
			if vim.api.nvim_win_is_valid(slot[1]) and vim.api.nvim_win_get_buf(slot[1]) ~= slot[2] then
				vim.api.nvim_win_call(slot[1], function()
					vim.cmd("keepjumps buffer " .. slot[2])
				end)
			end
		end
	end)
	s.swapping = s.swapping - 1
	if not ok then
		error(err)
	end
end

function M.presentation(s)
	M.swap(s, s.message_left, s.message_right)
end

local function unlink(cache, pair)
	if pair.previous then
		pair.previous.next = pair.next
	else
		cache.first = pair.next
	end
	if pair.next then
		pair.next.previous = pair.previous
	else
		cache.last = pair.previous
	end
	pair.previous, pair.next = nil, nil
end

local function touch(cache, pair)
	if cache.last == pair then
		return
	end
	if pair.previous or pair.next or cache.first == pair then
		unlink(cache, pair)
	end
	pair.previous = cache.last
	if cache.last then
		cache.last.next = pair
	else
		cache.first = pair
	end
	cache.last = pair
end

local function visible(buf)
	return vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0
end

local function discard(s, pair)
	if pair.reload_job then
		pair.reload_job:cancel()
	end
	local cache = s.buffer_cache
	unlink(cache, pair)
	cache.pairs[pair.path], cache.count = nil, cache.count - 1
	for _, buf in ipairs({ pair.left, pair.right }) do
		if vim.api.nvim_buf_is_valid(buf) then
			if visible(buf) then
				resources[buf] = { detached = true, lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false) }
				vim.bo[buf].bufhidden = "wipe"
				for _, mapping in ipairs(s.pane_mappings or {}) do
					pcall(compat.keymap_del, "n", mapping.key, { buffer = buf })
				end
			else
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end
		s.keymaps[buf] = nil
	end
end

function M.trim(s)
	local cache = s.buffer_cache
	local limit = require("lazyvcs.config").get().compare.max_cached_files
	if limit == 0 then
		return
	end
	local pair = cache.first
	while cache.count > limit and pair do
		local next_pair = pair.next
		if
			not pair.reload_job
			and not (s.preview_job and s.shown_item and s.shown_item.relpath == pair.path)
			and not visible(pair.left)
			and not visible(pair.right)
		then
			discard(s, pair)
		end
		pair = next_pair
	end
end

local function escaped(path)
	return (path:gsub("[^%w%._%-]", function(char)
		return string.format("%%%02X", char:byte())
	end))
end

function M.include(fname)
	local resource = resources[vim.api.nvim_get_current_buf()]
	if
		not resource
		or not resource.directory
		or fname:match("^[/\\]")
		or fname:match("^%a:")
		or fname:match("^%a[%w+.-]*://")
	then
		return fname
	end
	local path = vim.fs.normalize(resource.directory .. "/" .. fname)
	return vim.uv.fs_lstat(path) and path or fname
end

local function source_context(buf, resource)
	local prefix = vim.fn.escape(resource.directory, " ,;\\") .. ","
	if vim.bo[buf].path:sub(1, #prefix) ~= prefix then
		vim.bo[buf].path = prefix .. vim.bo[buf].path
	end
	if vim.bo[buf].includeexpr == "" then
		vim.bo[buf].includeexpr = "v:lua.require'lazyvcs.compare_buffers'.include(v:fname)"
	end
end

local function update(buf, lines)
	lines = #lines == 0 and { "" } or lines
	local current = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	if vim.deep_equal(current, lines) then
		return
	end
	local hunks = diff.compute_hunks(current, lines)
	protected_write(buf, function()
		for i = #hunks, 1, -1 do
			local hunk = hunks[i]
			local start = hunk.base_count == 0 and hunk.base_start or hunk.base_start - 1
			vim.api.nvim_buf_set_lines(
				buf,
				start,
				start + hunk.base_count,
				false,
				util.slice(lines, hunk.current_start, hunk.current_count)
			)
		end
	end)
end

function M.store(s, item, result)
	local cache = s.buffer_cache
	local pair = cache.pairs[item.relpath]
	if not pair or not vim.api.nvim_buf_is_valid(pair.left) or not vim.api.nvim_buf_is_valid(pair.right) then
		if pair then
			discard(s, pair)
		end
		pair = { path = item.relpath, old_path = item.old_path, left = M.scratch(), right = M.scratch() }
		cache.pairs[item.relpath], cache.count = pair, cache.count + 1
		for _, side in ipairs({
			{ "base", pair.left, item.old_path or item.relpath },
			{ "saved", pair.right, item.relpath },
		}) do
			vim.api.nvim_buf_set_name(
				side[2],
				"lazyvcs://compare/" .. s.buffer_id .. "/" .. side[1] .. "/" .. escaped(item.relpath)
			)
			local resource =
				{ session = s, pair = pair, side = side[1], directory = vim.fs.dirname(s.root .. "/" .. side[3]) }
			resources[side[2]] = resource
			vim.bo[side[2]].filetype = vim.filetype.match({ filename = s.root .. "/" .. side[3] }) or ""
			source_context(side[2], resource)
			s.keymaps[side[2]] = s.pane_mappings
		end
	end
	update(pair.left, result.left)
	update(pair.right, result.right)
	touch(cache, pair)
	return pair
end

function M.context(buf)
	local resource = resources[buf]
	if resource and resource.directory then
		source_context(buf, resource)
	end
end

function M.resource(buf)
	return resources[buf]
end

function M.reconcile(s, snapshot, items)
	local identity = { snapshot.vcs, snapshot.root, snapshot.revision, snapshot.url or "" }
	local changed = s.buffer_identity and not vim.deep_equal(s.buffer_identity, identity)
	s.buffer_identity = identity
	local paths = {}
	for _, item in ipairs(items) do
		paths[item.relpath] = item
	end
	local pair = s.buffer_cache.first
	while pair do
		local next_pair = pair.next
		local item = paths[pair.path]
		if changed or not item or item.old_path ~= pair.old_path then
			if s.left == pair.left or s.right == pair.right then
				M.presentation(s)
			end
			discard(s, pair)
		end
		pair = next_pair
	end
end

function M.close(s)
	local pair = s.buffer_cache.first
	while pair do
		local next_pair = pair.next
		discard(s, pair)
		pair = next_pair
	end
	for _, buf in ipairs({ s.message_left, s.message_right }) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_buf_delete(buf, { force = true })
		end
	end
end

return M
