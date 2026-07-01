local util = require("lazyvcs.util")

local M = {
	name = "svn",
}

-- Cache the `svn` executable lookup so a machine without Subversion (the common
-- case — lazyvcs is Git-first) does not spawn a process that throws ENOENT on
-- every session open. backends/init.lua probes every backend for each path, so
-- an unguarded svn call here breaks Git workflows too.
local svn_checked, svn_present = false, false
local function svn_available()
	if not svn_checked then
		svn_checked = true
		svn_present = vim.fn.executable("svn") == 1
	end
	return svn_present
end

local function get_root(path)
	if not svn_available() then
		return nil, "svn executable not found"
	end
	local cwd = vim.fs.dirname(path)
	local result, err = util.system({ "svn", "info", "--show-item", "wc-root", path }, { cwd = cwd })
	if not result then
		return nil, err
	end
	return util.trim(result.stdout)
end

local function is_versioned(path)
	if not svn_available() then
		return false
	end
	local _, err = util.system({ "svn", "info", path }, { cwd = vim.fs.dirname(path) })
	return err == nil
end

local function status_code(path)
	local lines, err = util.system_lines({ "svn", "status", "--depth", "empty", path }, { cwd = vim.fs.dirname(path) })
	if not lines then
		return nil, err
	end
	for _, line in ipairs(lines) do
		if line ~= "" then
			return line:sub(1, 1)
		end
	end
	return " "
end

local function is_added_base_error(err)
	return type(err) == "string" and (err:match("no committed revision") or err:match("no pristine version"))
end

