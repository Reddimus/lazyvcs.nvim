-- Recover SVN's E145001 when a working file has been replaced by a directory.
-- Compare the pinned revision to BASE first, then reconcile only changed paths.
local common = require("lazyvcs.backends.comparison")
local xml = require("lazyvcs.backends.xml")
local util = require("lazyvcs.util")
local M = {}

local function escape(value)
	return (value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

function M.load(task, snapshot, command, done, local_path)
	task:set_deadline(30000, "SVN replacement comparison timed out; narrow the comparison")
	local deadline = vim.uv.hrtime() / 1e6 + 30000
	local candidates, rows, count, bytes = {}, {}, 0, 0
	local function request(args, callback, opts)
		if not task:is_active() then
			return
		end
		local remaining = math.floor(deadline - vim.uv.hrtime() / 1e6)
		if remaining <= 0 then
			return done(nil, "SVN replacement comparison timed out; narrow the comparison")
		end
		command(task, snapshot, args, callback, vim.tbl_extend("force", opts or {}, { timeout_ms = remaining }))
	end
	local function relative(path)
		if path == snapshot.url then
			return "."
		end
		if path:sub(1, #snapshot.url + 1) == snapshot.url .. "/" then
			return (
				path:sub(#snapshot.url + 2):gsub("%%(%x%x)", function(hex)
					return string.char(tonumber(hex, 16))
				end)
			)
		end
		return util.relative_literal_path(local_path(snapshot.root), local_path(path))
	end
	local function candidate(path)
		if not common.relative(path) then
			return nil, "SVN returned a path outside the replacement comparison"
		end
		if not candidates[path] then
			count = count + 1
			if count > 10000 then
				return nil, "SVN replacement comparison exceeded its path limit"
			end
			candidates[path] = {}
		end
		return candidates[path]
	end
	local function emit(path, kind, status)
		if kind ~= "file" and kind ~= "dir" then
			return false, "SVN returned an unsupported comparison node kind"
		end
		local target = snapshot.root .. (path == "." and "" or "/" .. path)
		local row = ('<path kind="%s" item="%s" props="%s">%s</path>'):format(
			kind,
			status,
			status == "deleted" and "none" or "modified",
			escape(target)
		)
		bytes = bytes + #row
		if bytes > 4 * 1024 * 1024 then
			return false, "SVN replacement comparison exceeded its output limit"
		end
		rows[path] = rows[path] and rows[path] .. row or row
		return true
	end
	local function expand(path, before, after, next_path)
		local url = require("lazyvcs.backends.svn_url").append_path(snapshot.url, path)
		local local_target = snapshot.root .. "/" .. path
		local removing = before == "dir"
		local args = removing
				and { "list", "--xml", "--recursive", "-r", snapshot.revision, url .. "@" .. snapshot.revision }
			or { "info", "--xml", "--depth", "infinity", local_target .. "@" }
		request(args, function(raw, err)
			if not raw then
				return done(nil, err)
			end
			for attributes, body in raw:gmatch("<entry%s+([^>]+)>(.-)</entry>") do
				local attrs = xml.attributes(attributes)
				local child
				if removing then
					local name = body:match("<name>(.-)</name>")
					child = name and path .. "/" .. xml.decode(name)
				elseif attrs.path and body:match("<schedule>(.-)</schedule>") ~= "delete" then
					child = relative(attrs.path)
				end
				if child and child ~= path then
					local entry, why = candidate(child)
					if not entry then
						return done(nil, why)
					end
					if not rows[child] then
						local ok, failure = emit(child, attrs.kind, removing and "deleted" or "added")
						if not ok then
							return done(nil, failure)
						end
					end
				end
			end
			next_path()
		end)
	end
	local function reconcile()
		local paths = vim.tbl_keys(candidates)
		table.sort(paths)
		local index = 0
		local visit
		visit = function()
			if not task:is_active() then
				return
			end
			index = index + 1
			local path = paths[index]
			if not path then
				local result = {}
				for _, key in ipairs(vim.fn.sort(vim.tbl_keys(rows))) do
					result[#result + 1] = rows[key]
				end
				return done("<diff><paths>" .. table.concat(result) .. "</paths></diff>")
			end
			if rows[path] then
				return vim.schedule(visit)
			end
			local entry = candidates[path]
			local target = snapshot.root .. (path == "." and "" or "/" .. path)
			vim.uv.fs_lstat(target, function(stat_err, stat)
				vim.schedule(function()
					if not task:is_active() then
						return
					end
					if
						stat_err
						and not tostring(stat_err):match("ENOENT")
						and not tostring(stat_err):match("ENOTDIR")
					then
						return done(nil, stat_err)
					end
					---@type string|false
					local after = stat and (stat.type == "directory" and "dir" or "file") or false
					if
						entry.status == "deleted"
						or entry.status == "missing"
						or entry.status == "unversioned"
						or entry.status == "ignored"
						or entry.status == "external"
					then
						after = false
					end
					local function compare(before)
						local url = require("lazyvcs.backends.svn_url").append_path(snapshot.url, path)
						if before == "file" and after == "file" then
							return request({
								"diff",
								"--summarize",
								"--xml",
								"--old",
								url .. "@" .. snapshot.revision,
								"--new",
								target .. "@",
							}, function(raw, err)
								if not raw then
									return done(nil, err)
								end
								local inner = raw:match("<paths>(.-)</paths>")
								if not inner then
									return done(nil, "Malformed SVN replacement summary")
								end
								bytes = bytes + #inner
								if bytes > 4 * 1024 * 1024 then
									return done(nil, "SVN replacement comparison exceeded its output limit")
								end
								local function retain()
									rows[path] = inner
									visit()
								end
								if
									not inner:find("<path", 1, true)
									or not stat
									or stat.size > common.max_file_bytes
								then
									return retain()
								end
								-- SVN's summary can retain a BASE edit which WORKING undid.
								request(
									{ "cat", "-r", snapshot.revision, url .. "@" .. snapshot.revision },
									function(base)
										if not base then
											return retain()
										end
										common.read_file(task, target, function(current)
											if current ~= base then
												return retain()
											end
											require("lazyvcs.backends.svn_properties").load_directory_maps(
												task,
												snapshot,
												{ relpath = path, status = "M" },
												function(before_props, after_props)
													if
														before_props
														and after_props
														and vim.deep_equal(before_props, after_props)
													then
														rows[path] = ""
														return visit()
													end
													retain()
												end
											)
										end)
									end,
									{ output_limit_bytes = common.max_file_bytes }
								)
							end)
						end
						local function add(kind, status)
							local ok, err = emit(path, kind, status)
							if not ok then
								done(nil, err)
							end
							return ok
						end
						if before == "dir" and after == "dir" then
							if add("dir", "none") then
								visit()
							end
							return
						end
						if before and not add(before, "deleted") then
							return
						end
						if after and not add(after, "added") then
							return
						end
						if before == "dir" or after == "dir" then
							return expand(path, before, after, visit)
						end
						visit()
					end
					if entry.before ~= nil then
						return compare(entry.before)
					end
					if entry.status == "added" then
						return compare(false)
					end
					local url = require("lazyvcs.backends.svn_url").append_path(snapshot.url, path)
					request(
						{ "info", "--xml", "-r", snapshot.revision, url .. "@" .. snapshot.revision },
						function(raw, err)
							local info = raw and xml.parse_info(raw)
							if not info or not info.kind then
								return done(nil, err or "SVN returned no replacement base kind")
							end
							compare(info.kind)
						end
					)
				end)
			end)
		end
		visit()
	end
	request({
		"diff",
		"--summarize",
		"--xml",
		"--old",
		snapshot.url .. "@" .. snapshot.revision,
		"--new",
		snapshot.root .. "@BASE",
	}, function(raw, err)
		if not raw then
			return done(nil, err)
		end
		for attributes, value in raw:gmatch("<path%s+([^>]+)>(.-)</path>") do
			local attrs = xml.attributes(attributes)
			local entry, why = candidate(relative(xml.decode(value)))
			if not entry then
				return done(nil, why)
			end
			if attrs.item ~= "added" then
				entry.before = attrs.kind
			elseif entry.before == nil then
				entry.before = false
			end
		end
		request({ "status", "--xml", "--ignore-externals", snapshot.root .. "@" }, function(status, failure)
			if not status then
				return done(nil, failure)
			end
			for _, item in ipairs(xml.parse_status(status)) do
				local path = relative(item.path)
				if item.wc_item ~= "unversioned" and item.wc_item ~= "ignored" and item.wc_item ~= "external" then
					local entry, why = candidate(path)
					if not entry then
						return done(nil, why)
					end
					entry.status = item.wc_item
				elseif candidates[path] then
					candidates[path].status = item.wc_item
				end
			end
			reconcile()
		end)
	end)
end

return M
