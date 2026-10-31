return function(ctx)
	local h = ctx.helpers
	local function write(path, bytes)
		local file = assert(io.open(path, "wb"))
		assert(file:write(bytes))
		assert(file:close())
	end
	local function await(start)
		local result, err, finished
		start(function(value, failure)
			result, err, finished = value, failure, true
		end)
		ctx.wait_for(function()
			return finished
		end, "review regression did not finish", 15000)
		return result, err
	end
	return {
		{
			"test_svn_blame_preserves_copied_and_moved_directory_child_history",
			function()
				for _, operation in ipairs({ "copy", "move" }) do
					local f = h.make_svn_fixture()
					vim.fn.mkdir(f.root .. "/original/nested", "p")
					write(f.root .. "/original/nested/child.txt", "committed child\n")
					h.exec({ "svn", "add", "original" }, f.root)
					h.exec({ "svn", "commit", "-m", "directory", "original" }, f.root)
					h.exec({ "svn", operation, "original", "destination" }, f.root)
					local path = f.root .. "/destination/nested/child.txt"
					local raw = h.exec({ "svn", "info", "--xml", path .. "@" }, f.root)
					local info = assert(require("lazyvcs.backends.xml").parse_info(raw))
					assert(info.schedule == "normal" and not info.copy_from_url, "fixture must copy an ancestor")
					local rows, err = await(function(done)
						require("lazyvcs.backends.svn").blame_lines_async(path, done, { root = f.root })
					end)
					assert(rows, err)
					assert(not require("lazyvcs.backends.svn").parse_blame_entries(rows)[1].uncommitted)
				end
			end,
		},
		{
			"test_core_staged_git_blob_ignores_loaded_worktree_encoding_hint",
			function()
				local f = h.make_git_fixture()
				write(f.root .. "/.gitattributes", "*.txt working-tree-encoding=UTF-16LE\n")
				write(f.file, assert(vim.iconv("head!\n", "utf-8", "utf-16le")))
				h.exec({ "git", "add", ".gitattributes", "sample.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "encoded tree" }, f.root)
				write(f.file, assert(vim.iconv("index\n", "utf-8", "utf-16le")))
				h.exec({ "git", "add", "sample.txt" }, f.root)
				vim.cmd("edit ++enc=utf-16le " .. vim.fn.fnameescape(f.file))
				assert(vim.bo.fileencoding == "utf-16le")
				local result, err = await(function(done)
					require("lazyvcs.backends.git").load_diff_target_async(
						{ vcs = "git", root = f.root, path = f.file, relpath = "sample.txt", section = "staged" },
						done
					)
				end)
				assert(result, err)
				assert(
					result.left.lines[1] == "head!" and result.right.lines[1] == "index",
					"UTF-8 blobs inherited UTF-16 working-buffer hint"
				)
			end,
		},
		{
			"test_svn_sync_blame_rejects_binary_but_accepts_text_binary_mime",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "propset", "svn:mime-type", "application/octet-stream", f.file }, f.root)
				h.exec({ "svn", "commit", "-m", "binary MIME text", f.file }, f.root)
				local svn = require("lazyvcs.backends.svn")
				assert(svn.blame_lines(f.file), "decodable text with binary MIME lost blame")
				write(f.file, "binary\0bytes\n")
				h.exec({ "svn", "commit", "-m", "actual binary", f.file }, f.root)
				local rows, err = svn.blame_lines(f.file)
				assert(not rows and err, "binary bytes received synchronous line attribution")
				local revision, revision_err = svn.line_revision(f.file, 1)
				assert(not revision and revision_err, "binary bytes received a synchronous revision")
			end,
		},
		{
			"test_svn_blame_copy_origin_uses_child_revision_in_mixed_copy",
			function()
				local f = h.make_svn_fixture()
				vim.fn.mkdir(f.root .. "/source", "p")
				write(f.root .. "/source/child.txt", "local child\n")
				h.exec({ "svn", "add", "source" }, f.root)
				h.exec({ "svn", "commit", "-m", "child", "source" }, f.root)
				local other = h.tempdir() .. "/other"
				h.exec({ "svn", "checkout", h.file_url(f.repo), other }, f.root)
				write(other .. "/source/child.txt", "remote child\n")
				h.exec({ "svn", "commit", "-m", "remote child", other .. "/source/child.txt" }, other)
				h.exec({ "svn", "update", "--depth", "empty", "source" }, f.root)
				h.exec({ "svn", "copy", "source", "copied" }, f.root)
				local path = f.root .. "/copied/child.txt"
				local rows, err = await(function(done)
					require("lazyvcs.backends.svn").blame_lines_async(path, done, { root = f.root })
				end)
				assert(rows, err)
				local entry = require("lazyvcs.backends.svn").parse_blame_entries(rows)[1]
				assert(entry.revision == "2" and not entry.uncommitted, vim.inspect(entry))
			end,
		},
		{
			"test_core_staged_git_legacy_utf16_blob_keeps_loaded_encoding_hint",
			function()
				local f = h.make_git_fixture()
				local before = assert(vim.iconv("legacy\n", "utf-8", "utf-16le"))
				local after = assert(vim.iconv("staged\n", "utf-8", "utf-16le"))
				write(f.file, before)
				h.exec({ "git", "commit", "-am", "raw UTF16" }, f.root)
				write(f.file, after)
				h.exec({ "git", "add", "sample.txt" }, f.root)
				vim.cmd("edit ++enc=utf-16le " .. vim.fn.fnameescape(f.file))
				local result, err = await(function(done)
					require("lazyvcs.backends.git").load_diff_target_async(
						{ vcs = "git", root = f.root, path = f.file, relpath = "sample.txt", section = "staged" },
						done
					)
				end)
				assert(result, err)
				assert(result.left.bytes == before and result.right.bytes == after)
				assert(
					result.left.lines[1] == "legacy" and result.right.lines[1] == "staged",
					"legacy blob lost its exact loaded encoding hint"
				)
				assert(vim.iconv(result.left.lines[1] .. "\n", "utf-8", "utf-16le") == before)
			end,
		},
		{
			"test_svn_blame_copy_origin_preserves_literal_url_components",
			function()
				local f = h.make_svn_fixture()
				local parent = "original space%20"
				vim.fn.mkdir(f.root .. "/" .. parent, "p")
				local names = { "x%20y.txt", "x y.txt", "café@#.txt" }
				for index, name in ipairs(names) do
					write(f.root .. "/" .. parent .. "/" .. name, "child " .. index .. "\n")
				end
				h.exec({ "svn", "add", parent }, f.root)
				h.exec({ "svn", "commit", "-m", "literal children", parent }, f.root)
				h.exec({ "svn", "copy", parent, "copied" }, f.root)
				for index, name in ipairs(names) do
					local rows, err = await(function(done)
						require("lazyvcs.backends.svn").blame_lines_async(
							f.root .. "/copied/" .. name,
							done,
							{ root = f.root }
						)
					end)
					assert(rows, err)
					assert(rows[1]:match("child " .. index .. "$"), vim.inspect(rows))
					assert(not require("lazyvcs.backends.svn").parse_blame_entries(rows)[1].uncommitted)
				end
			end,
		},
		{
			"test_core_git_legacy_utf16_without_nuls_keeps_source_attribute_proof",
			function()
				local f = h.make_git_fixture()
				local before, after = "\194\162", "\195\162"
				write(f.file, before)
				h.exec({ "git", "commit", "-am", "legacy no NUL" }, f.root)
				write(f.file, after)
				h.exec({ "git", "add", "sample.txt" }, f.root)
				vim.cmd("edit ++enc=utf-16le " .. vim.fn.fnameescape(f.file))
				local result, err = await(function(done)
					require("lazyvcs.backends.git").load_diff_target_async(
						{ vcs = "git", root = f.root, path = f.file, relpath = "sample.txt", section = "staged" },
						done
					)
				end)
				assert(result, err)
				assert(result.left.lines[1] == vim.iconv(before, "utf-16le", "utf-8"))
				assert(result.right.lines[1] == vim.iconv(after, "utf-16le", "utf-8"))
				assert(result.left.bytes == before and result.right.bytes == after)
			end,
		},
		{
			"test_core_git_old_source_fallback_rejects_changed_ambiguous_attributes",
			function()
				local f = h.make_git_fixture()
				write(f.file, "head!\n")
				h.exec({ "git", "commit", "-am", "plain source" }, f.root)
				write(f.root .. "/.gitattributes", "*.txt working-tree-encoding=UTF-16LE\n")
				write(f.file, assert(vim.iconv("index\n", "utf-8", "utf-16le")))
				h.exec({ "git", "add", ".gitattributes", "sample.txt" }, f.root)
				vim.cmd("edit ++enc=utf-16le " .. vim.fn.fnameescape(f.file))
				local process = require("lazyvcs.backends.process")
				local run, unsupported = process.bytes, false
				---@diagnostic disable-next-line: duplicate-set-field
				process.bytes = function(args, opts, done)
					if args[2] == "check-attr" and args[4] and args[4]:find("--source=", 1, true) then
						unsupported = true
						local task = require("lazyvcs.backends.task").new(done)
						vim.schedule(function()
							task:finish(nil, "error: unknown option source=HEAD")
						end)
						return task
					end
					return run(args, opts, done)
				end
				local ok, failure = pcall(function()
					local result, err = await(function(done)
						require("lazyvcs.backends.git").load_diff_target_async(
							{ vcs = "git", root = f.root, path = f.file, relpath = "sample.txt", section = "staged" },
							done
						)
					end)
					assert(
						unsupported and not result and err and err:find("encoding is ambiguous", 1, true),
						tostring(err)
					)
				end)
				process.bytes = run
				assert(ok, failure)
			end,
		},
	}
end