local function uncommitted_blame_lines(path)
	local ok, lines = pcall(vim.fn.readfile, path)
	if not ok then
		return nil, tostring(lines)
	end
	local out = {}
	for _, line in ipairs(lines) do
		out[#out + 1] = "     - - - " .. line
	end
	return out
end

local function load_base_lines(path, root)
	local code, status_err = status_code(path)
	if not code then
		return nil, nil, status_err
	end
	if code == "A" then
		return {}, "EMPTY"
	end

	local lines, load_err = util.system_lines({ "svn", "cat", "-r", "BASE", path }, { cwd = root })
	if not lines then
		if is_added_base_error(load_err) then
			return {}, "EMPTY"
		end
		return nil, nil, load_err
	end
	return lines, "BASE"
end

local function status_label(code)
	return ({
		M = "modified",
		A = "added",
		D = "deleted",
		R = "replaced",
		C = "conflicted",
		["?"] = "untracked",
		["!"] = "missing",
	})[code] or "changed"
end

function M.probe(path)
	local root = get_root(path)
	if not root then
		return nil
	end
	return { root = root }
end

function M.load(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not an SVN working copy"
	end

	local tracked = is_versioned(path)
	---@type string[]
	local base_lines = {}
	local base_label = "EMPTY"

	if tracked then
		local loaded_lines, loaded_label, load_err = load_base_lines(path, root)
		if not loaded_lines then
			return nil, load_err or err
		end
		base_lines = loaded_lines
		base_label = loaded_label or "EMPTY"
	end

	return {
		name = M.name,
		root = root,
		relpath = util.relpath(root, path),
		tracked = tracked,
		base_label = base_label,
		base_lines = base_lines,
		impl = M,
	}
end

function M.revert_hunk()
	return false
end

function M.root(path)
	return get_root(path)
end

function M.is_versioned(path)
	return is_versioned(path)
end

function M.load_base(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not an SVN working copy"
	end

	if not is_versioned(path) then
		return nil, "File is not tracked by SVN"
	end

	local lines, base_label, load_err = load_base_lines(path, root)
	if not lines then
		return nil, load_err
	end
	return {
		root = root,
		relpath = util.relpath(root, path),
		base_label = base_label,
		base_lines = lines,
	}
end

function M.load_base_async(path, on_done)
	if not svn_available() then
		vim.schedule(function()
			on_done(nil, "svn executable not found")
		end)
		return nil
	end

	local cwd = vim.fs.dirname(path)
	util.system_start({ "svn", "info", "--show-item", "wc-root", path }, { cwd = cwd }, function(result, err)
		if err then
			return on_done(nil, err)
		end
		local root = util.trim(result.stdout)
		util.system_start({ "svn", "info", path }, { cwd = cwd }, function(_, tracked_err)
			if tracked_err then
				return on_done(nil, "File is not tracked by SVN")
			end
			util.system_lines_start(
				{ "svn", "status", "--depth", "empty", path },
				{ cwd = vim.fs.dirname(path) },
				function(status_lines, status_err)
					if not status_lines then
						return on_done(nil, status_err)
					end

					local code = " "
					for _, line in ipairs(status_lines) do
						if line ~= "" then
							code = line:sub(1, 1)
							break
						end
					end

					if code == "A" then
						return on_done({
							root = root,
							relpath = util.relpath(root, path),
							base_label = "EMPTY",
							base_lines = {},
						})
					end

					util.system_lines_start(
						{ "svn", "cat", "-r", "BASE", path },
						{ cwd = root },
						function(lines, cat_err)
							if not lines then
								if is_added_base_error(cat_err) then
									return on_done({
										root = root,
										relpath = util.relpath(root, path),
										base_label = "EMPTY",
										base_lines = {},
									})
								end
								return on_done(nil, cat_err)
							end
							on_done({
								root = root,
								relpath = util.relpath(root, path),
								base_label = "BASE",
								base_lines = lines,
							})
						end
					)
				end
			)
		end)
	end)
end

function M.parse_status_lines(lines, root)
	local items = {}
	for _, line in ipairs(lines or {}) do
		local code = line:sub(1, 1)
		if code ~= "" and code ~= " " then
			local path = util.trim(line:sub(9))
			if path ~= "" then
				items[#items + 1] = {
					status = code,
					label = status_label(code),
					path = path,
					absolute_path = root and vim.fs.normalize(root .. "/" .. path) or path,
				}
			end
		end
	end
	return items
end

function M.changed_files(root)
	if not svn_available() then
		return nil, "svn executable not found"
	end

	local lines, err = util.system_lines({ "svn", "status" }, { cwd = root })
	if not lines then
		return nil, err
	end
	return M.parse_status_lines(lines, root)
end

function M.blame_lines(path)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not an SVN working copy"
	end
	if status_code(path) == "A" then
		return uncommitted_blame_lines(path)
	end
	local lines, blame_err = util.system_lines({ "svn", "blame", "-v", path }, { cwd = root })
	if not lines and is_added_base_error(blame_err) then
		return uncommitted_blame_lines(path)
	end
	return lines, blame_err
end

function M.blame_lines_async(path, on_done)
	if not svn_available() then
		vim.schedule(function()
			on_done(nil, "svn executable not found")
		end)
		return {
			kill = function() end,
		}
	end

	local cwd = vim.fs.dirname(path)
	local job = {
		handle = nil,
		cancelled = false,
	}
	function job:kill(signal)
		self.cancelled = true
		if self.handle then
			pcall(self.handle.kill, self.handle, signal or 15)
		end
	end

	job.handle = util.system_start(
		{ "svn", "info", "--show-item", "wc-root", path },
		{ cwd = cwd },
		function(result, err)
			if job.cancelled then
				return
			end
			if err then
				return on_done(nil, err)
			end
			local root = util.trim(result.stdout)
			job.handle = util.system_lines_start(
				{ "svn", "status", "--depth", "empty", path },
				{ cwd = cwd },
				function(status_lines, status_err)
					if job.cancelled then
						return
					end
					if not status_lines then
						return on_done(nil, status_err)
					end

					for _, line in ipairs(status_lines) do
						if line ~= "" and line:sub(1, 1) == "A" then
							local blame, read_err = uncommitted_blame_lines(path)
							return on_done(blame, read_err, root)
						end
					end

					job.handle = util.system_lines_start(
						{ "svn", "blame", "-v", path },
						{ cwd = root },
						function(lines, blame_err)
							if job.cancelled then
								return
							end
							if not lines then
								if is_added_base_error(blame_err) then
									local blame, read_err = uncommitted_blame_lines(path)
									return on_done(blame, read_err, root)
								end
								return on_done(nil, blame_err)
							end
							on_done(lines, nil, root)
						end
					)
				end
			)
		end
	)
	return job
end

function M.parse_blame_entries(lines)
	local out = {}
	for _, line in ipairs(lines or {}) do
		local revision, author, date = line:match("^%s*(%S+)%s+(%S+)%s+(%S+)")
		local uncommitted = revision == "-" and author == "-" and date == "-"
		out[#out + 1] = {
			revision = revision or "-",
			full_revision = revision or "-",
			author = author or "-",
			date = date or "-",
			backend = M.name,
			uncommitted = uncommitted or nil,
		}
	end
	return out
end

function M.parse_blame_metadata(lines, uncommitted_text)
	local out = {}
	for _, entry in ipairs(M.parse_blame_entries(lines)) do
		if entry.uncommitted then
			out[#out + 1] = uncommitted_text or "Uncommitted line"
		else
			out[#out + 1] = string.format("%6s %15s %s", entry.revision, entry.author, entry.date)
		end
	end
	return out
end

function M.line_revision(path, line_number)
	local lines, err = M.blame_lines(path)
	if not lines then
		return nil, err
	end
	local line = lines[line_number]
	if not line then
		return nil, "No blame information for this line"
	end
	local entry = M.parse_blame_entries({ line })[1]
	if not entry or entry.uncommitted then
		return nil, "No committed SVN revision for this line"
	end
	return entry.revision
end

function M.revision_log(path, revision)
	local root, err = get_root(path)
	if not root then
		return nil, err or "Not an SVN working copy"
	end
	local lines, log_err = util.system_lines({ "svn", "log", "-r", tostring(revision), path }, { cwd = root })
	if not lines then
		return nil, log_err
	end
	return lines
end

return M
