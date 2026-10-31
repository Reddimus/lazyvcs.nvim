local Task = require("lazyvcs.backends.task")
local jobs = require("lazyvcs.source_control.jobs")
local util = require("lazyvcs.util")
local M = { max_file_bytes = 1024 * 1024 }

function M.relative(path)
	if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
		return false
	end
	local windows = vim.fn.has("win32") == 1
	local value = windows and path:gsub("\\", "/") or path
	return not value:match("^/")
		and not (windows and value:match("^%a:"))
		and value ~= ".."
		and not value:match("^%.%./")
		and not value:find("/../", 1, true)
		and not value:match("/%.%.$")
end

function M.task(callback)
	return Task.new(callback, {
		cancel_id = function(id)
			jobs.cancel(function(job)
				return job.id == id
			end)
		end,
	})
end

function M.command(task, repo, args, callback, opts)
	if not task:is_active() then
		return
	end
	opts = vim.tbl_extend("force", {
		owner = task,
		timeout_ms = 30000,
		output_limit_bytes = 4 * 1024 * 1024,
		start = function(argv, scheduled, on_exit)
			return util.system_start(argv, vim.tbl_extend("force", scheduled, { text = false }), on_exit)
		end,
	}, opts or {})
	task:add(jobs.command(repo, "comparison", args, opts, function(result, err, raw)
		if not task:is_active() then
			return
		end
		if result and (result.stdout_truncated or result.stderr_truncated) then
			return callback(nil, "Comparison output was truncated; narrow the comparison", raw)
		end
		local stdout = result and result.stdout
		if stdout and args[1] == "svn" and vim.tbl_contains(args, "--xml") and vim.fn.has("win32") == 1 then
			-- Only XML uses text-mode stdout on Windows, including LFs in values.
			-- Undo that translation. Diff and cat write binary value/content bytes.
			stdout = stdout:gsub("\r\n", "\n")
		end
		callback(stdout, err, raw)
	end))
end

local function schedule_read(task, callback)
	vim.schedule(function()
		if not task:is_active() then
			return
		end
		local ok, err = pcall(callback)
		if not ok then
			task:kill()
			util.notify("Comparison read: " .. tostring(err):gsub("%s+", " "), vim.log.levels.ERROR)
		end
	end)
end

function M.read_file(task, path, callback)
	vim.uv.fs_lstat(path, function(err, stat)
		schedule_read(task, function()
			if not task:is_active() then
				return
			end
			if err then
				return callback(nil, err)
			end
			if stat.type == "link" then
				vim.uv.fs_readlink(path, function(link_err, target)
					schedule_read(task, function()
						if task:is_active() then
							callback(target, link_err, "link")
						end
					end)
				end)
				return
			end
			if stat.type ~= "file" then
				return callback(nil, "Directory or submodule; open it to inspect its contents")
			end
			if stat.size > M.max_file_bytes then
				return callback(nil, "File exceeds the 1 MiB preview limit")
			end
			vim.uv.fs_open(path, "r", 0, function(open_err, fd)
				if not fd then
					return schedule_read(task, function()
						if task:is_active() then
							callback(nil, open_err)
						end
					end)
				end
				local ok, request, start_err = pcall(
					vim.uv.fs_read,
					fd,
					M.max_file_bytes + 1,
					0,
					function(read_err, data)
						pcall(vim.uv.fs_close, fd)
						schedule_read(task, function()
							if not task:is_active() then
								return
							end
							if data and #data > M.max_file_bytes then
								return callback(nil, "File exceeds the 1 MiB preview limit")
							end
							callback(data, read_err, "file")
						end)
					end
				)
				if not ok or not request then
					pcall(vim.uv.fs_close, fd)
					schedule_read(task, function()
						callback(nil, ok and start_err or request)
					end)
				end
			end)
		end)
	end)
end

function M.decode_options(path)
	local text = require("lazyvcs.compare_text")
	local resolved = util.canonical_entry_path(path)
	local entry = vim.uv.fs_lstat(path)
	if entry and entry.type == "link" then
		return { fileencodings = vim.o.fileencodings }
	end
	local hint
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if
			vim.api.nvim_buf_is_loaded(buf)
			and util.is_real_file_buffer(buf)
			and util.canonical_entry_path(vim.api.nvim_buf_get_name(buf)) == resolved
		then
			local profile = text.profile(buf)
			if profile then
				hint = { fileencoding = profile.fileencoding }
				break
			end
		end
	end
	return { hint = hint, fileencodings = vim.o.fileencodings }
end

function M.decode_side(result, side, bytes, opts)
	local document, err = require("lazyvcs.compare_text").decode_preview(bytes, opts, M.max_file_bytes)
	if not document then
		return nil, (side == "left" and "Base preview: " or "Saved preview: ") .. err
	end
	result[side], result[side .. "_document"], result[side .. "_bytes"] = document.lines, document, bytes
	result.profile_key = table.concat({
		result.left_document and result.left_document.profile_key or "",
		result.right_document and result.right_document.profile_key or "",
	}, "\0")
	return true
end

-- Immutable snapshots decode legacy encodings while keeping CR and BOM
-- characters visible to hunk comparison. Always retain the original bytes.
function M.snapshot_document(bytes, path, key, opts)
	local text = require("lazyvcs.compare_text")
	local detected =
		text.decode_preview(bytes, vim.tbl_extend("force", M.decode_options(path), opts or {}), M.max_file_bytes)
	local document
	if detected then
		document = text.decode(bytes, {
			fileencoding = detected.encoding,
			fileformat = "unix",
			bomb = false,
			binary = false,
			key = key .. ":" .. detected.encoding,
		}, M.max_file_bytes)
		if document and document.bom then
			-- Snapshot panes compare serialized text. Represent the source BOM as
			-- a character so adding/removing one remains a navigable hunk, even
			-- when the decoded document otherwise contains no text.
			document.lines[1] = "\239\187\191" .. (document.lines[1] or "")
			document.empty = false
		end
	end
	document = document
		or { lines = util.split_lines(bytes), encoding = "utf-8", eol = bytes:sub(-1) == "\n", empty = bytes == "" }
	document.bom = false
	document.profile_key = key .. ":" .. document.encoding
	return document
end

function M.provider(vcs)
	assert(vcs == "git" or vcs == "svn", "Unsupported comparison backend")
	return require("lazyvcs.backends.compare_" .. vcs)
end

return M
