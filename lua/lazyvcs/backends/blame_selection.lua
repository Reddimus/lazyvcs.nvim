local Task = require("lazyvcs.backends.task")
local process = require("lazyvcs.backends.process")
local util = require("lazyvcs.util")
local M = {}

function M.load(target, contents, callback)
	local task = Task.new(callback)
	local backends = require("lazyvcs.backends")
	local function load(backend, root)
		local function finish(raw, err)
			if task:is_active() then
				local entries = raw and backend.parse_blame_entries(raw)
				if entries and backend.name == "git" then
					local indexed, index = {}, 0
					for _, line in ipairs(raw) do
						local oid, number = line:match("^(%x+)%s+%d+%s+(%d+)")
						if oid and (#oid == 40 or #oid == 64) then
							index = index + 1
							indexed[tonumber(number)] = entries[index]
						end
					end
					entries = indexed
				end
				task:finish(entries, err)
			end
		end
		local snapshot, item = target.snapshot, target.item
		if not snapshot then
			task:add(
				backend.blame_lines_async(
					target.path,
					finish,
					{ root = root, contents = contents, line_start = target.first, line_end = target.last }
				)
			)
		elseif snapshot.vcs == "git" then
			local base = target.side == "base"
			local revision = base and snapshot.revision or snapshot.head
			local path = base and (item.old_path or item.relpath) or item.relpath
			local function blame(relpath, retry)
				local args = { "git", "blame", "--line-porcelain", "-L", target.first .. "," .. target.last }
				if not base then
					vim.list_extend(args, { "--contents", "-" })
				end
				vim.list_extend(args, { revision, "--", relpath })
				task:add(process.lines(args, { cwd = root, stdin = not base and contents or nil }, function(raw, err)
					if not task:is_active() then
						return
					end
					if not base and not raw and type(err) == "string" and err:find("no such path", 1, true) then
						if item.old_path and not retry then
							return blame(item.old_path, true)
						end
						local entries = {}
						for _ in ipairs(util.split_lines(contents)) do
							entries[#entries + 1] = { uncommitted = true, backend = "git" }
						end
						return task:finish(entries)
					end
					finish(raw, err)
				end))
			end
			blame(path, false)
		elseif target.side == "base" then
			local path = item.relpath:gsub("[^%w%-%._~/]", function(char)
				return string.format("%%%02X", char:byte())
			end)
			local url = snapshot.url .. "/" .. path
			task:add(process.lines({
				"svn",
				"--non-interactive",
				"blame",
				"-v",
				"-r",
				snapshot.revision,
				url .. "@" .. snapshot.revision,
			}, { cwd = root }, finish))
		else
			task:add(
				backend.blame_lines_async(
					target.path,
					finish,
					{ root = root, contents = contents, line_start = target.first, line_end = target.last }
				)
			)
		end
	end
	if target.snapshot then
		load(require("lazyvcs.backends." .. target.snapshot.vcs), target.snapshot.root)
	else
		task:add(backends.resolve_async(target.path, function(backend, root, err)
			if not task:is_active() then
				return
			end
			if not backend then
				return task:finish(nil, err)
			end
			load(backend, root)
		end))
	end
	return task
end
return M
