return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local cases = {}
	local refusal = "SVN patch filenames cannot contain ASCII control bytes"
	local function write(path, bytes)
		local fd = assert(uv.fs_open(path, "w", 384))
		assert(uv.fs_write(fd, bytes, 0) == #bytes)
		assert(uv.fs_close(fd))
	end
	local function read(path)
		local fd = uv.fs_open(path, "r", 438)
		if not fd then
			return nil
		end
		local size = assert(uv.fs_fstat(fd)).size
		local bytes = assert(uv.fs_read(fd, size, 0))
		assert(uv.fs_close(fd))
		return bytes
	end
	local function command(args, cwd)
		return vim.system(args, { cwd = cwd, text = false }):wait(15000)
	end
	local function get(path, opts)
		local out = {}
		require("lazyvcs").patch(vim.tbl_extend("force", opts or {}, {
			path = path,
			on_done = function(text, err)
				out.text, out.err, out.done = text, err, true
			end,
		}))
		ctx.wait_for(function()
			return out.done
		end, "SVN control-name request did not settle", 15000)
		return out
	end
	local function posix()
		if vim.fn.has("win32") == 1 then
			error({
				lazyvcs_skip = "Native control/quote filename fixtures require POSIX; byte-class validation still runs",
			}, 0)
		end
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_svn_control_names_" .. name,
			function()
				local module = require("lazyvcs.backends.patch_svn")
				local original = module.read
				local ok, err = xpcall(fn, function(value)
					return type(value) == "table" and value or debug.traceback(value, 2)
				end)
				module.read = original
				h.cleanup()
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	case("exact_native_ascii_class_and_relative_root", function()
		local validator = require("lazyvcs.backends.patch_svn_filenames")
		local root = h.tempdir() .. "/Unicode caf\195\169"
		for byte = 0, 255 do
			local expected = byte >= 32 and byte ~= 127
			assert(validator.untracked_path({ root = root }, root .. "/leaf" .. string.char(byte)) == expected, byte)
		end
		assert(validator.untracked_path({ root = root .. "\troot" }, root .. "\troot/ordinary"))
	end)
	for _, spec in ipairs({
		{ "tab", "tab\tleaf.txt" },
		{ "lf", "line\nleaf.txt" },
		{ "cr", "cr\rleaf.txt" },
		{ "del", "del\127leaf.txt" },
	}) do
		local label, name = unpack(spec)
		case(label .. "_native_invalid_and_public_refused_before_read", function()
			posix()
			local f = h.make_svn_fixture()
			assert(uv.fs_mkdir(f.root .. "/loose", 448))
			local rel, bytes = "loose/" .. name, "OWNED " .. label .. " " .. vim.fn.sha256(f.root) .. "\nlast"
			write(f.root .. "/" .. rel, bytes)
			local neighbor = assert(read(f.file))
			local native = h.make_svn_fixture()
			assert(uv.fs_mkdir(native.root .. "/native", 448))
			write(native.root .. "/native/" .. name, bytes)
			local added = command({ "svn", "add", "--force", "--", "native" }, native.root)
			assert(added.code == 1 and added.stderr:find("E160005", 1, true), added.stderr)
			if label == "tab" then
				local directory = h.tempdir()
				h.exec({ "svn", "checkout", h.file_url(f.repo), directory .. "/wc" }, directory)
				local nonce = "EXISTING NEIGHBOR " .. vim.fn.sha256(directory) .. "\n"
				write(directory .. "/wc/sample.txt", nonce)
				write(directory .. "/counterfactual.patch", require("lazyvcs.backends.patch_svn").section(rel, bytes))
				local applied = command({ "svn", "patch", directory .. "/counterfactual.patch" }, directory .. "/wc")
				assert(applied.code == 0 and not read(directory .. "/wc/" .. rel), applied.stderr)
				assert(read(directory .. "/wc/loose/tab") == bytes, "native TAB truncation counterfactual changed")
				assert(read(directory .. "/wc/sample.txt") == nonce, "counterfactual touched neighboring contents")
			end
			local reader, reads = require("lazyvcs.backends.patch_svn"), 0
			local original = reader.read
			---@diagnostic disable-next-line: duplicate-set-field
			reader.read = function(...)
				reads = reads + 1
				return original(...)
			end
			local out = get(f.root .. "/loose")
			assert(out.text == nil and out.err == refusal, out.err or "unsupported filename was exported")
			assert(reads == 0, "unsupported file bytes were read before refusal")
			assert(read(f.root .. "/" .. rel) == bytes and read(f.file) == neighbor)
		end)
	end
	for _, spec in ipairs({
		{ "space", "space leaf.txt" },
		{ "quote", 'quote"leaf.txt' },
		{ "unicode", "caf\195\169.txt" },
	}) do
		local label, name = unpack(spec)
		case(label .. "_positive_native_roundtrip", function()
			if label ~= "space" then
				posix()
			end
			local f = h.make_svn_fixture()
			assert(uv.fs_mkdir(f.root .. "/loose", 448))
			local rel, bytes = "loose/" .. name, "Unicode r\195\169sum\195\169\tbody\nDEL\127body\nlast"
			write(f.root .. "/" .. rel, bytes)
			local out = get(f.root .. "/loose")
			assert(out.text and not out.err and not out.text:find("sample.txt", 1, true), out.err)
			local directory = h.tempdir()
			h.exec({ "svn", "checkout", h.file_url(f.repo), directory .. "/wc" }, directory)
			local nonce = "neighbor unchanged\n"
			write(directory .. "/wc/sample.txt", nonce)
			write(directory .. "/valid.patch", out.text)
			local applied = command({ "svn", "patch", directory .. "/valid.patch" }, directory .. "/wc")
			assert(applied.code == 0 and read(directory .. "/wc/" .. rel) == bytes, applied.stderr)
			assert(read(directory .. "/wc/sample.txt") == nonce and read(f.root .. "/" .. rel) == bytes)
		end)
	end
	for _, ignored in ipairs({ false, true }) do
		case(
			ignored and "ignored_controls_do_not_block_ascii_patch" or "omitted_controls_do_not_block_ascii_patch",
			function()
				posix()
				local f = h.make_svn_fixture()
				assert(uv.fs_mkdir(f.root .. "/loose", 448))
				if ignored then
					h.exec({ "svn", "propset", "svn:global-ignores", "*.tmp", "." }, f.root)
				end
				for _, byte in ipairs({ 9, 10, 13, 127 }) do
					write(f.root .. "/loose/leaf" .. string.char(byte) .. ".tmp", "omitted private bytes\n")
				end
				local native = command({ "svn", "diff", "--internal-diff", "--", "." }, f.root)
				assert(native.code == 0, native.stderr)
				local out = get(f.root, { include_untracked = ignored })
				assert(out.text == native.stdout and not out.err, out.err or "excluded filename blocked ASCII output")
				assert(not out.text:find("omitted private bytes", 1, true))
			end
		)
	end
	return cases
end
