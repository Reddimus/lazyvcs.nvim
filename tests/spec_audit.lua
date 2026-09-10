return function(ctx)
	return {
		{
			"test_svn_comparison_filters_nested_ignores_and_shows_properties",
			function()
				local fixture = ctx.helpers.make_svn_fixture()
				vim.fn.mkdir(fixture.root .. "/new-dir")
				for _, name in ipairs({ "keep.txt", "ignored.o", "ignored.trash", "two words" }) do
					ctx.helpers.write_file(fixture.root .. "/new-dir/" .. name, "content\n")
				end
				ctx.helpers.exec(
					{ "svn", "propset", "svn:global-ignores", "*.trash\ntwo words", fixture.root },
					fixture.root
				)
				ctx.helpers.exec({ "svn", "propset", "custom", "value", fixture.file }, fixture.root)
				local provider = require("lazyvcs.backends.comparison").provider("svn")
				local done, items, failure, snapshot
				provider.context({ root = fixture.root, vcs = "svn" }, function(context, context_err)
					if not context then
						failure, done = context_err, true
						return
					end
					provider.resolve({ root = fixture.root, vcs = "svn" }, context.suggestion, function(value, err)
						if not value then
							failure, done = err, true
							return
						end
						snapshot = value
						provider.list(value, true, function(result, list_err)
							items, failure, done = result, list_err, true
						end)
					end)
				end)
				ctx.wait_for(function()
					return done
				end, "SVN comparison timed out", 15000)
				assert(items, failure)
				local found = {}
				for _, item in ipairs(items) do
					found[item.relpath] = item
				end
				assert(
					found["new-dir/keep.txt"]
						and not found["new-dir/ignored.o"]
						and not found["new-dir/ignored.trash"]
						and not found["new-dir/two words"],
					vim.inspect(items)
				)
				done = false
				provider.preview(snapshot, assert(found["sample.txt"]), function(result, err)
					items, failure, done = result, err, true
				end)
				ctx.wait_for(function()
					return done
				end, "SVN property preview timed out", 15000)
				assert(
					items and items.properties and table.concat(items.properties, "\n"):match("custom"),
					failure or vim.inspect(items)
				)
			end,
		},
		{
			"test_git_blame_unborn_index_is_uncommitted",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				ctx.helpers.exec({ "git", "checkout", "--orphan", "unborn" }, fixture.root)
				local backend = require("lazyvcs.backends.git")
				local done, entries, failure
				backend.blame_lines_async(fixture.file, function(lines, err)
					entries, failure, done = backend.parse_blame_entries(lines), err, true
				end, { contents = "unsaved\nline\n" })
				ctx.wait_for(function()
					return done
				end, "Git blame timed out", 15000)
				assert(
					not failure and #entries == 2 and entries[1].uncommitted and entries[2].uncommitted,
					failure or vim.inspect(entries)
				)
			end,
		},
		{
			"test_git_staged_refresh_preserves_head_to_index",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				ctx.helpers.exec({ "git", "add", "sample.txt" }, fixture.root)
				require("lazyvcs").setup({ signs = { enabled = false }, blame = { persist = false } })
				local done, loaded, err
				require("lazyvcs.backends").load_diff_target_async({
					vcs = "git",
					root = fixture.root,
					path = fixture.file,
					relpath = "sample.txt",
					section = "staged",
					status = "M",
				}, function(value, failure)
					loaded, err, done = value, failure, true
				end)
				ctx.wait_for(function()
					return done
				end)
				assert(loaded, err)
				require("lazyvcs.actions").open_target(loaded)
				local session = require("lazyvcs.state").current()
				assert(session and session.base_lines[2] == "two")
				require("lazyvcs.actions").refresh_current()
				ctx.wait_for(function()
					return session.refresh_job == nil
				end)
				assert(session.base_lines[2] == "two" and #session.hunks == 1)
				require("lazyvcs.actions").close()
			end,
		},
		{
			"test_backend_probe_shared_cancellation_preserves_other_subscriber",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				local backends = require("lazyvcs.backends")
				backends.invalidate()
				local done, resolved
				local first = backends.resolve_async(fixture.file, function()
					error("cancelled subscriber ran")
				end)
				backends.resolve_async(fixture.file, function(value)
					resolved, done = value, true
				end)
				first:kill()
				ctx.wait_for(function()
					return done
				end)
				assert(resolved and resolved.name == "git")
			end,
		},
		{
			"test_git_signs_delegate_without_loading_base",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				local backends = require("lazyvcs.backends")
				local old, old_gitsigns = backends.load_base_async, package.loaded.gitsigns
				package.loaded.gitsigns = {}
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_base_async = function()
					error("delegated signs loaded content")
				end
				local ok, err = pcall(function()
					require("lazyvcs").setup({ use_gitsigns = true, blame = { persist = false } })
					vim.cmd.edit(vim.fn.fnameescape(fixture.file))
					local done
					require("lazyvcs.signs").refresh(0, true, function()
						done = true
					end)
					ctx.wait_for(function()
						return done
					end)
				end)
				backends.load_base_async, package.loaded.gitsigns = old, old_gitsigns
				assert(ok, err)
			end,
		},
		{
			"test_git_comparison_saved_net_changes_and_readonly_ui",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				ctx.helpers.write_file(fixture.root .. "/new.txt", "new file\n")
				local origin = vim.api.nvim_get_current_win()
				local compare = require("lazyvcs.compare")
				local session = compare.open({ path = fixture.root, base = "HEAD" })
				ctx.wait_for(function()
					return session.snapshot ~= nil or session.message:match("fatal")
				end)
				assert(session.snapshot, session.message)
				assert(#session.items == 2, vim.inspect(session.items))
				ctx.wait_for(function()
					return session.preview_job == nil
				end)
				assert(not vim.bo[session.left].modifiable and not vim.bo[session.right].modifiable)
				assert(vim.api.nvim_buf_get_lines(session.right, 0, -1, false)[1] == "new file")
				compare.close(session)
				assert(vim.api.nvim_get_current_win() == origin)
			end,
		},
		{
			"test_git_comparison_deduplicates_index_delete_recreated_path",
			function()
				local fixture = ctx.helpers.make_git_fixture()
				ctx.helpers.exec({ "git", "restore", "--", "sample.txt" }, fixture.root)
				ctx.helpers.exec({ "git", "rm", "--cached", "sample.txt" }, fixture.root)
				local provider = require("lazyvcs.backends.comparison").provider("git")
				local done, items, err
				provider.resolve({ root = fixture.root, vcs = "git" }, "HEAD", function(snapshot, failure)
					if not snapshot then
						err, done = failure, true
						return
					end
					provider.list(snapshot, true, function(result, list_err)
						items, err, done = result, list_err, true
					end)
				end)
				ctx.wait_for(function()
					return done
				end)
				assert(items and #items == 0, err or vim.inspect(items))
			end,
		},
		{
			"test_svn_comparison_explicit_branch_and_untracked",
			function()
				local fixture = ctx.helpers.make_svn_switch_fixture()
				ctx.helpers.write_file(fixture.root .. "/new.txt", "new\n")
				local provider = require("lazyvcs.backends.comparison").provider("svn")
				local done, items, err, snapshot
				provider.resolve(
					{ root = fixture.root, vcs = "svn" },
					fixture.release_url .. "@1",
					function(value, failure)
						snapshot = value
						if not value then
							err, done = failure, true
							return
						end
						provider.list(value, true, function(result, list_err)
							items, err, done = result, list_err, true
						end)
					end
				)
				ctx.wait_for(function()
					return done
				end)
				assert(items and #items >= 2, err or vim.inspect(items))
				local sample
				for _, item in ipairs(items) do
					if item.relpath == "sample.txt" then
						sample = item
					end
				end
				assert(sample, vim.inspect(items))
				done = false
				provider.preview(snapshot, sample, function(result, failure)
					err = failure
					items = result
					done = true
				end)
				ctx.wait_for(function()
					return done
				end)
				assert(items and items.left[1] == "release" and items.right[1] == "trunk", err or vim.inspect(items))
			end,
		},
		{
			"test_svn_blame_maps_saved_and_unsaved_lines",
			function()
				local fixture = ctx.helpers.make_svn_fixture()
				local done, entries, err
				local backend = require("lazyvcs.backends.svn")
				backend.blame_lines_async(fixture.file, function(lines, failure)
					entries, err, done = backend.parse_blame_entries(lines), failure, true
				end, { contents = "inserted\none\nchanged\nthree\n" })
				ctx.wait_for(function()
					return done
				end)
				assert(not err, err)
				assert(#entries == 4 and entries[1].uncommitted and entries[3].uncommitted)
				assert(entries[2].revision == "1" and entries[4].revision == "1")
			end,
		},
		{
			"test_alignment_large_file_only_allocates_viewport",
			function()
				local units = require("lazyvcs.align").pair_units({}, 200000, 200000, 200000, 200000, 199921, 199921)
				assert(#units == 80 and units[1].base[1] == 199921)
			end,
		},
		{
			"test_svn_literal_at_filename",
			function()
				local fixture = ctx.helpers.make_svn_fixture()
				local path = fixture.root .. "/a@b.txt"
				ctx.helpers.write_file(path, "literal\n")
				ctx.helpers.exec({ "svn", "add", path .. "@" }, fixture.root)
				ctx.helpers.exec({ "svn", "commit", "-m", "literal", path .. "@" }, fixture.root)
				local done, result, err
				require("lazyvcs.backends.svn").load_async(path, function(value, failure)
					result, err, done = value, failure, true
				end)
				ctx.wait_for(function()
					return done
				end)
				assert(result and result.base_lines[1] == "literal", err)
			end,
		},
		{
			"test_command_lines_reject_truncated_success",
			function()
				local util = require("lazyvcs.util")
				local done, lines, err
				util.system_lines_start({ vim.v.progpath, "--headless", "-u", "NONE", "-l", "-" }, {
					stdin = 'io.stdout:write(string.rep("line\\n", 1000))',
					output_limit_bytes = 512,
				}, function(value, failure)
					lines, err, done = value, failure, true
				end)
				ctx.wait_for(function()
					return done
				end)
				assert(lines == nil and err and err:match("truncated"), "partial contents must be rejected")
			end,
		},
		{
			"test_git_blame_sha256_headers",
			function()
				local oid = string.rep("a", 64)
				local entries = require("lazyvcs.backends.git").parse_blame_entries({
					oid .. " 1 1 1",
					"author Someone",
					"author-time 0",
					"\tcontent",
				})
				assert(#entries == 1 and entries[1].full_revision == oid)
			end,
		},
		{
			"test_svn_blame_ignored_file_is_ineligible",
			function()
				local fixture = ctx.helpers.make_svn_fixture()
				local path = fixture.root .. "/ignored.txt"
				ctx.helpers.write_file(path, "ignored\n")
				ctx.helpers.exec({ "svn", "propset", "svn:ignore", "ignored.txt", fixture.root }, fixture.root)
				local done, lines, err
				require("lazyvcs.backends.svn").blame_lines_async(path, function(value, failure)
					lines, err, done = value, failure, true
				end)
				ctx.wait_for(function()
					return done
				end)
				assert(
					lines == nil and err == nil,
					"ignored files should have no blame and no error: " .. tostring(err)
				)
			end,
		},
	}
end
