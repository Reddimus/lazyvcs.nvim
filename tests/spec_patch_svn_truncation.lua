return function(ctx)
	local h = ctx.helpers
	local validator = require("lazyvcs.backends.patch_svn_filenames")
	local cases = {}
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_svn_truncation_" .. name,
			function()
				local has, collect = vim.fn.has, require("lazyvcs.backends.patch").collect
				local patch = require("lazyvcs.patch")
				local ok, err = xpcall(fn, debug.traceback)
				vim.fn.has, require("lazyvcs.backends.patch").collect = has, collect
				patch._test_output_limit = nil
				h.cleanup()
				assert(ok, err)
			end,
		}
	end
	local function windows_collect(...)
		local has = vim.fn.has
		vim.fn.has = function(name)
			return name == "win32" and 1 or has(name)
		end
		local ok, result = pcall(require("lazyvcs.backends.patch").collect, ...)
		vim.fn.has = has
		assert(ok, result)
		return result
	end
	local function wait(fn)
		ctx.wait_for(fn, "truncated SVN validation did not settle", 15000)
	end
	local function fixture()
		local f = h.make_svn_fixture()
		h.write_file(f.root .. "/sample.txt", string.rep("native ASCII body line\n", 12000))
		return f
	end
	case("native_stream_retains_marker_and_bytes", function()
		local f, out = fixture(), { appends = 0 }
		windows_collect({ vcs = "svn", root = f.root }, f.root, {
			include_untracked = false,
			remaining = function()
				return 1024
			end,
			append = function(text, truncated)
				out.appends, out.text, out.truncated = out.appends + 1, text, truncated
				return false
			end,
		}, function(value, err)
			out.value, out.err, out.done = value, err, true
		end)
		wait(function()
			return out.done
		end)
		assert(out.value and not out.err and out.appends == 1 and out.truncated, out.err)
		assert(out.text:match("\n%.%.%. %[truncated at least [1-9]%d* bytes%]$"), "native transport marker changed")
	end)
	case("public_partial_patch_keeps_documented_marker", function()
		local f = fixture()
		local backend = require("lazyvcs.backends.patch")
		local original = backend.collect
		---@diagnostic disable-next-line: duplicate-set-field
		backend.collect = function(...)
			backend.collect = original
			return windows_collect(...)
		end
		require("lazyvcs.patch")._test_output_limit = 1024
		local out = {}
		require("lazyvcs").patch({
			path = f.root,
			include_untracked = false,
			on_done = function(text, err)
				out.text, out.err, out.done = text, err, true
			end,
		})
		wait(function()
			return out.done
		end)
		assert(out.text and not out.err, out.err)
		assert(out.text:find("+native ASCII body line", 1, true))
		assert(out.text:find("# lazyvcs: output truncated at 16 MiB", 1, true), "public truncation marker absent")
	end)
	local function validate(text, truncated)
		local out = {}
		local task = require("lazyvcs.backends.task").new(function(value, err)
			out.value, out.err, out.done = value, err, true
		end)
		validator.headers({ root = h.tempdir() }, task, text, function(fn)
			return function(...)
				if task:is_active() then
					return fn(...)
				end
			end
		end, function()
			out.published = text
			task:finish(true)
		end, truncated)
		wait(function()
			return out.done
		end)
		return out
	end
	for _, marker in ipairs({ "\n... [truncated 37 bytes]", "\n... [truncated at least 37 bytes]" }) do
		local label = marker:find("at least", 1, true) and "stream" or "fallback"
		case(label .. "_suffix_is_metadata_only_when_flagged", function()
			local text = "Index: sample.txt\n@@ -0,0 +1,20 @@\n+partial body" .. marker
			local out = validate(text, true)
			assert(out.value and not out.err and out.published == text, out.err)
			local unflagged = validate(text, false)
			assert(not unflagged.value and unflagged.err == "Malformed SVN patch hunk")
		end)
		case(label .. "_does_not_skip_unicode_filename_validation", function()
			local out = validate("Index: caf\195\169\n@@ -0,0 +1,20 @@\n+partial" .. marker, true)
			assert(not out.value and out.err == validator.error and not out.published)
		end)
	end
	case("literal_marker_content_remains_hunk_data", function()
		local text = "Index: sample.txt\n@@ -0,0 +1,2 @@\n+... [truncated 37 bytes]\n+... [truncated at least 37 bytes]"
		for _, flagged in ipairs({ false, true }) do
			local out = validate(text, flagged)
			assert(out.value and out.published == text and not out.err, out.err)
		end
	end)
	case("near_markers_are_not_transport_metadata", function()
		for _, marker in ipairs({
			"\n... [truncated at least 0 bytes]",
			"\n... [truncated 37 bytes]\n",
			"\n... [truncated at least 37 bytes] extra",
		}) do
			local out = validate("Index: sample.txt\n@@ -0,0 +1,20 @@\n+body" .. marker, true)
			assert(not out.value and out.err == "Malformed SVN patch hunk")
		end
	end)
	return cases
end
