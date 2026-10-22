return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare = require("lazyvcs.compare")
	local function ready(s)
		ctx.wait_for(function()
			return s.preview_result or s.message == "Comparison unavailable"
		end, "SVN preview", 15000)
		assert(s.preview_result, s.message)
	end
	local function keys(text)
		api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end
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
		end, "SVN request", 15000)
		return value, failure
	end
	local cases = {
		{
			"test_svn_compare_list_reconciles_directory_property_candidates",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				local provider, common = require("lazyvcs.backends.compare_svn"), require("lazyvcs.backends.comparison")
				local snapshot = { root = f.root, url = h.file_url(f.repo), revision = "1" }
				local original = common.command
				local mode, property_calls, held = nil, 0, nil
				local summary = '<diff><paths><path kind="dir" item="none" props="modified">'
					.. snapshot.url
					.. "</path></paths></diff>"
				---@diagnostic disable-next-line: duplicate-set-field
				common.command = function(task, repo, args, callback, opts)
					if vim.tbl_contains(args, "--summarize") then
						vim.schedule(function()
							if task:is_active() then
								callback(summary)
							end
						end)
						return
					end
					if vim.tbl_contains(args, "proplist") then
						property_calls = property_calls + 1
						if mode == "cancel" then
							held = callback
							return
						end
						if mode then
							vim.schedule(function()
								if task:is_active() then
									if mode == "malformed" then
										callback("<properties>broken</properties>")
									elseif mode == "truncated" then
										callback(nil, "truncated", { stdout_truncated = true })
									else
										callback(nil, "property read failed")
									end
								end
							end)
							return
						end
					end
					return original(task, repo, args, callback, opts)
				end
				local ok, err = xpcall(function()
					local items, failure = await(function(done)
						provider.list(snapshot, false, done)
					end)
					assert(items, failure)
					assert(#items == 0, "clean directory property candidate remained listed")
					assert(property_calls == 2, "directory reconciliation did not use shallow maps")
					local s = assert(compare.open({ editable = false, path = f.root, base = snapshot.url .. "@1" }))
					ctx.wait_for(function()
						return s.snapshot
					end, "clean list", 15000)
					assert(s.message == "No saved changes", s.message)
					compare.close(s)
					for _, failure_mode in ipairs({ "failed", "malformed", "truncated" }) do
						mode = failure_mode
						items = assert(await(function(done)
							provider.list(snapshot, false, done)
						end))
						assert(#items == 1 and items[1].property_check_error, "failed validation hid a directory")
						assert(
							require("lazyvcs.compare_view").build(items).lines[1]:find("property check failed", 1, true)
						)
						local result = assert(await(function(done)
							provider.preview(snapshot, items[1], done, { mode = "metadata" })
						end))
						local warning = table.concat(result.details or {}, "\n")
						assert(
							warning:find("unavailable", 1, true) and warning:find("Property validation failed", 1, true)
						)
					end
					local published = false
					property_calls, mode = 0, "cancel"
					local task = provider.list(snapshot, false, function()
						published = true
					end)
					ctx.wait_for(function()
						return property_calls > 0
					end, "property validation started", 15000)
					task:cancel()
					assert(held)(nil, "cancelled read")
					vim.wait(50)
					assert(not published, "cancelled list published")
				end, debug.traceback)
				common.command = original
				assert(ok, err)
				h.exec({ "svn", "mkdir", "nested", "deleted" }, f.root)
				h.exec({ "svn", "commit", "-m", "directories" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				local property = h.tempdir() .. "/property"
				write(property, "before\0bytes")
				h.exec({ "svn", "propset", "custom:binary", "--file", property, "." }, f.root)
				h.exec({ "svn", "commit", "-m", "root property" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				snapshot.revision = "2"
				local items = assert(await(function(done)
					provider.list(snapshot, false, done)
				end))
				assert(#items == 1 and items[1].relpath == ".", "reconciled against WC BASE instead of pinned revision")
				snapshot.revision = "3"
				items = assert(await(function(done)
					provider.list(snapshot, false, done)
				end))
				assert(#items == 0)
				write(property, "after\0bytes")
				h.exec({ "svn", "propset", "custom:binary", "--file", property, "." }, f.root)
				h.exec({ "svn", "propset", "custom:review", "new", "nested" }, f.root)
				h.exec({ "svn", "mkdir", "added" }, f.root)
				h.exec({ "svn", "rm", "deleted" }, f.root)
				items = assert(await(function(done)
					provider.list(snapshot, false, done)
				end))
				local paths = {}
				for _, item in ipairs(items) do
					paths[item.relpath] = item
				end
				assert(
					paths["."] and paths.nested and paths.added.status == "A" and paths.deleted.status == "D",
					vim.inspect(items)
				)
			end,
		},

		{
			"test_svn_compare_metadata_survives_unavailable_content",
			function()
				require("lazyvcs.commands").setup()
				for _, oversized in ipairs({ false, true }) do
					local f = h.make_svn_fixture()
					write(f.file, oversized and "old\n" or "old\0data\n")
					h.exec({ "svn", "propset", "custom:review", "old", "sample.txt" }, f.root)
					h.exec({ "svn", "commit", "-m", "properties before" }, f.root)
					h.exec({ "svn", "update" }, f.root)
					write(f.file, oversized and string.rep("x", 1024 * 1024 + 1) or "new\0data\n")
					h.exec({ "svn", "propset", "custom:review", "new", "sample.txt" }, f.root)
					local s =
						assert(compare.open({ editable = false, path = f.root, base = h.file_url(f.repo) .. "@2" }))
					local common = require("lazyvcs.backends.comparison")
					local command, read = common.command, common.read_file
					local ok, err = xpcall(function()
						ctx.wait_for(function()
							return s.snapshot and not s.preview_job
						end, "initial preview", 15000)
						api.nvim_set_current_win(s.sidewin)
						api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["sample.txt"], 0 })
						keys("P")
						ctx.wait_for(function()
							return not s.preview_job
						end, "unavailable text", 15000)
						local cats, reads = 0, 0
						---@diagnostic disable-next-line: duplicate-set-field
						common.command = function(task, repo, args, callback, opts)
							if vim.tbl_contains(args, "cat") then
								cats = cats + 1
							end
							return command(task, repo, args, callback, opts)
						end
						---@diagnostic disable-next-line: duplicate-set-field
						common.read_file = function(...)
							reads = reads + 1
							return read(...)
						end
						api.nvim_set_current_win(s.sidewin)
						if oversized then
							keys("p")
						else
							vim.cmd("LazyVCS compare metadata")
						end
						ctx.wait_for(function()
							return s.mode == "metadata" or (not s.preview_job and s.mode == "message")
						end, "metadata request", 15000)
						assert(
							s.mode == "metadata",
							"metadata remained unavailable: "
								.. table.concat(api.nvim_buf_get_lines(s.left, 0, -1, false), " | ")
						)
						local text = table.concat(api.nvim_buf_get_lines(s.left, 0, -1, false), "\n")
						assert(
							text:find("Modified: custom:review", 1, true)
								and text:find("-old", 1, true)
								and text:find("+new", 1, true),
							text
						)
						assert(cats == 0 and reads == 0, "metadata read file content")
						assert(s.preview_result.loaded.metadata and not s.preview_result.loaded.text)
						common.command, common.read_file = command, read
						vim.cmd("LazyVCS compare metadata")
						ctx.wait_for(function()
							return s.mode == "message" and not s.preview_job
						end, "return to text", 15000)
						local reason = table.concat(api.nvim_buf_get_lines(s.left, 0, -1, false), "\n")
						assert(reason:find(oversized and "1 MiB" or "Binary", 1, true), reason)
					end, debug.traceback)
					common.command, common.read_file = command, read
					compare.close(s)
					assert(ok, err)
				end
			end,
		},

		{
			"test_svn_compare_type_replacements_coalesce_review_rows",
			function()
				require("lazyvcs.commands").setup()
				for _, directory_before in ipairs({ true, false }) do
					local f = h.make_svn_fixture()
					h.exec({ "svn", "revert", f.file }, f.root)
					if directory_before then
						h.exec({ "svn", "mkdir", "node" }, f.root)
						h.write_file(f.root .. "/node/child", "child\n")
						h.exec({ "svn", "add", "node/child" }, f.root)
					else
						h.write_file(f.root .. "/node", "before\n")
						h.exec({ "svn", "add", "node" }, f.root)
					end
					h.exec({ "svn", "propset", "custom:review", "before", "node" }, f.root)
					h.exec({ "svn", "commit", "-m", "add node" }, f.root)
					h.exec({ "svn", "update" }, f.root)
					h.exec({ "svn", "rm", "node" }, f.root)
					if directory_before then
						h.write_file(f.root .. "/node", "after\n")
						h.exec({ "svn", "add", "node" }, f.root)
					else
						h.exec({ "svn", "mkdir", "node" }, f.root)
					end
					h.exec({ "svn", "propset", "custom:review", "after", "node" }, f.root)
					h.write_file(f.file, "changed\n")
					local s =
						assert(compare.open({ editable = false, path = f.root, base = h.file_url(f.repo) .. "@2" }))
					local ok, err = xpcall(function()
						ready(s)
						local nodes = {}
						for _, item in ipairs(s.items) do
							if item.relpath == "node" then
								nodes[#nodes + 1] = item
							end
						end
						assert(#nodes == 1, "replacement produced " .. #nodes .. " rows for node")
						local node = nodes[1]
						assert(
							node.status == "R"
								and node.kind_before == (directory_before and "dir" or "file")
								and node.kind_after == (directory_before and "file" or "dir")
						)
						api.nvim_set_current_win(s.sidewin)
						api.nvim_win_set_cursor(s.sidewin, { s.row_by_path.node, 0 })
						keys("P")
						ctx.wait_for(function()
							return s.shown_item == node and s.preview_result
						end, "replacement preview", 15000)
						local result = s.preview_result
						assert(result.left[1] == (directory_before and "Directory: node" or "before"))
						assert(result.right[1] == (directory_before and "after" or "Directory: node"))
						local patch = table.concat(result.properties or {}, "\n")
						assert(
							patch:find("custom:review", 1, true)
								and patch:find("-before", 1, true)
								and patch:find("+after", 1, true),
							patch
						)
						if directory_before then
							assert(s.row_by_path["node/child"], "deleted child disappeared")
						end
						for _, mapping in ipairs({ "]b", "[b" }) do
							local seen = {}
							for _ = 1, #s.items do
								local previous = s.shown_item
								keys(mapping)
								ctx.wait_for(function()
									return s.shown_item ~= previous and s.preview_result
								end, "file navigation", 15000)
								local item = s.shown_item
								assert(not seen[item.relpath], "navigation repeated a row")
								seen[item.relpath] = true
								assert(
									s.rows[api.nvim_win_get_cursor(s.sidewin)[1]] == item,
									"sidebar cursor disagrees"
								)
								local ns = api.nvim_get_namespaces().lazyvcs_compare_marker
								local marks = api.nvim_buf_get_extmarks(s.sidebar, ns, 0, -1, {})
								assert(
									#marks == 1 and marks[1][2] + 1 == s.row_by_path[item.relpath],
									"marker disagrees"
								)
							end
						end
						local path, snapshot = s.shown_item.relpath, s.snapshot
						keys(":LazyVCS compare refresh<CR>")
						ctx.wait_for(function()
							return s.snapshot and s.snapshot ~= snapshot and s.preview_result
						end, "refresh", 15000)
						assert(s.shown_item.relpath == path, "refresh lost selection")
					end, debug.traceback)
					compare.close(s)
					assert(ok, err)
				end
			end,
		},
	}
	return cases
end
