-- Native capability evidence is independent of the public export refusal.
local uv = vim.uv
local M = {}
local function read(path)
	local fd = uv.fs_open(path, "r", 438)
	if not fd then
		return nil
	end
	local stat = assert(uv.fs_fstat(fd))
	local bytes = assert(uv.fs_read(fd, stat.size, 0))
	assert(uv.fs_close(fd))
	return bytes
end
local function write(path, bytes)
	local fd = assert(uv.fs_open(path, "w", 384))
	assert(uv.fs_write(fd, bytes, 0) == #bytes)
	assert(uv.fs_close(fd))
end
local function command(args, cwd)
	local result = vim.system(args, { cwd = cwd, text = false }):wait(15000)
	assert(result.code ~= 124 and (result.signal or 0) == 0, result.stderr)
	return result
end
local function hex(value)
	return (value:gsub(".", function(char)
		return string.format("%02x", char:byte())
	end))
end
function M.check(h, fixture, parent, rel, bytes, out, sample_before)
	assert(out.text == nil and out.err and out.err:find("Windows SVN patch filenames must be ASCII", 1, true), out.err)
	assert(not out.err:find("+Unicode parent bytes", 1, true), "refusal published content")
	assert(read(fixture.root .. "/" .. rel) == bytes, "export changed the source")
	assert(read(fixture.root .. "/sample.txt") == sample_before, "export changed a neighboring file")
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		assert(not vim.api.nvim_buf_get_name(buf):match("^lazyvcs://patch/"), "callback export opened a patch buffer")
	end

	local directory = h.tempdir()
	local destination = directory .. "/applied"
	h.exec({ "svn", "checkout", h.file_url(fixture.repo), destination }, directory)
	local destination_sample = assert(read(destination .. "/sample.txt"))
	local patchfile = directory .. "/utf8.patch"
	write(patchfile, require("lazyvcs.backends.patch_svn").section(rel, bytes))
	local applied = command({ "svn", "patch", patchfile }, destination)
	local correct = read(destination .. "/" .. rel)
	local capability = { parent_hex = hex(parent), apply_code = applied.code, utf8_apply = correct == bytes }
	if correct then
		assert(applied.code == 0 and correct == bytes, "native apply altered content or failed")
	else
		local scanner = assert(uv.fs_scandir(destination))
		local found
		for _ = 1, 8 do
			local name, kind = uv.fs_scandir_next(scanner)
			if not name then
				break
			end
			if kind == "directory" and name ~= ".svn" then
				assert(read(destination .. "/" .. name .. "/leaf @.txt") == bytes, "native applied unexpected content")
				assert(name ~= parent, "native target name and filesystem lookup disagree")
				assert(not found, "native patch widened its scope")
				found, capability.decoded_parent_hex = true, hex(name)
			end
		end
		assert(found or applied.code ~= 0, "native apply returned success without the requested file or decoded target")
	end
	assert(read(destination .. "/sample.txt") == destination_sample, "native capability fixture widened its scope")

	local control = directory .. "/native"
	h.exec({ "svn", "checkout", h.file_url(fixture.repo), control }, directory)
	assert(uv.fs_mkdir(control .. "/" .. parent, 448))
	write(control .. "/" .. rel, bytes)
	write(control .. "/neighbor", "not selected\n")
	local target = require("lazyvcs.util").svn_target
	local status = command({ "svn", "status", "--xml", "--", target(parent) }, control)
	local returned = require("lazyvcs.backends.xml").attributes(status.stdout:match("<target[^>]*>")).path
	assert(returned, "native status omitted its selected target")
	capability.native_target_hex = hex(returned:gsub("\\", "/"))
	local added = command({ "svn", "add", "--", target(parent) }, control)
	capability.native_add_code = added.code
	if added.code == 0 then
		local listed = command({ "svn", "status", "--xml" }, control)
		---@type boolean|nil
		local leaf = false
		local neighbor = false
		local expected = assert(uv.fs_stat(control .. "/" .. rel))
		for _, entry in ipairs(require("lazyvcs.backends.xml").parse_status(listed.stdout)) do
			local actual = entry.wc_item == "added" and uv.fs_stat(control .. "/" .. entry.path) or nil
			leaf = leaf
				or (actual and actual.type == "file" and actual.dev == expected.dev and actual.ino == expected.ino)
			neighbor = neighbor or (entry.path == "neighbor" and entry.wc_item == "unversioned")
		end
		assert(leaf and neighbor, "native add lost the literal file or widened scope")
	else
		assert(added.code == 1 and added.stderr:find("155010", 1, true), added.stderr)
		assert(returned:gsub("\\", "/") ~= parent, "native failure lacks the observed filename-conversion evidence")
	end
	assert(read(control .. "/" .. rel) == bytes and read(control .. "/neighbor") == "not selected\n")
	assert(read(fixture.root .. "/" .. rel) == bytes and read(fixture.root .. "/sample.txt") == sample_before)
	print("PATCH_SVN_NATIVE_FILENAME_CAPABILITY " .. vim.json.encode(capability))
end
return M
