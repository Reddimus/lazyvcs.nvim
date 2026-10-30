return function(ctx)
	local h = ctx.helpers
	local git = require("lazyvcs.backends.compare_git")
	local svn = require("lazyvcs.backends.compare_svn")
	local oid = string.rep("a", 40)
	local function await(start)
		local done, value, failure
		start(function(result, err)
			done, value, failure = true, result, err
		end)
		ctx.wait_for(function()
			return done
		end, "CRLF output did not load")
		return assert(value, failure)
	end
	-- Feed bytes through the real capture layer, including a CRLF split across chunks.
	local function with_output(output, check, windows)
		local system, has = vim.system, vim.fn.has
		if windows ~= nil then
			---@diagnostic disable-next-line: duplicate-set-field
			vim.fn.has = function(feature)
				return feature == "win32" and (windows and 1 or 0) or has(feature)
			end
		end
		---@diagnostic disable-next-line: duplicate-set-field
		vim.system = function(args, opts, exit)
			local bytes, code = output(args)
			if not bytes then
				return system(args, opts, exit)
			end
			local split = bytes:find("\r\n", 1, true) or #bytes
			local stream = code and code ~= 0 and opts.stderr or opts.stdout
			stream(nil, bytes:sub(1, split))
			stream(nil, bytes:sub(split + 1))
			exit({ code = code or 0 })
			return { kill = function() end }
		end
		local ok, err = xpcall(check, debug.traceback)
		vim.system, vim.fn.has = system, has
		assert(ok, err)
	end
	local function clean(lines, expected)
		assert(vim.deep_equal(lines, expected), "CRLF lines were not decoded: " .. vim.inspect(lines))
		for _, line in ipairs(lines) do
			assert(not line:find("\r", 1, true), "Display line kept a carriage return")
		end
	end
	local function snapshot(root)
		return { root = root, vcs = "git", base = "main", revision = oid }
	end
	local function compare_error(command, expected)
		local f = h.make_git_fixture()
		local compare = require("lazyvcs.compare")
		local session
		local ok, err = xpcall(function()
			with_output(function(args)
				if vim.tbl_contains(args, command) then
					return "first\r\nsecond\r\n", 1
				end
			end, function()
				session = assert(compare.open({ editable = false, path = f.root, base = "HEAD" }))
				ctx.wait_for(function()
					return table.concat(vim.api.nvim_buf_get_lines(session.left, 0, -1, false)):find("first", 1, true)
				end, "CRLF error pane did not load", 15000)
				clean(vim.api.nvim_buf_get_lines(session.left, 0, -1, false), expected)
			end)
		end, debug.traceback)
		if session then
			compare.close(session)
		end
		assert(ok, err)
	end
	return {
		{
			"test_svn_compare_crlf_info_urls",
			function()
				local url = "file:///repo/trunk"
				local raw = '<info>\r\n<entry revision="2" kind="dir" path=".">\r\n<url>'
					.. url
					.. "</url>\r\n<repository><root>file:///repo</root></repository>\r\n</entry>\r\n</info>\r\n"
				with_output(function()
					return raw
				end, function()
					local context = await(function(done)
						svn.context({ root = h.tempdir() }, done)
					end)
					assert(context.branch == url and context.suggestion == url .. "@2")
					local resolved = await(function(done)
						svn.resolve({ root = h.tempdir() }, url .. "@2", done)
					end)
					assert(resolved.url == url and resolved.revision == "2")
				end)
				-- parse_info preserves text inside tags; CRLF after </url> is outside the URL.
				local embedded = raw:gsub("</url>", "\r</url>")
				assert(require("lazyvcs.backends.xml").parse_info(embedded).url == url .. "\r")
			end,
		},
		{
			"test_svn_compare_crlf_optional_property_error",
			function()
				local root = h.tempdir()
				h.write_file(root .. "/sample.txt", "added text")
				with_output(function()
					return "first\r\nsecond\r\n", 1
				end, function()
					local value = await(function(done)
						svn.preview(
							{ root = root, url = "file:///repo", revision = "1" },
							{ relpath = "sample.txt", status = "A", kind = "file", properties = true },
							done
						)
					end)
					clean(value.details, { "Properties unavailable: first", "second" })
					clean(value.right, { "added text" })
				end)
			end,
		},
		{
			"test_core_compare_crlf_resolution_error",
			function()
				compare_error(
					"merge-base",
					{ "No common ancestor; check unrelated or shallow history: first", "second" }
				)
			end,
		},
		{
			"test_core_compare_crlf_preview_error",
			function()
				compare_error("--summary", { "Preview unavailable", "first", "second" })
			end,
		},
		{
			"test_core_profile_crlf_command_error",
			function()
				local jobs = require("lazyvcs.source_control.jobs")
				local common = require("lazyvcs.backends.comparison")
				jobs.clear_history()
				with_output(function()
					return "first\r\nsecond\r\n", 1
				end, function()
					local done
					local task = common.task(function()
						done = true
					end)
					common.command(task, { root = h.tempdir(), vcs = "git" }, { "git", "show" }, function()
						task:finish(true)
					end)
					ctx.wait_for(function()
						return done
					end, "CRLF job history did not load")
				end)
				require("lazyvcs.commands").setup()
				vim.cmd("LazyVCS profile")
				local lines = vim.api.nvim_buf_get_lines(0, 1, -1, false)
				vim.cmd.close()
				jobs.clear_history()
				clean(lines, { "  first", "  second" })
			end,
		},
		{
			"test_core_display_lines_preserve_literal_carriage_returns",
			function()
				local util = require("lazyvcs.util")
				assert(vim.deep_equal(util.split_text_lines("one\rtwo  \r\nlast\r"), { "one\rtwo  ", "last\r" }))
				assert(vim.deep_equal(util.split_lines("one\r\n"), { "one\r" }), "Byte splitter changed")
				clean(util.split_text_lines("\r\n\r\n"), { "", "" })
				clean(util.split_text_lines(""), {})
				clean(util.split_text_lines(nil), {})
			end,
		},
		{
			"test_core_git_compare_crlf_content_bytes_preserved",
			function()
				local root, bytes = h.tempdir(), "one\r\ntwo\r\n"
				local file = assert(io.open(root .. "/sample.txt", "wb"))
				file:write(bytes)
				file:close()
				with_output(function(args)
					return vim.tbl_contains(args, "show") and bytes or ""
				end, function()
					local value = await(function(done)
						git.preview(snapshot(root), { relpath = "sample.txt", status = "M" }, done)
					end)
					assert(value.left_bytes == bytes and value.right_bytes == bytes, "File bytes were normalized")
					local profile =
						{ fileencoding = "utf-8", fileformat = "dos", bomb = false, binary = false, key = "test" }
					local text = require("lazyvcs.compare_text")
					local decoded = assert(text.decode(value.left_bytes, profile, 1024))
					assert(text.encode_file(decoded, profile, 1024) == bytes, "Text decoder lost CRLF representation")
					clean(value.left, { "one", "two" })
					clean(value.right, { "one", "two" })
				end)
			end,
		},
		{
			"test_core_process_lines_normalize_crlf",
			function()
				with_output(function()
					return "metadata\r\nsource\r\n"
				end, function()
					local lines = await(function(done)
						require("lazyvcs.backends.process").lines({ "git", "show" }, { cwd = h.tempdir() }, done)
					end)
					clean(lines, { "metadata", "source" })
				end)
			end,
		},
		{
			"test_core_git_compare_lf_refs",
			function()
				with_output(function(args)
					if vim.tbl_contains(args, "symbolic-ref") then
						return "topic\n"
					end
					return "refs/heads/main\t\nrefs/remotes/origin/HEAD\trefs/remotes/origin/main\n"
				end, function()
					local value = await(function(done)
						git.context({ root = h.tempdir() }, done)
					end)
					clean(value.candidates, { "main" })
					assert(value.branch == "topic" and value.suggestion == "origin/main")
				end)
			end,
		},
		{
			"test_core_git_compare_lf_merge_base",
			function()
				with_output(function()
					return oid .. "\n"
				end, function()
					local value = await(function(done)
						git.resolve({ root = h.tempdir() }, "main", done)
					end)
					assert(value.revision == oid, "Merge base kept CR: " .. vim.inspect(value.revision))
				end)
			end,
		},
		{
			"test_core_git_compare_lf_recreated_hashes",
			function()
				local root = h.tempdir()
				h.write_file(root .. "/sample.txt", "one")
				with_output(function(args)
					if vim.tbl_contains(args, "--name-status") then
						return "D\0sample.txt\0"
					elseif vim.tbl_contains(args, "--others") then
						return "sample.txt\0"
					elseif vim.tbl_contains(args, "ls-tree") then
						return "100644 blob " .. oid .. "\tsample.txt\0"
					elseif vim.tbl_contains(args, "hash-object") then
						return oid .. "\n"
					end
					return ""
				end, function()
					local items = await(function(done)
						git.list(snapshot(root), true, done)
					end)
					assert(#items == 0, "CRLF hash made identical retained contents appear changed")
				end)
			end,
		},
		{
			"test_core_git_compare_lf_summary",
			function()
				with_output(function(args)
					if vim.tbl_contains(args, "ls-files") then
						return ""
					end
					assert(vim.tbl_contains(args, "--summary"))
					return " mode change 100644 => 100755 sample.txt\n\n"
				end, function()
					local value = await(function(done)
						git.preview(
							snapshot(h.tempdir()),
							{ relpath = "sample.txt", status = "D", original_status = "A" },
							done
						)
					end)
					clean(value.details, { " mode change 100644 => 100755 sample.txt", "" })
					assert(value.loaded.text and #value.left == 0 and #value.right == 0)
				end)
			end,
		},
		{
			"test_core_git_compare_lf_submodule_log",
			function()
				local root = h.tempdir()
				vim.fn.mkdir(root .. "/nested")
				with_output(function(args)
					assert(vim.tbl_contains(args, "--submodule=log"))
					return "Submodule nested aaaaaaa..bbbbbbb:\n  > message\r\n"
				end, function()
					local value = await(function(done)
						git.preview(snapshot(root), { relpath = "nested", status = "M" }, done)
					end)
					assert(vim.deep_equal(value.right, { "Submodule nested aaaaaaa..bbbbbbb:", "  > message\r" }))
				end)
			end,
		},
		{
			"test_svn_compare_crlf_property_patch",
			function()
				with_output(function(args)
					assert(vim.tbl_contains(args, "--properties-only"))
					return table.concat({
						"Index: sample.txt\r",
						string.rep("=", 67) .. "\r",
						"--- sample.txt\t(revision 1)\r",
						"+++ sample.txt\t(working copy)\r",
						"\r",
						"Property changes on: sample.txt\r",
						string.rep("_", 67) .. "\r",
						"Modified: custom\r",
						"## -1,2 +1,3 ##\r",
						"-one",
						"-two",
						"+one\r",
						"+two\r",
						"+last\r",
						"\\ No newline at end of property\r",
						"Added: another\r",
						"## -0,0 +1 ##\r",
						"+value",
						"Deleted: removed\r",
						"## -1,2 +1 ##\r",
						"-value",
						-- These look like file headers but are property content.
						"--- literal\r",
						"+++ literal\r",
						"",
					}, "\n")
				end, function()
					local value = await(function(done)
						svn.preview(
							{ root = h.tempdir(), url = "file:///repo", revision = "1" },
							{ relpath = "sample.txt", status = "M", kind = "file", property_only = true },
							done
						)
					end)
					assert(
						vim.deep_equal(value.right, {
							"Index: sample.txt",
							string.rep("=", 67),
							"--- sample.txt\t(revision 1)",
							"+++ sample.txt\t(working copy)",
							"",
							"Property changes on: sample.txt",
							string.rep("_", 67),
							"Modified: custom",
							"## -1,2 +1,3 ##",
							"-one",
							"-two",
							"+one\r",
							"+two\r",
							"+last",
							"\\ No newline at end of property",
							"Added: another",
							"## -0,0 +1 ##",
							"+value",
							"Deleted: removed",
							"## -1,2 +1 ##",
							"-value",
							"--- literal\r",
							"+++ literal\r",
						}),
						vim.inspect(value.right)
					)
					assert(vim.deep_equal(value.right, value.properties))
				end, true)
			end,
		},
		{
			"test_svn_compare_crlf_directory_property_values",
			function()
				with_output(function(args)
					local path = args[#args]:gsub("@[^@]*$", "")
					return '<properties>\r\n<target path="'
						.. path
						.. '"><property name="custom" encoding="base64">'
						.. vim.base64.encode(vim.tbl_contains(args, "-r") and "one\ntwo\n" or "one\r\ntwo\r\n")
						.. "</property></target>\r\n</properties>\r\n"
				end, function()
					local value = await(function(done)
						svn.preview(
							{ root = h.tempdir(), url = "file:///repo", revision = "1" },
							{ relpath = "folder", status = "M", kind = "dir", property_only = true },
							done
						)
					end)
					local changed = {}
					for _, line in ipairs(value.right) do
						if line:match("^[+-]") then
							changed[#changed + 1] = line
						end
					end
					assert(vim.deep_equal(changed, { "-one", "-two", "+one\r", "+two\r" }), vim.inspect(changed))
				end)
			end,
		},
	}
end
