-- Failure-only diagnostics for owned Patch fixtures; never change product policy.
local uv = vim.uv
local M = {}
local initial = {}
for _, name in ipairs({ "fs_lstat", "fs_open", "fs_fstat", "fs_read", "fs_write", "fs_close", "fs_realpath" }) do
	initial[name] = uv[name]
end
local capability_emitted = false
local function origin(fn)
	local info = debug.getinfo(fn, "S")
	return { what = info.what, source = info.source, line = info.linedefined }
end
local fields = { "type", "dev", "ino", "mode", "size" }
local function bytes(value, limit)
	if value == nil then
		return nil
	end
	value = tostring(value)
	local prefix = value:sub(1, limit or 512)
	return {
		length = #value,
		hex = (prefix:gsub(".", function(char)
			return string.format("%02x", char:byte())
		end)),
		escaped = (prefix:gsub("[^\32-\126]", function(char)
			return string.format("\\x%02x", char:byte())
		end)),
		truncated = #prefix < #value,
	}
end
local function stat(value)
	if not value then
		return nil
	end
	---@type table<string, any>
	local out = { lua_types = {}, rendered = {} }
	for _, key in ipairs(fields) do
		local item = value[key]
		out.lua_types[key] = type(item)
		out[key] = type(item) == "number" and item or tostring(item)
		out.rendered[key] = type(item) == "number" and string.format("%.17g", item) or tostring(item)
	end
	return out
end
local function identified(value)
	return value ~= nil
		and value.type == "file"
		and type(value.dev) == "number"
		and value.dev >= 0
		and type(value.ino) == "number"
		and value.ino > 0
end
local function flags()
	local c = uv.constants
	return {
		O_RDONLY = c.O_RDONLY == nil and "nil" or c.O_RDONLY,
		O_NONBLOCK = c.O_NONBLOCK == nil and "nil" or c.O_NONBLOCK,
		O_NOFOLLOW = c.O_NOFOLLOW == nil and "nil" or c.O_NOFOLLOW,
		lua_types = { O_RDONLY = type(c.O_RDONLY), O_NONBLOCK = type(c.O_NONBLOCK), O_NOFOLLOW = type(c.O_NOFOLLOW) },
		reader = bit.bor(c.O_RDONLY, c.O_NONBLOCK or 0, c.O_NOFOLLOW or 0),
	}
end
local function versions()
	local out =
		{ nvim = vim.version(), luv = uv.version_string(), jit = jit and jit.version or "unavailable", locale = {} }
	for _, name in ipairs({ "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES" }) do
		out.locale[name] = vim.env[name]
	end
	if vim.fn.has("win32") == 1 then
		local ok, result = pcall(function()
			local ffi = require("ffi")
			ffi.cdef([[
				unsigned int __stdcall GetACP(void);
				unsigned int __stdcall GetConsoleCP(void);
				unsigned int __stdcall GetConsoleOutputCP(void);
			]])
			local kernel = ffi.load("kernel32")
			return {
				GetACP = tonumber(kernel.GetACP()),
				GetConsoleCP = tonumber(kernel.GetConsoleCP()),
				GetConsoleOutputCP = tonumber(kernel.GetConsoleOutputCP()),
			}
		end)
		out.windows_codepages = ok and result or { error = bytes(result) }
	end
	return out
end
local function io_read(path)
	local file, err = io.open(path, "rb")
	if not file then
		return { error = bytes(err) }
	end
	local value, reason = file:read(512)
	local closed, close_err = file:close()
	return { bytes = bytes(value), error = bytes(reason), closed = closed, close_error = bytes(close_err) }
end
local function uv_read(path, open_flags)
	local fd, err = uv.fs_open(path, open_flags, 438)
	if not fd then
		return { error = bytes(err) }
	end
	local info, stat_err = uv.fs_fstat(fd)
	local value, read_err = uv.fs_read(fd, 512, 0)
	local closed, close_err = uv.fs_close(fd)
	return {
		fd = fd,
		stat = stat(info),
		stat_error = bytes(stat_err),
		bytes = bytes(value),
		read_error = bytes(read_err),
		closed = closed,
		close_error = bytes(close_err),
	}
end
local function file(path)
	local info, err = uv.fs_lstat(path)
	local out =
		{ path = bytes(path), lstat = stat(info), lstat_error = bytes(err), realpath = bytes(uv.fs_realpath(path)) }
	if info and info.type == "file" then
		out.io = io_read(path)
		out.uv_numeric = uv_read(path, flags().reader)
		out.uv_string = uv_read(path, "r")
	end
	return out
