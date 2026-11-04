return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local util, svn = require("lazyvcs.util"), require("lazyvcs.backends.svn")
	local cases = {}
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_svn_unicode_roots_" .. name,
			function()
				local start, system = util.system_start, util.system_result
				local ok, err = xpcall(fn, debug.traceback)
				util.system_start, util.system_result = start, system
				h.cleanup()
				assert(ok, err)
			end,
		}
	end
	case("xml_entities_decode_once", function()
		local parser = require("lazyvcs.backends.xml")
		local source = "&#38;lt;&#x26;#38;&amp;lt;"
		local expected = "&lt;&#38;&lt;"
		assert(parser.decode(source) == expected, "XML entities were decoded more than once")
		local entries =
			parser.parse_status('<status><entry path="' .. source .. '"><wc-status item="modified"/></entry></status>')
		assert(entries[1].path == expected, "SVN filename bytes changed while parsing XML")
	end)
	case("copied_addition_retains_its_pristine_comparison", function()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "copy", "sample.txt", "copied.txt" }, f.root)
		local out = {}
		svn.load_diff_target_async(
			{ root = f.root, relpath = "copied.txt", section = "changes", wc_item = "added", change_kind = "added" },
			function(value, err)
				out.value, out.err, out.done = value, err, true
			end
		)
		ctx.wait_for(function()
			return out.done
		end, "copied comparison did not settle", 15000)
		local value = assert(out.value, out.err)
		assert(value.left.bytes == "one\ntwo\nthree\n", "copy history was replaced by an empty base")
		assert(value.right.source.kind == "worktree" and value.right.path == f.root .. "/copied.txt")
		assert(value.presence.left == "present")
	end)
	case("async_blame_reads_working_bytes_without_readfile", function()
		local f = h.make_svn_fixture()
		local readfile = vim.fn.readfile
		local out, sync_reads = {}, 0
		---@diagnostic disable-next-line: duplicate-set-field
		vim.fn.readfile = function(...)
			sync_reads = sync_reads + 1
			return readfile(...)
		end
		local ok, err = xpcall(function()
			svn.blame_lines_async(f.file, function(value, failure)
				out.value, out.err, out.done = value, failure, true
			end, { root = f.root })
			ctx.wait_for(function()
				return out.done
			end, "async blame did not settle", 15000)
			assert(out.value, out.err)
			assert(sync_reads == 0, "async blame used a synchronous unbounded working-file read")
		end, debug.traceback)
		vim.fn.readfile = readfile
		assert(ok, err)
	end)
	case("async_blame_preserves_supplied_text_without_eol_metadata", function()
		local f = h.make_svn_fixture()
		local fs = require("lazyvcs.fs")
		local read = fs.read_file_async
		---@diagnostic disable-next-line: duplicate-set-field
		fs.read_file_async = function()
			error("supplied text was replaced by disk bytes")
		end
		local out = {}
		local ok, err = xpcall(function()
			svn.blame_lines_async(f.file, function(value, failure)
				out.value, out.err, out.done = value, failure, true
			end, { root = f.root, text = { lines = { "one", "unsaved", "three", "extra unsaved line" } } })
			ctx.wait_for(function()
				return out.done
			end, "supplied-text blame did not settle", 15000)
			assert(out.value, out.err)
			assert(#out.value == 4, "supplied text was not used for attribution")
		end, debug.traceback)
		fs.read_file_async = read
		assert(ok, err)
	end)
	local function write(path, bytes)
		local fd = assert(uv.fs_open(path, "w", 384))
		assert(uv.fs_write(fd, bytes, 0) == #bytes)
		assert(uv.fs_close(fd))
	end
	local function read(path)
		local fd = assert(uv.fs_open(path, "r", 438))
		local bytes = assert(uv.fs_read(fd, assert(uv.fs_fstat(fd)).size, 0))
		assert(uv.fs_close(fd))
		return bytes
	end
	local function xml(root, padding)
		root = root:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
		return '<?xml version="1.0" encoding="UTF-8"?>\n<info><entry kind="dir" path="." revision="1"><url>file:///unused</url><repository><root>file:///unused</root><uuid>x</uuid></repository><wc-info><wcroot-abspath>'
			.. root
			.. "</wcroot-abspath><schedule>normal</schedule></wc-info>"
			.. (padding or "")
			.. "</entry></info>\n"
	end
	local function async(path, opts)
		local out = {}
		local task = svn.probe_async(path, function(info, err)
			out.info, out.err, out.done = info, err, true
		end, opts)
		ctx.wait_for(function()
			return out.done
		end, "root discovery did not settle", 15000)
		return out, task
	end
	local function mock(bytes, fields)
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_result = function(args, opts)
			assert(args[1] == "svn" and args[2] == "info")
			assert(args[3] == "--xml" and args[4] == "--" and args[5] == ".", "root probe must use literal cwd XML")
			if opts.stdout then
				opts.stdout(nil, bytes)
			end
			return vim.tbl_extend("force", { code = 0, signal = 0, stdout = bytes, stderr = "" }, fields or {})
		end
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(args, opts, done)
			local result = util.system_result(args, {})
			assert(opts.text == false and opts.timeout > 0)
			vim.schedule(function()
				done(result, nil, result)
			end)
			return { cancel = function() end }
		end
	end
	for index, name in ipairs({ "cafe\204\129-root", "\228\184\173\230\150\135-root" }) do
		for _, reject_absolute in ipairs({ false, true }) do
			case("public_untracked_native_apply_" .. index .. "_" .. tostring(reject_absolute), function()
				local f = h.make_svn_fixture()
				local root = h.tempdir() .. "/" .. name
				assert(uv.fs_rename(f.root, root))
				f.root, f.file = root, root .. "/sample.txt"
				h.exec({ "svn", "propset", "svn:global-ignores", "*.hidden", "." }, root)
				write(root .. "/loose.txt", "ASCII filename owned bytes\n")
				write(root .. "/ignored.hidden", "excluded sibling\n")
				local before = read(f.file)
				local start = util.system_start
				local queries = 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "svn" and (args[2] == "propget" or args[2] == "info") then
						queries = queries + 1
						local operand = args[#args]
						if
							reject_absolute
							and operand:find("[\128-\255]")
							and (operand:sub(1, 1) == "/" or operand:match("^%a:"))
						then
							vim.schedule(function()
								done(nil, "controlled native Unicode operand refusal", { code = 1 })
							end)
							return { cancel = function() end }
						end
					end
					return start(args, opts, done)
				end
				require("lazyvcs.backends").invalidate()
				local out = {}
				require("lazyvcs").patch({
					path = root,
					on_done = function(text, err)
						out.text, out.err, out.done = text, err, true
					end,
				})
				ctx.wait_for(function()
					return out.done
				end, "public Unicode-root patch did not settle", 15000)
				local text = assert(out.text, out.err)
				assert(queries >= 2 and text:find("+ASCII filename owned bytes", 1, true))
				assert(not text:find("excluded sibling", 1, true))
				assert(read(f.file) == before and read(root .. "/loose.txt") == "ASCII filename owned bytes\n")
				local dest = h.tempdir()
				h.exec({ "svn", "checkout", h.file_url(f.repo), dest .. "/wc" }, dest)
				write(dest .. "/root.patch", text)
				h.exec({ "svn", "patch", dest .. "/root.patch" }, dest .. "/wc")
				assert(read(dest .. "/wc/loose.txt") == "ASCII filename owned bytes\n")
				assert(svn.root(root) == util.canonical_path(root))
				assert(assert(async(root).info).root == util.canonical_path(root))
			end)
		end
	end
	case("xml_preserves_exact_root_and_large_record", function()
		local root = h.tempdir() .. "/caf\195\169 & tail"
		assert(uv.fs_mkdir(root, 448))
		local precise = root .. "/ tail \t\r\n"
		local encoded = xml(precise):gsub("<wcroot%-abspath>(.-)</wcroot%-abspath>", function(value)
			return "<wcroot-abspath>"
				.. value:gsub("\t", "&#9;"):gsub("\r", "&#13;"):gsub("\n", "&#10;")
				.. "</wcroot-abspath>"
		end)
		assert(
			require("lazyvcs.backends.xml").wcroot_abspath(encoded) == precise,
			"decoded root whitespace was trimmed"
		)
		mock(xml(root, "<lock><comment>" .. string.rep("x", 20000) .. "</comment></lock>"))
		assert(svn.root(root) == util.canonical_path(root))
		assert(assert(async(root).info).root == util.canonical_path(root))
	end)
	local invalid = {
		{ "missing", '<info><entry kind="dir"><wc-info/></entry></info>\n' },
		{ "incomplete", "<info><entry><wc-info><wcroot-abspath>/tmp</wcroot-abspath></wc-info></entry>\n" },
		{ "malformed", "<info><entry><wc-info><wcroot-abspath>/tmp</wcroot-abspath></entry></wc-info></info>\n" },
		{
			"duplicate",
			"<info><entry><wc-info><wcroot-abspath>/tmp</wcroot-abspath><wcroot-abspath>/other</wcroot-abspath></wc-info></entry></info>\n",
		},
		{ "relative", xml("relative") },
		{ "entity", xml("/tmp/&unknown;"):gsub("&amp;unknown;", "&unknown;") },
		{ "utf8", xml("/tmp/\255") },
		{ "nul", xml("/tmp/a"):gsub("/tmp/a", "/tmp/&#0;") },
		{ "oversized", xml("/tmp", "<comment>" .. string.rep("x", 2 * 1024 * 1024) .. "</comment>") },
	}
	for _, spec in ipairs(invalid) do
		case("rejects_" .. spec[1], function()
			local root = h.tempdir()
			mock(spec[2])
			local value, err = svn.root(root)
			assert(not value and err, "sync accepted invalid XML root: " .. spec[1])
			local out = async(root)
			assert(not out.info and out.err, "async accepted invalid XML root: " .. spec[1])
		end)
	end
	case("truncated_transport_is_not_a_root", function()
		local root = h.tempdir()
		mock(xml(root), { stdout_truncated = true })
		local out = async(root)
		assert(not out.info and out.err)
	end)
	case("cached_root_bypasses_command", function()
		local root = h.tempdir()
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function()
			error("cached root spawned a command")
		end
		local out = async(root, { root = root })
		assert(assert(out.info).root == root)
	end)
	case("canceled_probe_ignores_late_xml", function()
		local root, late, killed, settled = h.tempdir(), nil, false, false
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(_, _, done)
			late = done
			return {
				cancel = function()
					killed = true
				end,
			}
		end
		local task = svn.probe_async(root, function()
			settled = true
		end)
		ctx.wait_for(function()
			return late ~= nil
		end, "probe did not start")
		task:cancel()
		assert(killed)
		assert(late)({ code = 0, stdout = xml(root), stderr = "" })
		vim.wait(30, function()
			return settled
		end, 5)
		assert(not settled)
	end)
	case("native_failure_code_and_deadline_are_preserved", function()
		local root, calls = h.tempdir(), 0
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_result = function(_, opts)
			calls = calls + 1
			if opts.stderr then
				opts.stderr(nil, "W155010: was not found")
			end
			return { code = 87, signal = 0, stdout = "", stderr = "W155010: was not found" }
		end
		local value, err = svn.root(root)
		---@cast err string
		assert(not value and err:find("W155010", 1, true) and calls == 1)
		local timeouts = {}
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(_, opts, done)
			timeouts[#timeouts + 1] = opts.timeout
			if #timeouts == 1 then
				vim.defer_fn(function()
					done(nil, "W155010: was not found", { code = 1 })
				end, 30)
			else
				vim.schedule(function()
					done({ code = 0, stdout = xml(root), stderr = "" })
				end)
			end
			return { cancel = function() end }
		end
		local out = async(root, { timeout_ms = 1000 })
		assert(assert(out.info).root == root)
		assert(#timeouts == 2 and timeouts[2] < timeouts[1] - 10 and timeouts[2] > 0)
	end)
	case("transport_errors_never_become_roots", function()
		local root = h.tempdir()
		for _, code in ipairs({ 124, 127 }) do
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_result = function()
				return { code = code, signal = 0, stdout = "", stderr = "native failure" }
			end
			local value, err = svn.root(root)
			assert(not value and err == "native failure")
		end
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_result = function(_, opts)
			opts.stdout("EIO: synthetic read error", nil)
			return { code = 0, signal = 0, stdout = xml(root), stderr = "" }
		end
		local value, err = svn.root(root)
		---@cast err string
		assert(not value and err:find("incomplete", 1, true))
		---@diagnostic disable-next-line: duplicate-set-field
		util.system_start = function(_, _, done)
			vim.schedule(function()
				done(nil, "native timed out", { code = 124 })
			end)
			return { cancel = function() end }
		end
		local out = async(root)
		assert(not out.info and out.err == "native timed out")
	end)
	case("relative_boundary_protects_leading_dash_and_scope", function()
		local f = h.make_svn_fixture()
		h.exec({ "svn", "mkdir", "--", "-branch@" }, f.root)
		h.exec({ "svn", "propset", "svn:global-ignores", "*.hidden", "--", "-branch@" }, f.root)
		local common = require("lazyvcs.backends.comparison")
		local command, args_seen = common.command, {}
		---@diagnostic disable-next-line: duplicate-set-field
		common.command = function(task, repo, args, cb)
			if args[1] == "svn" then
				args_seen[#args_seen + 1] = args
			end
			return command(task, repo, args, cb)
		end
		local ok, failure = pcall(function()
			local out = {}
			require("lazyvcs.backends.svn_ignore").load(common.task(), { root = f.root }, function(value, err)
				out.value, out.err, out.done = value, err, true
			end, { f.root .. "/-branch" })
			ctx.wait_for(function()
				return out.done
			end, "boundary ignores did not settle", 15000)
			local ignored = assert(out.value, out.err)
			assert(#args_seen == 2 and args_seen[1][#args_seen[1]] == ".@")
			assert(args_seen[2][#args_seen[2] - 1] == "--" and args_seen[2][#args_seen[2]] == "./-branch@")
			assert(ignored(f.root .. "/-branch/a.hidden", "a.hidden"))
			assert(not ignored(f.root .. "/outside/a.hidden", "a.hidden"))
		end)
		common.command = command
		assert(ok, failure)
	end)
	return cases
end
