return function(ctx)
	local h = ctx.helpers
	local function check(vcs, f, expected, selected)
		local backend = require("lazyvcs.backends." .. vcs)
		local function paths(items)
			local out = {}
			for _, item in ipairs(items) do
				out[#out + 1] = item.path
			end
			table.sort(out)
			assert(vim.deep_equal(out, expected), "picker paths: " .. vim.inspect(out))
		end
		paths(assert(backend.changed_files(f.root)))
		local done, result, err
		backend.changed_files_async(f.root, function(value, failure)
			result, err, done = value, failure, true
		end)
		ctx.wait_for(function()
			return done
		end, "changed files did not complete", 15000)
		paths(assert(result, err))
		if selected then
			require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
			vim.cmd.edit(vim.fn.fnameescape(f.file))
			local select, picked = vim.ui.select, false
			vim.ui.select = function(items, _, cb)
				paths(items)
				for _, item in ipairs(items) do
					if item.path == selected then
						cb(item)
						picked = true
						return
					end
				end
			end
			local ok, failure = pcall(function()
				vim.cmd("LazyVCS files")
				ctx.wait_for(function()
					return picked
				end, "picker did not select", 15000)
				assert(vim.api.nvim_buf_get_name(0) == f.root .. "/" .. selected)
				assert(
					vim.deep_equal(
						vim.api.nvim_buf_get_lines(0, 0, -1, false),
						vim.fn.readfile(f.root .. "/" .. selected)
					)
				)
			end)
			vim.ui.select = select
			assert(ok, failure)
		end
	end
	return {
		{
			"test_svn_windows_roots_normalize_native_probe_output",
			function()
				if vim.fn.executable("svn") ~= 1 then
					error({ lazyvcs_skip = "svn unavailable" }, 0)
				end
				local util, process = require("lazyvcs.util"), require("lazyvcs.backends.process")
				local svn = require("lazyvcs.backends.svn")
				local has, normalize, realpath = vim.fn.has, vim.fs.normalize, vim.uv.fs_realpath
				local system, bytes = util.system, process.bytes
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(feature)
					return feature == "win32" and 1 or has(feature)
				end
				-- Exercise Neovim's real Windows normalization on every host.
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fs.normalize = function(path, opts)
					return normalize(path, vim.tbl_extend("force", opts or {}, { win = true }))
				end
				---@diagnostic disable-next-line: duplicate-set-field
				vim.uv.fs_realpath = function(path)
					assert(path == "C:/wc", "native root reached realpath without normalization")
					return [[C:\wc]]
				end
				local native = "C:\\wc\r\n"
				---@diagnostic disable-next-line: duplicate-set-field
				util.system = function()
					return { stdout = native }
				end
				---@diagnostic disable-next-line: duplicate-set-field
				process.bytes = function(_, _, cb)
					cb(native)
					return {}
				end
				local ok, err = pcall(function()
					assert(process.root_output(native) == "C:/wc")
					assert(svn.root("C:/wc/file.txt") == "C:/wc", "sync SVN root was not normalized")
					local result, failure, done
					svn.probe_async("C:/wc/file.txt", function(value, why)
						result, failure, done = value, why, true
					end)
					ctx.wait_for(function()
						return done
					end, "native SVN root probe did not complete")
					assert(result and result.root == "C:/wc", failure or "async SVN root was not normalized")
				end)
				vim.fn.has, vim.fs.normalize, vim.uv.fs_realpath = has, normalize, realpath
				util.system, process.bytes = system, bytes
				assert(ok, err)
			end,
		},
		{
			"test_svn_windows_status_paths_use_forward_slashes",
			function()
				local has = vim.fn.has
				local common = require("lazyvcs.backends.comparison")
				local command = common.command
				---@diagnostic disable-next-line: duplicate-set-field
				vim.fn.has = function(feature)
					return feature == "win32" and 1 or has(feature)
				end
				local ok, err = pcall(function()
					local raw = [[<status>
<entry path="external"><wc-status item="external"/></entry>
<entry path="external\file.txt"><wc-status item="modified"/></entry>
<entry path="sub\nested"><wc-status item="normal" switched="true"/></entry>
</status>]]
					local entries = require("lazyvcs.backends.xml").parse_status(raw)
					assert(entries[2].path == "external/file.txt", "Windows status separator leaked")
					assert(entries[3].path == "sub/nested" and entries[3].switched)
					local items = require("lazyvcs.backends.svn").parse_status(raw, "C:/wc")
					assert(#items == 1 and items[1].path == "external/file.txt")
					assert(items[1].absolute_path == "C:/wc/external/file.txt")
					local info = require("lazyvcs.backends.xml").parse_info(
						[[<info><entry path="sub\file.txt" kind="file" revision="1"><url>file:///C:/repo/sub/file.txt</url></entry></info>]]
					)
					assert(info and info.path == "sub/file.txt" and info.url == "file:///C:/repo/sub/file.txt")
					for _, root in ipairs({ "C:/wc", "c:/wc", [[c:\wc]] }) do
						for _, path in ipairs({ [[C:\wc\sub\File.txt]], [[c:\wc\sub\File.txt]] }) do
							---@diagnostic disable-next-line: duplicate-set-field
							common.command = function(_, _, _, cb)
								cb(
									'<diff><paths><path item="modified" kind="file" props="none">'
										.. path
										.. "</path></paths></diff>"
								)
							end
							local comparison, failure
							require("lazyvcs.backends.compare_svn").list(
								{ root = root, url = "file:///C:/repo", revision = "1" },
								false,
								function(value, why)
									comparison, failure = value, why
								end
							)
							ctx.wait_for(function()
								return comparison ~= nil or failure ~= nil
							end, "Windows comparison paths did not settle")
							assert(comparison and #comparison == 1 and comparison[1].relpath == "sub/File.txt", failure)
						end
					end
					for _, path in ipairs({ "C:/wc-other/File.txt", "file:///c:/repo/File.txt" }) do
						---@diagnostic disable-next-line: duplicate-set-field
						common.command = function(_, _, _, cb)
							cb('<diff><paths><path item="modified" kind="file">' .. path .. "</path></paths></diff>")
						end
						local comparison, failure
						require("lazyvcs.backends.compare_svn").list(
							{ root = "c:/wc", url = "file:///C:/repo", revision = "1" },
							false,
							function(value, why)
								comparison, failure = value, why
							end
						)
						assert(not comparison and failure == "SVN returned a path outside the comparison")
					end
				end)
				vim.fn.has, common.command = has, command
				assert(ok, err)
			end,
		},
		{
			"test_core_git_picker_preserves_rename_paths",
			function()
				local f = h.make_git_fixture()
				h.exec({ "git", "reset", "--hard" }, f.root)
				local renamed = vim.fn.has("win32") == 1 and "draft - reviewed.txt" or "draft -> reviewed.txt"
				h.exec({ "git", "mv", "sample.txt", renamed }, f.root)
				h.exec({ "git", "commit", "-m", "arrow" }, f.root)
				h.exec({ "git", "mv", renamed, "final.txt" }, f.root)
				f.file = f.root .. "/final.txt"
				check("git", f, { "final.txt" }, "final.txt")
				local parse = require("lazyvcs.backends.git_status").parse
				local records = assert(parse(" R destination\0source -> original\0 C copy\0original\0?? café.txt\0"))
				assert(records[1].path == "destination" and records[1].renamed_from == "source -> original")
				assert(records[2].renamed_from == "original" and records[3].path == "café.txt")
				assert(parse("R  destination\0") == nil, "truncated rename was accepted")
				assert(parse("?? incomplete") == nil, "unterminated record was accepted")
			end,
		},
		{
			"test_core_git_picker_preserves_backslash_digits",
			function()
				if vim.fn.has("win32") == 1 then
					return
				end
				local f = h.make_git_fixture()
				h.exec({ "git", "reset", "--hard" }, f.root)
				for _, name in ipairs({ "literal\\123.txt", "literal\\999.txt" }) do
					h.write_file(f.root .. "/" .. name, name)
				end
				check("git", f, { "literal\\123.txt", "literal\\999.txt" }, "literal\\999.txt")
			end,
		},
		{
			"test_core_git_picker_enumerates_untracked_files",
			function()
				local f = h.make_git_fixture()
				h.exec({ "git", "reset", "--hard" }, f.root)
				h.write_file(f.root .. "/.git/info/exclude", "*.ignored")
				vim.fn.mkdir(f.root .. "/newdir/deep", "p")
				h.write_file(f.root .. "/newdir/one.txt", "one")
				h.write_file(f.root .. "/newdir/deep/two.txt", "two")
				h.write_file(f.root .. "/newdir/hidden.ignored", "hidden")
				check("git", f, { "newdir/deep/two.txt", "newdir/one.txt" }, "newdir/deep/two.txt")
			end,
		},
		{
			"test_svn_picker_includes_property_changes",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "propset", "custom", "value", f.file }, f.root)
				check("svn", f, { "sample.txt" }, "sample.txt")
				local items = require("lazyvcs.backends.svn").parse_status(
					[[<status>
<entry path="conflict"><wc-status item="normal" props="conflicted"/></entry>
<entry path="tree"><wc-status item="normal" props="none" tree-conflicted="true"/></entry>
<entry path="clean"><wc-status item="normal" props="none"/></entry>
</status>]],
					f.root
				)
				assert(#items == 2 and items[1].status == "C" and items[2].status == "C")
			end,
		},
		{
			"test_svn_picker_filters_external_markers",
			function()
				local f = h.make_svn_fixture()
				h.exec({ "svn", "revert", f.file }, f.root)
				h.exec({ "svn", "mkdir", "source" }, f.root)
				h.write_file(f.root .. "/source/file.txt", "external contents")
				h.exec({ "svn", "add", "source/file.txt" }, f.root)
				h.exec({ "svn", "commit", "-m", "create external source" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				h.exec({ "svn", "propset", "svn:externals", h.file_url(f.repo) .. "/source external", "." }, f.root)
				h.exec({ "svn", "commit", "-m", "configure external" }, f.root)
				h.exec({ "svn", "update" }, f.root)
				check("svn", f, {})
				h.write_file(f.root .. "/external/file.txt", "external edit")
				check("svn", f, { "external/file.txt" }, "external/file.txt")
			end,
		},
	}
end
