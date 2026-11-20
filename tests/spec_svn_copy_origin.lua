return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	return {
		{
			"test_svn_blame_uncommitted_copy_through_symlinked_path",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "directory symlinks need extra privileges on Windows" }, 0)
				end
				local f = h.make_svn_fixture()
				vim.fn.mkdir(f.root .. "/d", "p")
				h.write_file(f.root .. "/d/file.txt", "one\ntwo\n")
				h.exec({ "svn", "add", "--", "d" }, f.root)
				h.exec({ "svn", "commit", "-m", "add directory", "--", "d" }, f.root)
				-- Children of an uncommitted copy find BASE through the copied ancestor.
				h.exec({ "svn", "copy", "d", "d2" }, f.root)
				-- Discovery resolves the root's symlinks; the buffer path keeps them.
				local link = vim.fs.normalize(vim.fn.tempname()) .. "-wc"
				assert(uv.fs_symlink(f.root, link))
				local out = {}
				require("lazyvcs.backends").blame_lines_async(link .. "/d2/file.txt", function(value, err)
					out.value, out.err, out.done = value, err, true
				end)
				ctx.wait_for(function()
					return out.done
				end, "blame through the symlinked path did not settle", 15000)
				uv.fs_unlink(link)
				assert(out.value and #out.value == 2, "blame through the symlinked path failed: " .. tostring(out.err))
			end,
		},
	}
end