end
local function listing(path, children)
	local request, err = uv.fs_scandir(path)
	local out = { path = bytes(path), error = bytes(err), entries = {} }
	if not request then
		return out
	end
	for _ = 1, 5 do
		local name, kind = uv.fs_scandir_next(request)
		if not name then
			return out
		end
		local item = { name = bytes(name), kind = kind }
		if children and kind == "directory" and name ~= ".svn" and name ~= ".git" then
			item.children = listing(path .. "/" .. name, false)
		elseif not children and kind == "file" then
			item.file = file(path .. "/" .. name)
		end
		out.entries[#out.entries + 1] = item
	end
	out.truncated = true
	return out
end
local function write(path, value)
	local fd = assert(uv.fs_open(path, "w", 384))
	local count, err = uv.fs_write(fd, value, 0)
	local closed, close_err = uv.fs_close(fd)
	assert(count == #value and closed, err or close_err)
end
function M.capability(h)
	if capability_emitted or vim.fn.has("win32") ~= 1 then
		return
	end
	capability_emitted = true
	local ok, value = pcall(function()
		local path = h.tempdir() .. "/patch-native-capability.txt"
		local descriptor = assert(initial.fs_open(path, "w", 384))
		local count, write_err = initial.fs_write(descriptor, "owned capability bytes\n", 0)
		local closed, close_err = initial.fs_close(descriptor)
		assert(count and closed, write_err or close_err)
		local entry, entry_err = initial.fs_lstat(path)
		local fd, open_err = initial.fs_open(path, flags().reader, 438)
		local descriptor_stat, stat_err, close_result, close_error
		if fd then
			descriptor_stat, stat_err = initial.fs_fstat(fd)
			close_result, close_error = initial.fs_close(fd)
		end
		local originals = {}
		for _, name in ipairs({ "fs_lstat", "fs_open", "fs_fstat" }) do
			originals[name] = {
				initial = origin(initial[name]),
				current = origin(uv[name]),
				same_as_initial = initial[name] == uv[name],
			}
		end
		return {
			kind = "Windows-capability",
			mode = "fresh synchronous native sample",
			versions = versions(),
			flags = flags(),
			lstat = stat(entry),
			lstat_error = bytes(entry_err),
			fd = fd,
			open_error = bytes(open_err),
			fstat = stat(descriptor_stat),
			fstat_error = bytes(stat_err),
			closed = close_result,
			close_error = bytes(close_error),
			origins = originals,
			same_identity = entry and descriptor_stat and {
				dev = entry.dev == descriptor_stat.dev,
				ino = entry.ino == descriptor_stat.ino,
			} or nil,
		}
	end)
	M.emit(ok and value or { kind = "Windows-capability", error = bytes(value) })
end
function M.unicode(h, context)
	local out = { kind = "Unicode", context = {}, versions = versions(), flags = flags(), commands = {} }
	for _, name in ipairs({ "vcs", "parent", "rel", "root", "destination", "patchfile", "apply_stdout" }) do
		out.context[name] = bytes(context[name])
	end
	out.patch = bytes(context.result and context.result.text, 1024)
	out.public_error = bytes(context.result and context.result.err)
	out.trace = context.trace
	out.source = file(context.root .. "/" .. context.rel)
	local lexical_parent = vim.fs.dirname(context.root .. "/" .. context.rel)
	local canonical_parent, parent_error = uv.fs_realpath(lexical_parent)
	out.parents = {
		lexical = file(lexical_parent),
		canonical = canonical_parent and file(canonical_parent) or nil,
		canonical_error = bytes(parent_error),
	}
	out.source_listing = listing(context.root, true)
	if context.destination then
		out.destination = file(context.destination .. "/" .. context.rel)
		out.destination_listing = listing(context.destination, true)
	end
	if context.patchfile then
		out.patch_file = file(context.patchfile)
	end
	local deadline = uv.hrtime() + 20000000000
	local function command(label, args, cwd)
		local remaining = math.floor((deadline - uv.hrtime()) / 1000000)
		if remaining <= 0 then
			out.commands[#out.commands + 1] = { label = label, deadline_exceeded = true }
			return nil
		end
		local ok, result = pcall(function()
			return vim.system(args, { cwd = cwd, text = false }):wait(math.min(5000, remaining))
		end)
		local record = { label = label, cwd = bytes(cwd), args = {} }
		for _, arg in ipairs(args) do
			record.args[#record.args + 1] = bytes(arg)
		end
		if ok then
			record.code, record.signal = result.code, result.signal
			record.stdout, record.stderr = bytes(result.stdout), bytes(result.stderr)
		else
			record.error = bytes(result)
		end
		out.commands[#out.commands + 1] = record
		return ok and result or nil
	end
	if context.vcs == "svn" then
		local target = require("lazyvcs.util").svn_target
		command("version", { "svn", "--version", "--quiet" }, context.root)
		command("status-relative", { "svn", "status", "--xml", "--no-ignore", "--", target(context.rel) }, context.root)
		command(
			"status-Unicode-cwd",
			{ "svn", "status", "--xml", "--no-ignore", "--", target("leaf @.txt") },
			context.root .. "/" .. context.parent
		)
		if context.destination then
			command("destination-status", { "svn", "status", "--xml", "--no-ignore" }, context.destination)
		end
		local independent = h.tempdir()
		local repo, wc = independent .. "/repo", independent .. "/wc"
		local made = command("control-create", { "svnadmin", "create", repo }, independent)
		if made and made.code == 0 then
			local checked = command("control-checkout", { "svn", "checkout", h.file_url(repo), wc }, independent)
			if checked and checked.code == 0 then
				vim.fn.mkdir(wc .. "/" .. context.parent)
				write(wc .. "/" .. context.rel, "native base\n")
				local added = command("control-add", { "svn", "add", "--", target(context.parent) }, wc)
				if added and added.code == 0 then
					local committed = command("control-commit", { "svn", "commit", "-m", "Unicode diagnostic" }, wc)
					if committed and committed.code == 0 then
						write(wc .. "/" .. context.rel, "native edited\n")
						local diff = command(
							"control-diff-relative",
							{ "svn", "diff", "--internal-diff", "--", context.rel },
							wc
						)
						command(
							"control-diff-Unicode-cwd",
							{ "svn", "diff", "--internal-diff", "--", "leaf @.txt" },
							wc .. "/" .. context.parent
						)
						if diff and diff.code == 0 then
							local destination = independent .. "/applied"
							local copy = command(
								"control-apply-checkout",
								{ "svn", "checkout", h.file_url(repo), destination },
								independent
							)
							if copy and copy.code == 0 then
								write(independent .. "/native.patch", diff.stdout)
								command(
									"control-native-patch",
									{ "svn", "patch", independent .. "/native.patch" },
									destination
								)
								out.native_destination = file(destination .. "/" .. context.rel)
								out.native_listing = listing(destination, true)
							end
						end
					end
				end
				out.native_source = file(wc .. "/" .. context.rel)
				out.native_source_listing = listing(wc, true)
			end
		end
	end
	return out
end
local function pack(...)
	return { n = select("#", ...), ... }
end
function M.trace()
	local originals, info, events, paths, entries, observation_errors = {}, {}, {}, {}, {}, {}
	local active = true
	local function remember(name, input, err, value, flags_value)
		if not active then
			return
		end
		local event = { operation = name, input = bytes(input), error = bytes(err) }
		if name == "fs_open" then
			event.fd, event.flags = value, flags_value
			if value then
				paths[value] = input
			end
		elseif name == "fs_realpath" then
			event.physical_path = bytes(value)
		else
			event.stat, event.identified = stat(value), identified(value)
			if name == "fs_lstat" and value then
				entries[input] = { type = value.type, dev = value.dev, ino = value.ino }
			elseif name == "fs_fstat" then
				local path = paths[input]
				event.path = bytes(path)
				local entry = path and entries[path]
				if entry and value then
					event.same_as_lstat = {
						type = entry.type == value.type,
						dev = entry.dev == value.dev,
						ino = entry.ino == value.ino,
					}
				end
			end
		end
		events[#events + 1] = event
		if #events > 96 then
			table.remove(events, 1)
		end
	end
	local function observe(...)
		local ok, err = pcall(remember, ...)
		if not ok and #observation_errors < 4 then
			observation_errors[#observation_errors + 1] = bytes(err)
		end
	end
	for _, name in ipairs({ "fs_lstat", "fs_open", "fs_fstat", "fs_realpath" }) do
		local original = uv[name]
		originals[name] = original
		info[name] =
			{ current = origin(original), initial = origin(initial[name]), same_as_initial = original == initial[name] }
		uv[name] = function(...)
			local args = pack(...)
			local input, callback, open_flags = args[1], args[args.n], args[2]
			if type(callback) == "function" then
				args[args.n] = function(err, value, ...)
					observe(name, input, err, value, name == "fs_open" and open_flags or nil)
					return callback(err, value, ...)
				end
			end
			local result = pack(original(unpack(args, 1, args.n)))
			if type(callback) ~= "function" then
				observe(name, input, result[2], result[1], name == "fs_open" and open_flags or nil)
			end
			return unpack(result, 1, result.n)
		end
	end
	return function()
		active = false
		for name, original in pairs(originals) do
			uv[name] = original
		end
		return {
			kind = "reader-metadata",
			versions = versions(),
			flags = flags(),
			originals = info,
			events = events,
			observation_errors = observation_errors,
		}
	end
end
function M.emit(value)
	local ok, encoded = pcall(vim.json.encode, value)
	print(ok and ("PATCH_WINDOWS_DIAGNOSTIC " .. encoded) or ("PATCH_WINDOWS_DIAGNOSTIC_ERROR " .. tostring(encoded)))
end
return M
