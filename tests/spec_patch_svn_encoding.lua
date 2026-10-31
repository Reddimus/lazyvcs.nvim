return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local cases = {}
	local message = "Windows SVN patch filenames must be ASCII"
	local function write(path, text)
		local fd = assert(uv.fs_open(path, "w", 384))
		assert(uv.fs_write(fd, text, 0) == #text)
		assert(uv.fs_close(fd))
	end
	local function native_diff(root)
		local result = vim.system({ "svn", "diff", "--internal-diff", "--", "." }, { cwd = root, text = false })
			:wait(15000)
		assert(result.code == 0 and (result.signal or 0) == 0, result.stderr)
		return result.stdout
	end
	local function collect(f, path, raw, include_untracked)
		local has, system = vim.fn.has, vim.system
		if raw then
			vim.system = function(args, opts, exit)
				if args[1] == "svn" and vim.tbl_contains(args, "diff") then
					opts.stdout(nil, raw)
					exit({ code = 0, signal = 0 })
					return { kill = function() end }
				end
				return system(args, opts, exit)
			end
		end
		-- Capture only this request's policy; native child execution retains its OS.
		vim.fn.has = function(feature)
			return feature == "win32" and 1 or has(feature)
		end
		local parts, done, value, failure = {}, false, nil, nil
		local ok, task = pcall(require("lazyvcs.backends.patch").collect, { vcs = "svn", root = f.root }, path, {
			include_untracked = include_untracked ~= false,
			remaining = function()
				return 16 * 1024 * 1024
			end,
			append = function(text)
				parts[#parts + 1] = text
				return true
			end,
		}, function(result, err)
			value, failure, done = result, err, true
		end)
		vim.fn.has = has
		assert(ok, task)
		ctx.wait_for(function()
			return done
		end, "SVN filename policy did not settle", 15000)
		vim.system = system
		return value and table.concat(parts) or nil, failure, parts
	end
	local function refusal(f, path, raw)
		local text, err, parts = collect(f, path, raw)
		assert(not text and err and err:find(message, 1, true), err or "unsafe filename was published")
		for _, part in ipairs(parts) do
			assert(
				not part:find("caf\195\169", 1, true) and not part:find("+owned bytes", 1, true),
				"unsupported file bytes reached append"
			)
		end
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_svn_encoding_" .. name,
			function()
				local has, system = vim.fn.has, vim.system
				local ok, err = xpcall(fn, debug.traceback)
				vim.fn.has, vim.system = has, system
				h.cleanup()
				assert(ok, err)
			end,
		}
	end
	case("selected_operand_refused", function()
		local f = h.make_svn_fixture()
		write(f.root .. "/caf\195\169", "owned bytes\n")
		refusal(f, f.root .. "/caf\195\169")
	end)
	case("native_status_filename_refused", function()
		local f = h.make_svn_fixture()
		write(f.root .. "/caf\195\169", "owned bytes\n")
		refusal(f, f.root)
	end)
	case("expanded_untracked_filename_refused", function()
		local f = h.make_svn_fixture()
		vim.fn.mkdir(f.root .. "/loose")
		write(f.root .. "/loose/caf\195\169", "owned bytes\n")
		refusal(f, f.root)
	end)
	for _, header in ipairs({
		"Index: caf\195\169\n",
		"--- caf\195\169\t(revision 1)\n",
		"+++ caf\195\169\t(working copy)\n",
		"Property changes on: caf\195\169\n",
	}) do
		case("native_header_" .. #cases, function()
			local f = h.make_svn_fixture()
			refusal(f, f.root, "Index: sample.txt\n" .. header)
		end)
	end
	case("omitted_untracked_unicode_does_not_block_ascii_patch", function()
		local f = h.make_svn_fixture()
		write(f.root .. "/caf\195\169", "not selected\n")
		local native = native_diff(f.root)
		local text, err = collect(f, f.root, nil, false)
		assert(text == native, err or "omitted untracked filename blocked tracked output")
	end)
	case("ignored_unicode_does_not_block_ascii_patch", function()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "propset", "svn:ignore", "caf\195\169", "." }, f.root)
		write(f.root .. "/caf\195\169", "ignored bytes\n")
		local native = native_diff(f.root)
		local text, err = collect(f, f.root)
		assert(text == native, err or "ignored filename blocked tracked output")
		---@cast text string
		assert(not text:find("+ignored bytes", 1, true))
	end)
	case("external_unicode_does_not_block_ascii_patch", function()
		local f, external = h.make_svn_fixture(), h.make_svn_fixture()
		h.exec({ "svn", "propset", "svn:externals", h.file_url(external.repo) .. " caf\195\169", "." }, f.root)
		h.exec({ "svn", "update" }, f.root)
		write(f.root .. "/caf\195\169/private.txt", "external private bytes\n")
		local native = native_diff(f.root)
		local text, err = collect(f, f.root)
		assert(text == native, err or "excluded external filename blocked tracked output")
		---@cast text string
		assert(not text:find("external private bytes", 1, true))
	end)
	case("ascii_filename_preserves_unicode_content_and_properties", function()
		local f = h.make_svn_fixture()
		local body = "++ r\195\169sum\195\169\n-- caf\195\169\nIndex: caf\195\169\nProperty changes on: caf\195\169\n"
		write(f.root .. "/sample.txt", body)
		h.exec({ "svn", "propset", "custom:unicode", body, "sample.txt" }, f.root)
		local native = native_diff(f.root)
		write(f.root .. "/loose.txt", body)
		local text, err = collect(f, f.root)
		assert(
			text == native .. require("lazyvcs.backends.patch_svn").section("loose.txt", body),
			err or "content or property bytes changed"
		)
		local directory = h.tempdir()
		h.exec({ "svn", "checkout", h.file_url(f.repo), directory .. "/wc" }, directory)
		write(directory .. "/content.patch", text)
		h.exec({ "svn", "patch", directory .. "/content.patch" }, directory .. "/wc")
		local fd = assert(uv.fs_open(directory .. "/wc/loose.txt", "r", 438))
		assert(uv.fs_read(fd, #body, 0) == body, "native apply changed Unicode content")
		assert(uv.fs_close(fd))
		---@cast text string
		assert(text:find("+++ r\195\169sum\195\169", 1, true))
		assert(text:find("## ", 1, true), "native property hunk absent")
	end)
	case("unicode_repository_root_is_not_a_filename", function()
		local f = h.make_svn_fixture()
		local root = h.tempdir() .. "/caf\195\169-root"
		assert(uv.fs_rename(f.root, root))
		f.root = root
		write(f.root .. "/sample.txt", "ASCII path; Unicode content caf\195\169\n")
		local native = native_diff(f.root)
		local text, err = collect(f, f.root)
		assert(text == native, err or "Unicode root was rejected")
	end)
	for index, parent in ipairs({ "caf\195\169", "cafe\204\129" }) do
		case("native_capability_control_" .. index, function()
			local f = h.make_svn_fixture()
			local rel, bytes = parent .. "/leaf @.txt", "Unicode parent bytes\nlast"
			assert(uv.fs_mkdir(f.root .. "/" .. parent, 448))
			write(f.root .. "/" .. rel, bytes)
			write(f.root .. "/sample.txt", "neighbor snapshot\n")
			local text, err = collect(f, f.root .. "/" .. rel)
			require("patch_svn_encoding_controls").check(
				h,
				f,
				parent,
				rel,
				bytes,
				{ text = text, err = err },
				"neighbor snapshot\n"
			)
		end)
	end
	case("header_batches_cancel_without_publication", function()
		local task = require("lazyvcs.backends.task").new(function()
			error("canceled header validation settled")
		end)
		local calls, done = 0, false
		local text = "Index: sample.txt\n@@ -0,0 +1,9000 @@\n" .. string.rep("+Unicode caf\195\169\n", 9000)
		require("lazyvcs.backends.patch_svn_filenames").headers({ root = h.tempdir() }, task, text, function(fn)
			return function(...)
				if task:is_active() then
					calls = calls + 1
					fn(...)
					if calls == 1 then
						task:cancel()
					end
				end
			end
		end, function()
			done = true
		end)
		ctx.wait_for(function()
			return calls == 1
		end, "header batch was not visited")
		vim.wait(30)
		assert(task.cancelled and not done and calls == 1, "late header batch published after cancellation")
	end)
	return cases
end
