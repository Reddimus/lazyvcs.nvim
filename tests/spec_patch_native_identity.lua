return function(ctx)
	local fs = require("lazyvcs.file_io")
	local paths = require("lazyvcs.backends.patch_path")
	local cases = {}
	local function wait(fn)
		ctx.wait_for(fn, "Patch native identity did not settle", 15000)
	end
	local function call(fn, ...)
		local done, err, value
		local args = { ... }
		args[#args + 1] = function(reason, result)
			done, err, value = true, reason, result
		end
		fn(unpack(args))
		wait(function()
			return done
		end)
		assert(not err, err)
		return value
	end
	cases[#cases + 1] = {
		"test_patch_native_identity_svn_legacy_walker_avoids_provider",
		function()
			local fixture = ctx.helpers.make_svn_fixture()
			ctx.helpers.write_file(fixture.root .. "/loose", "legacy own bytes\n")
			local original, touched = fs.fs_lstat, false
			---@diagnostic disable-next-line: duplicate-set-field
			fs.fs_lstat = function()
				touched = true
				error("default SVN walker entered the Patch provider")
			end
			local ok, err = xpcall(function()
				local done
				require("lazyvcs.backends.svn_untracked").expand(
					require("lazyvcs.backends.task").new(),
					{ root = fixture.root, vcs = "svn" },
					{ { path = fixture.root .. "/loose", wc_item = "unversioned" } },
					function(files, failure, identities)
						assert(not failure, failure)
						assert(vim.deep_equal(files, { "loose" }) and identities == nil)
						done = true
					end
				)
				wait(function()
					return done
				end)
			end, debug.traceback)
			fs.fs_lstat = original
			assert(ok, err)
			assert(not touched)
		end,
	}
	cases[#cases + 1] = {
		"test_patch_native_identity_exact_tokens_and_type",
		function()
			local entry = {
				identity = "windows-file-id-128",
				dev = "ffffffffffffffff",
				ino = "00000000000000008000000000000001",
				type = "file",
			}
			assert(paths.identified(entry) and paths.same(entry, vim.deepcopy(entry)))
			local different = vim.deepcopy(entry)
			different.ino = "00000000000000008000000000000002"
			assert(not paths.same(entry, different), "large identifiers lost their low bits")
			different = vim.deepcopy(entry)
			different.dev = "fffffffffffffffe"
			assert(not paths.same(entry, different), "volume mismatch was ignored")
			different.identity = nil
			assert(not paths.same(entry, different), "mixed identity sources matched")
			entry.type, entry.directory_reparse = "link", true
			assert(not paths.identified(entry, true), "Git must not accept a directory junction leaf")
			entry.directory_reparse = false
			assert(paths.identified(entry, true) and not paths.identified(entry))
			entry.type = "unsupported-reparse"
			assert(not paths.identified(entry, true), "unknown reparse tags must not become Git file links")
			entry.ino = string.rep("0", 32)
			assert(not paths.identity(entry))
		end,
	}
	for _, kind in ipairs({ "metadata_read_close", "directory_junction", "bounded_handle_lifetime", "shutdown" }) do
		cases[#cases + 1] = {
			"test_patch_native_identity_windows_" .. kind,
			function()
				if vim.fn.has("win32") == 0 then
					error({ lazyvcs_skip = "Win32 HANDLE API requires a native Windows host" }, 0)
				end
				local dir = ctx.helpers.tempdir()
				local path = dir .. "/leaf"
				local fixture_file = assert(io.open(path, "wb"))
				assert(fixture_file:write("native exact\r\nbytes"))
				assert(fixture_file:close())
				if kind == "shutdown" then
					local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
					local script = dir .. "/shutdown.lua"
					ctx.helpers.write_file(
						script,
						string.format(
							[[
vim.opt.runtimepath:prepend(%q)
require("lazyvcs.util")
local fs = require("lazyvcs.file_io")
local handle, failure
fs.fs_open(%q, 0, 0, function(err, value) failure, handle = err, value end)
assert(vim.wait(10000, function() return handle ~= nil or failure ~= nil end, 10))
assert(handle, failure)
local called = false
fs.fs_read(handle, 65536, 0, function() called = true end)
require("lazyvcs.process_runtime").shutdown()
assert(vim.wait(10000, function() return handle.closed and not handle.pending end, 10))
assert(not called, "shutdown published application I/O completion")
fs.fs_lstat(%q, function() called = true end)
vim.wait(30)
assert(not called, "shutdown accepted a new metadata request")
io.stdout:write("NATIVE_PATCH_SHUTDOWN_OK\n")
]],
							root,
							path,
							path
						)
					)
					local result = vim.system(
						{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", script },
						{ text = true }
					):wait(15000)
					assert(result.code == 0 and (result.signal or 0) == 0, result.stderr)
					assert(result.stdout:find("NATIVE_PATCH_SHUTDOWN_OK", 1, true), result.stdout)
					return
				end
				if kind == "directory_junction" then
					local link = dir .. "/junction"
					assert(vim.uv.fs_symlink(dir, link, { junction = true }))
					local entry = call(fs.fs_lstat, link)
					assert(entry.type == "link" and entry.directory_reparse and entry.reparse_tag ~= 0)
					assert(not paths.identified(entry, true), "directory reparse leaf became a Git file")
					assert(vim.uv.fs_rmdir(link))
					return
				end
				local function read_once()
					local initial = call(fs.fs_lstat, path)
					assert(fs.same(initial, fs.fs_lstat(path)), "sync and async metadata used different identities")
					assert(paths.identified(initial) and initial.identity == "windows-file-id-128")
					local handle = call(fs.fs_open, path, 0, 0)
					local ok, err = xpcall(function()
						local opened = call(fs.fs_fstat, handle)
						assert(paths.same(initial, opened), "path and descriptor used different identity domains")
						assert(call(fs.fs_read, handle, 65536, 0) == "native exact\r\nbytes")
					end, debug.traceback)
					assert(call(fs.fs_close, handle))
					assert(handle.closed and not handle.pending)
					assert(ok, err)
				end
				read_once()
				if kind == "bounded_handle_lifetime" then
					local ffi = require("ffi")
					ffi.cdef([[
              void * __stdcall GetCurrentProcess(void);
              int __stdcall GetProcessHandleCount(void *, uint32_t *);
            ]])
					local kernel = ffi.load("kernel32")
					local function count()
						local value = ffi.new("uint32_t[1]")
						assert(kernel.GetProcessHandleCount(kernel.GetCurrentProcess(), value) ~= 0)
						return tonumber(value[0])
					end
					local before = count()
					for _ = 1, 16 do
						read_once()
					end
					assert(count() <= before + 4, "native Patch HANDLEs grew with completed reads")
				end
			end,
		}
	end
	return cases
end
