return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, provider = require("lazyvcs.compare"), require("lazyvcs.backends.compare_svn")
	local function await(start)
		local done, value, failure = false, nil, nil
		start(function(result, err)
			done, value, failure = true, result, err
		end)
		ctx.wait_for(function()
			return done
		end, "SVN metadata did not load", 15000)
		return value, failure
	end
	local function contains(lines, text)
		return lines and table.concat(lines, "\n"):find(text, 1, true)
	end
	return {
		{
			"test_svn_compare_added_file_metadata_includes_properties",
			function()
				local f = h.make_svn_fixture()
				for _, path in ipairs({ "added.txt", "plain.txt", "untracked.txt" }) do
					h.write_file(f.root .. "/" .. path, "added text\n")
				end
				h.exec({ "svn", "add", "added.txt", "plain.txt" }, f.root)
				h.exec({ "svn", "propset", "svn:eol-style", "native", "added.txt" }, f.root)
				h.exec({ "svn", "propset", "svn:executable", "*", "added.txt" }, f.root)
				h.write_file(f.file, "one\ntwo\nthree\n")
				h.exec({ "svn", "propset", "custom:file", "value", "sample.txt" }, f.root)
				local snapshot = assert(await(function(done)
					provider.resolve({ root = f.root }, h.file_url(f.repo) .. "@1", done)
				end))
				local items = assert(await(function(done)
					provider.list(snapshot, true, done)
				end))
				local paths = {}
				for _, item in ipairs(items) do
					paths[item.relpath] = item
				end
				local function preview(name)
					return await(function(done)
						provider.preview(snapshot, assert(paths[name]), done)
					end)
				end
				local result, err = preview("added.txt")
				assert(result, err)
				assert(contains(result.properties, "svn:eol-style"), "added SVN properties missing from metadata")
				assert(contains(result.properties, "svn:executable"))
				assert(#result.left == 0 and result.right[1] == "added text")
				assert(not assert(preview("plain.txt")).properties, "property-free addition has metadata")
				assert(not assert(preview("untracked.txt")).properties, "untracked file has property metadata")
				assert(
					contains(assert(preview("sample.txt")).right, "custom:file"),
					"file property-only preview changed"
				)
				local s = assert(compare.open({ path = f.root, base = h.file_url(f.repo) .. "@1" }))
				ctx.wait_for(function()
					return s.preview_result
				end, "SVN comparison did not load", 15000)
				api.nvim_set_current_win(s.sidewin)
				api.nvim_win_set_cursor(s.sidewin, { s.row_by_path["added.txt"], 0 })
				s.actions.metadata()
				ctx.wait_for(function()
					return s.mode == "metadata" and s.shown_item.relpath == "added.txt"
				end, "added metadata UI did not load", 15000)
				assert(contains(api.nvim_buf_get_lines(s.left, 0, -1, false), "svn:eol-style"))
				compare.refresh(s)
				ctx.wait_for(function()
					return s.preview_result
				end, "SVN refresh did not load", 15000)
				assert(contains(s.preview_result.properties, "svn:executable"), "refresh lost added properties")
				compare.close(s)
				local large = h.tempdir() .. "/large-property"
				h.write_file(large, string.rep("x", 1024 * 1024 + 1))
				h.exec({ "svn", "propset", "custom:large", "--file", large, "added.txt" }, f.root)
				result, err = preview("added.txt")
				assert(
					result and result.right[1] == "added text",
					"oversized optional properties discarded valid text: " .. tostring(err)
				)
				assert(not result.properties and contains(result.details, "1 MiB"), "property limit was not reported")
			end,
		},
	}
end
