return function(ctx)
	local h, api = ctx.helpers, vim.api
	local common = require("lazyvcs.backends.comparison")
	local compare = require("lazyvcs.compare")
	local git = require("lazyvcs.backends.compare_git")
	local function write(path, bytes)
		local file = assert(io.open(path, "wb"))
		file:write(bytes)
		file:close()
	end
	local function await(start)
		local done, value, failure
		start(function(result, err)
			done, value, failure = true, result, err
		end)
		ctx.wait_for(function()
			return done
		end, "review regression request", 15000)
		return value, failure
	end
	local function keys(value)
		api.nvim_feedkeys(api.nvim_replace_termcodes(value, true, false, true), "xt", false)
	end
	local function guarded(fn)
		return function()
			local encodings, formats, command = vim.o.fileencodings, vim.o.fileformats, common.command
			local notify = vim.notify
			local ok, err = xpcall(fn, debug.traceback)
			common.command, vim.notify = command, notify
			pcall(compare.close)
			vim.o.fileencodings, vim.o.fileformats = encodings, formats
			assert(ok, err)
		end
	end
	local function snapshot(f)
		return assert(await(function(done)
			git.resolve({ root = f.root }, "HEAD", done)
		end))
	end
	local cases = {}
	for _, ending in ipairs({ "mixed_loaded", "unix_only", "stale_mac" }) do
		cases[#cases + 1] = {
			"test_core_compare_review_endings_" .. ending,
			guarded(function()
				vim.o.fileencodings, vim.o.fileformats = "ucs-bom,utf-8,latin1", "unix,dos"
				local f = h.make_git_fixture()
				write(f.root .. "/.gitattributes", "* -text\n")
				local before = ending == "mixed_loaded" and "a\r\nb\nc\r\n" or "a\nb\nc\n"
				write(f.file, before)
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "line endings" }, f.root)
				local after = ending == "mixed_loaded" and "a\r\nB\nc\r\n" or "a\r\nb\r\nc\r\n"
				write(f.file, after)
				if ending == "unix_only" then
					vim.o.fileformats = "unix"
				else
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					if ending == "mixed_loaded" then
						assert(vim.bo.fileformat == "unix")
						api.nvim_buf_set_lines(0, 1, 2, false, { "B" })
						vim.cmd.write()
					else
						vim.bo.fileformat = "mac"
					end
				end
				local result, err = await(function(done)
					git.preview(snapshot(f), { relpath = "sample.txt", status = "M" }, done)
				end)
				assert(result, err)
				assert(vim.deep_equal(result.left, { "a", "b", "c" }), vim.inspect(result.left))
				assert(
					vim.deep_equal(result.right, { "a", ending == "mixed_loaded" and "B" or "b", "c" }),
					vim.inspect(result.right)
				)
				assert(result.left_bytes == before and result.right_bytes == after, "raw endings changed")
				local hunks = require("lazyvcs.diff").compute_hunks(result.left, result.right)
				assert(#hunks == (ending == "mixed_loaded" and 1 or 0), vim.inspect(hunks))
				if ending == "mixed_loaded" then
					assert(hunks[1].current_start == 2 and hunks[1].current_count == 1 and hunks[1].base_count == 1)
				end
				local buf = api.nvim_create_buf(false, true)
				api.nvim_buf_set_lines(buf, 0, -1, false, result.right)
				api.nvim_buf_delete(buf, { force = true })
				local lone = assert(
					require("lazyvcs.compare_text").decode_preview(
						"a\rb\rc\r",
						{ fileencodings = "utf-8", fileformats = "mac" },
						100
					)
				)
				assert(vim.deep_equal(lone.lines, { "a\rb\rc\r" }), "lone CR split a display line")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_review_exact_encoding_hint",
		guarded(function()
			local root = h.tempdir()
			write(root .. "/README.md", "caf\233\n")
			vim.cmd.edit(vim.fn.fnameescape(root .. "/README.md"))
			vim.bo.fileencoding = "latin1"
			local opts = common.decode_options(root .. "/README")
			assert(not opts.hint, "README.md supplied README's encoding hint")
			local document = assert(require("lazyvcs.compare_text").decode_preview("café\n", opts, 100))
			assert(document.lines[1] == "café")
			local exact = common.decode_options(root .. "/README.md")
			assert(exact.hint.fileencoding == "latin1")
			assert(exact.hint.fileformat == nil and exact.hint.binary == nil, "hint contains more than encoding")
			for _, path in ipairs({ root .. "/[", root .. "/trailing\\" }) do
				local ok, options = pcall(common.decode_options, path)
				assert(ok, "literal path threw: " .. tostring(options))
				assert(not options.hint)
			end
		end),
	}
	for _, key in ipairs({ "]v", "[v" }) do
		cases[#cases + 1] = {
			"test_core_compare_review_metadata_jump_" .. (key == "]v" and "next" or "previous"),
			guarded(function()
				local f = h.make_git_fixture()
				local lines = {}
				for i = 1, 30 do
					lines[i] = "line " .. i
				end
				write(f.root .. "/other.txt", table.concat(lines, "\n") .. "\n")
				h.exec({ "git", "add", "other.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "second file" }, f.root)
				lines[5], lines[25] = "changed first", "changed last"
				write(f.root .. "/other.txt", table.concat(lines, "\n") .. "\n")
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ctx.wait_for(function()
					return s.preview_result
				end, "initial preview", 15000)
				local path = s.shown_item.relpath == "other.txt" and "sample.txt" or "other.txt"
				-- Select another file so p must request a metadata-only result.
				if path == "sample.txt" then
					api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[path], 0 })
					keys("P")
					ctx.wait_for(function()
						return s.shown_item.relpath == path and s.preview_result
					end, "other preview", 15000)
				end
				api.nvim_set_current_win(s.sidewin)
				api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["other.txt"], 0 })
				keys("p")
				ctx.wait_for(function()
					return s.mode == "metadata" and s.shown_item.relpath == "other.txt"
				end, "metadata only", 15000)
				assert(not s.preview_result.loaded.text)
				local notices = {}
				vim.notify = function(message)
					notices[#notices + 1] = message
				end
				api.nvim_set_current_win(s.rightwin)
				keys(key)
				ctx.wait_for(function()
					return s.mode == "text" and not s.preview_job
				end, "navigation text", 15000)
				assert(
					api.nvim_win_get_cursor(s.rightwin)[1] == (key == "]v" and 5 or 25),
					"metadata jump lost its intent"
				)
				assert(#notices == 0, vim.inspect(notices))
			end),
		}
	end
	cases[#cases + 1] = {
		"test_core_compare_review_attribute_source_failure",
		guarded(function()
			local f = h.make_git_fixture()
			local pinned = snapshot(f)
			local command = common.command
			for _, code in ipairs({ 129, 1 }) do
				---@diagnostic disable-next-line: duplicate-set-field
				common.command = function(task, repo, args, done, opts)
					if vim.tbl_contains(args, "--source=" .. pinned.revision) then
						vim.schedule(function()
							done(nil, "Fehler: unbekannte Option", { code = code })
						end)
						return
					end
					return command(task, repo, args, done, opts)
				end
				local result, err = await(function(done)
					git.preview(pinned, { relpath = "sample.txt", status = "M" }, done)
				end)
				assert(result and result.left[1] == "one", err)
			end
		end),
	}
	cases[#cases + 1] = {
		"test_core_compare_review_attribute_empty_sides",
		guarded(function()
			local f = h.make_git_fixture()
			local pinned, command = snapshot(f), common.command
			local calls = {}
			---@diagnostic disable-next-line: duplicate-set-field
			common.command = function(task, repo, args, done, opts)
				if vim.tbl_contains(args, "check-attr") then
					calls[#calls + 1] = args
				end
				return command(task, repo, args, done, opts)
			end
			for _, item in ipairs({
				{ relpath = "sample.txt", status = "A" },
				{ relpath = "sample.txt", status = "?", untracked = true },
				{ relpath = "sample.txt", status = "D" },
			}) do
				calls = {}
				assert(await(function(done)
					git.preview(pinned, item, done)
				end))
				assert(#calls == 1, item.status .. " inspected an empty side: " .. #calls)
				assert(vim.tbl_contains(calls[1], "--source=" .. pinned.revision) == (item.status == "D"))
			end
		end),
	}
	cases[#cases + 1] = {
		"test_core_compare_review_parallel_attributes",
		guarded(function()
			local f = h.make_git_fixture()
			local pinned, command, held = snapshot(f), common.command, {}
			---@diagnostic disable-next-line: duplicate-set-field
			common.command = function(task, repo, args, done, opts)
				if vim.tbl_contains(args, "check-attr") then
					held[#held + 1] = done
					return
				end
				return command(task, repo, args, done, opts)
			end
			local result, failure
			local task = git.preview(pinned, { relpath = "sample.txt", status = "M" }, function(value, err)
				result, failure = value, err
			end)
			local count = #held
			if count ~= 2 then
				task:cancel()
			end
			assert(count == 2, "attribute reads were serialized: " .. count .. " submitted")
			-- Finish in reverse order to exercise both sides of the join.
			held[2]("sample.txt\0working-tree-encoding\0unspecified\0")
			assert(not result)
			held[1]("sample.txt\0working-tree-encoding\0unspecified\0")
			ctx.wait_for(function()
				return result or failure
			end, "parallel attributes", 15000)
			assert(result and result.left[1] == "one" and result.right[2] == "changed", failure)
		end),
	}
	cases[#cases + 1] = {
		"test_core_compare_review_stale_encoding_hint_fallback",
		guarded(function()
			local root = h.tempdir()
			write(root .. "/sample", "old\n")
			vim.cmd.edit(vim.fn.fnameescape(root .. "/sample"))
			vim.bo.fileencoding, vim.bo.binary = "utf-8", false
			local opts = common.decode_options(root .. "/sample")
			opts.fileencodings = "ucs-bom,utf-8,latin1"
			local result, err = require("lazyvcs.compare_text").decode_preview("caf\233\r\n", opts, 100)
			assert(result and result.lines[1] == "café", err)
			assert(result.encoding == "latin1")
		end),
	}
	cases[#cases + 1] = {
		"test_core_compare_review_decode_error_sides",
		guarded(function()
			for _, side in ipairs({ "left", "right" }) do
				for _, row in ipairs({ { "\255", "utf-8" }, { "abc", "no-such-encoding" }, { "\255", "ucs-4le" } }) do
					local ok, err = common.decode_side({}, side, row[1], { encoding = row[2] })
					assert(
						not ok and err and err:find(side == "left" and "Base preview" or "Saved preview", 1, true),
						tostring(err)
					)
					assert(err and not err:find("VCS base", 1, true), err)
				end
			end
		end),
	}
	for _, endian in ipairs({ "LE", "BE" }) do
		cases[#cases + 1] = {
			"test_core_compare_review_utf16" .. endian:lower() .. "_bom_attribute",
			guarded(function()
				local f = h.make_git_fixture()
				local before = "café\nold\n"
				local after = "café\nnew\n"
				local function encoded(value)
					local le = assert(vim.iconv(value, "utf-8", "utf-16le"))
					return endian == "LE" and "\255\254" .. le or "\254\255" .. le:gsub("(.)(.)", "%2%1")
				end
				local name = "UTF-16" .. endian .. "-BOM"
				for _, encoding in ipairs({ name, name:lower(), "Utf-16" .. endian .. "-Bom" }) do
					write(f.root .. "/.gitattributes", "sample.txt working-tree-encoding=UTF-16\n")
					write(f.file, encoded(before))
					h.exec({ "git", "add", "." }, f.root)
					h.exec({ "git", "commit", "--allow-empty", "-m", "BOM attribute" }, f.root)
					write(f.file, encoded(after))
					-- Git itself need not support every alias to read an existing saved file.
					write(f.root .. "/.gitattributes", "sample.txt working-tree-encoding=" .. encoding .. "\n")
					local result, err = await(function(done)
						git.preview(snapshot(f), { relpath = "sample.txt", status = "M" }, done)
					end)
					assert(result, encoding .. ": " .. tostring(err))
					assert(result.left[1] == "café" and result.right[1] == "café", encoding)
					assert(result.right_document.bom and result.right_bytes == encoded(after))
				end
			end),
		}
	end
	cases[#cases + 1] = {
		"test_svn_compare_review_metadata_property_gate",
		guarded(function()
			local f = h.make_svn_fixture()
			write(f.root .. "/untracked.txt", "new\n")
			local svn = require("lazyvcs.backends.compare_svn")
			local pinned = { root = f.root, url = h.file_url(f.repo), revision = "1" }
			local command, property_calls = common.command, 0
			---@diagnostic disable-next-line: duplicate-set-field
			common.command = function(task, repo, args, done, opts)
				if vim.tbl_contains(args, "--properties-only") or vim.tbl_contains(args, "proplist") then
					property_calls = property_calls + 1
				end
				return command(task, repo, args, done, opts)
			end
			for _, item in ipairs({
				{ relpath = "untracked.txt", status = "?", untracked = true },
				{ relpath = "untracked.txt", status = "A", untracked = true },
				{ relpath = "sample.txt", status = "M" },
			}) do
				local result = assert(await(function(done)
					svn.preview(pinned, item, done, { mode = "metadata" })
				end))
				assert(
					not result.details and not result.properties and property_calls == 0,
					"ineligible metadata loaded properties: " .. vim.inspect(result)
				)
			end
			local s = assert(compare.open({ path = f.root, base = pinned.url .. "@1" }))
			ctx.wait_for(function()
				return s.preview_result
			end, "SVN initial preview", 15000)
			api.nvim_set_current_win(s.sidewin)
			api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["untracked.txt"], 0 })
			keys("p")
			ctx.wait_for(function()
				return s.mode == "metadata" and not s.preview_job
			end, "untracked metadata", 15000)
			assert(api.nvim_buf_get_lines(s.left, 0, 1, false)[1] == "No metadata or property changes for this path.")
			compare.close(s)
			h.exec({ "svn", "propset", "custom:review", "value", "sample.txt" }, f.root)
			local result = assert(await(function(done)
				svn.preview(
					pinned,
					{ relpath = "sample.txt", status = "M", property_only = true },
					done,
					{ mode = "metadata" }
				)
			end))
			assert(result.properties and table.concat(result.properties, "\n"):find("custom:review", 1, true))
			write(f.root .. "/added.txt", "added\n")
			h.exec({ "svn", "add", "added.txt" }, f.root)
			h.exec({ "svn", "propset", "custom:added", "value", "added.txt" }, f.root)
			result = assert(await(function(done)
				svn.preview(pinned, { relpath = "added.txt", status = "A" }, done, { mode = "metadata" })
			end))
			assert(result.properties and table.concat(result.properties, "\n"):find("custom:added", 1, true))
		end),
	}
	cases[#cases + 1] = {
		"test_svn_compare_review_replacement_property_label",
		guarded(function()
			local svn = require("lazyvcs.backends.compare_svn")
			for _, with_properties in ipairs({ false, true }) do
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "mkdir", "node" }, f.root)
				if with_properties then
					h.exec({ "svn", "propset", "custom:review", "before", "node" }, f.root)
				end
				h.exec({ "svn", "commit", "-m", "directory" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				h.exec({ "svn", "rm", "node" }, f.root)
				write(f.root .. "/node", "after\n")
				h.exec({ "svn", "add", "node" }, f.root)
				if with_properties then
					h.exec({ "svn", "propset", "custom:review", "after", "node" }, f.root)
				end
				local pinned = { root = f.root, url = h.file_url(f.repo), revision = "2" }
				local items = assert(await(function(done)
					svn.list(pinned, false, done)
				end))
				assert(#items == 1 and items[1].status == "R", vim.inspect(items))
				local row = require("lazyvcs.compare_view").build(items).lines[1]
				if not with_properties then
					assert(not row:find("[props]", 1, true), row)
				end
				assert(items[1].load_properties, "replacement lost its property loader flag")
				local result = assert(await(function(done)
					svn.preview(pinned, items[1], done)
				end))
				assert(result.left[1] == "Directory: node" and result.right[1] == "after")
				assert((result.properties ~= nil) == with_properties, vim.inspect(result))
				result = assert(await(function(done)
					svn.preview(pinned, items[1], done, { mode = "metadata" })
				end))
				assert((result.properties ~= nil) == with_properties)
			end
		end),
	}
	cases[#cases + 1] = {
		"test_svn_compare_review_blame_maps_decoded_raw_sources",
		guarded(function()
			local svn = require("lazyvcs.backends.compare_svn")
			for _, row in ipairs({
				{ "CRLF", "café\nold\n", "café\r\nnew\r\n" },
				{ "transcode", "caf\233\nold\n", "café\nnew\n" },
				{ "latin1", "caf\233\nold\n", "caf\233\nnew\n" },
			}) do
				vim.o.fileencodings = "ucs-bom,utf-8,latin1"
				local f = h.make_svn_fixture()
				write(f.file, row[2])
				h.exec({ "svn", "commit", "-m", "encoded" }, f.root)
				write(f.file, row[3])
				local s = assert(compare.open({ path = f.root, base = h.file_url(f.repo) .. "@2" }))
				ctx.wait_for(function()
					return s.preview_result
				end, "SVN encoded preview", 15000)
				for _, side in ipairs({ "base", "saved" }) do
					local target = assert(compare.blame_target(side == "base" and s.left or s.right))
					assert(target.bytes == row[side == "base" and 2 or 3], "blame lost source bytes")
					target.first, target.last = 1, 2
					local entries, err = await(function(done)
						require("lazyvcs.backends.blame_selection").load(target, target.bytes, done)
					end)
					assert(
						entries and entries[1] and not entries[1].uncommitted,
						row[1] .. " " .. side .. ": " .. tostring(err) .. vim.inspect(entries)
					)
					assert(entries[1].revision == "2" and entries[2].uncommitted == (side == "saved" and true or nil))
				end
				local pinned = s.snapshot
				compare.close(s)
				-- Keep the provider's raw-byte contract explicit as well.
				local value = assert(await(function(done)
					svn.preview(pinned, { relpath = "sample.txt", status = "M" }, done)
				end))
				assert(value.left_bytes == row[2] and value.right_bytes == row[3])
			end
			-- Saved-pane blame decodes working-copy BASE; its errors must not name the base pane.
			vim.o.fileencodings = "ucs-bom,utf-8"
			local f = h.make_svn_fixture()
			write(f.file, "café\nold\n")
			h.exec({ "svn", "commit", "-m", "utf-8" }, f.root)
			-- BASE becomes Latin-1 while the pinned revision and saved file stay UTF-8.
			write(f.file, "caf\233\nold\n")
			h.exec({ "svn", "commit", "-m", "latin1" }, f.root)
			write(f.file, "café\nnew\n")
			local s = assert(compare.open({ path = f.root, base = h.file_url(f.repo) .. "@2" }))
			ctx.wait_for(function()
				return s.preview_result
			end, "SVN saved-pane preview", 15000)
			local target = assert(compare.blame_target(s.right))
			target.first, target.last = 1, 2
			local entries, err = await(function(done)
				require("lazyvcs.backends.blame_selection").load(target, target.bytes, done)
			end)
			assert(not entries and tostring(err):find("^SVN BASE for blame: "), "BASE decode error: " .. tostring(err))
			compare.close(s)
		end),
	}
	return cases
end
