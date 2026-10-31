local process = require("lazyvcs.backends.process")
local util = require("lazyvcs.util")
local M = {}

local function oid(value)
	return value and value:match("^%x+$") and (#value == 40 or #value == 64)
end

-- Capture entries before reading their immutable blobs. Status rows may be stale.
function M.prepare(task, comparison, timeout, callback)
	local root, path = comparison.root, comparison.relpath
	local source = comparison.left and comparison.left.source
	local old_path = comparison.renamed_from
		or (source and source.object and source.object:match("^[^:]+:(.*)$"))
		or path
	local options = { cwd = root, timeout = timeout, output_limit_bytes = 2 * (#old_path + #path + 2048) }
	local result = {}
	local function command(args, done)
		task:add(process.bytes(args, options, function(bytes, err, raw)
			if task:is_active() then
				done(bytes, err, raw)
			end
		end))
	end
	local function index()
		-- Both operands carry their own literal magic. Omit -- so util preserves
		-- the exclusion, bounding output to the exact entry rather than children.
		command(
			{ "git", "ls-files", "--stage", "-z", ":(literal)" .. path, ":(exclude,literal)" .. path .. "/" },
			function(bytes, err)
				if not bytes then
					return callback(nil, err)
				end
				if bytes == "" then
					result.right = false
				else
					local mode, object, stage, entry_path = bytes:match("^(%d+) (%x+) (%d+)\t([^%z]+)%z$")
					if
						entry_path ~= path
						or stage ~= "0"
						or not oid(object)
						or not (mode == "100644" or mode == "100755" or mode == "120000")
					then
						return callback(nil, "Cannot verify exact staged index entry; refresh and retry")
					end
					result.right = { oid = object, object = ":0:" .. path }
				end
				callback(result)
			end
		)
	end
	local function tree(revision)
		command({ "git", "--literal-pathspecs", "ls-tree", "-z", revision, "--", old_path }, function(bytes, err)
			if not bytes then
				return callback(nil, err)
			end
			if bytes == "" then
				result.left = false
			else
				local mode, kind, object, entry_path = bytes:match("^(%d+) (%S+) (%x+)\t([^%z]+)%z$")
				if
					entry_path ~= old_path
					or not oid(object)
					or not (
						kind == "tree" and mode == "040000"
						or kind == "blob" and (mode == "100644" or mode == "100755" or mode == "120000")
					)
				then
					return callback(nil, "Cannot verify exact staged HEAD entry; refresh and retry")
				end
				if kind == "tree" then
					result.left = false
				else
					result.left = { oid = object, object = revision .. ":" .. old_path }
				end
			end
			index()
		end)
	end
	command({ "git", "rev-parse", "--verify", "HEAD^{commit}" }, function(bytes, err)
		local revision = bytes and util.trim(bytes)
		if oid(revision) then
			return tree(revision)
		end
		-- Only an absent symbolic HEAD ref proves an unborn repository. Other
		-- resolution failures must not manufacture an empty historical endpoint.
		command({ "git", "symbolic-ref", "--quiet", "HEAD" }, function(ref)
			ref = ref and util.trim(ref)
			if not ref or not ref:match("^refs/heads/.") then
				return callback(nil, err or "Cannot resolve staged HEAD")
			end
			command({ "git", "show-ref", "--verify", "--quiet", ref }, function(_, why, raw)
				if
					not raw
					or raw.code ~= 1
					or raw.timed_out
					or raw.cancelled
					or (raw.signal or 0) ~= 0
					or raw.stdout_truncated
					or raw.stderr_truncated
				then
					return callback(nil, why or err or "Cannot verify unborn HEAD")
				end
				result.left = false
				index()
			end)
		end)
	end)
end

return M
