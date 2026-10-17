return function(ctx)
	local h = ctx.helpers
	return {
		{
			"test_git_changed_files_preserves_unmerged_pairs",
			function()
				local git = require("lazyvcs.backends.git")
				local failures = {}
				for _, pair in ipairs({ "DD", "AU", "UA", "UD", "DU", "AA", "UU" }) do
					local item = assert(git.parse_status(pair .. " both.txt\0"))[1]
					if item.status ~= "U" or item.label ~= "conflicted" then
						failures[#failures + 1] = pair .. " -> " .. item.status .. "/" .. item.label
					end
				end
				assert(#failures == 0, table.concat(failures, ", "))
				for pair, expected in pairs({ [" M"] = "M", ["A "] = "A", [" D"] = "D", ["??"] = "?", ["R "] = "R" }) do
					local raw = pair .. " literal\nname\0" .. (expected == "R" and "old\0" or "")
					local item = assert(git.parse_status(raw))[1]
					assert(item.status == expected and item.path == "literal\nname")
				end
				local f = h.make_git_fixture()
				h.exec({ "git", "checkout", "--", "sample.txt" }, f.root)
				h.exec({ "git", "checkout", "-b", "other" }, f.root)
				h.write_file(f.root .. "/both.txt", "other\n")
				h.exec({ "git", "add", "both.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "other" }, f.root)
				h.exec({ "git", "checkout", "-b", "ours", "HEAD~" }, f.root)
				h.write_file(f.root .. "/both.txt", "ours\n")
				h.exec({ "git", "add", "both.txt" }, f.root)
				h.exec({ "git", "commit", "-m", "ours" }, f.root)
				assert(vim.system({ "git", "merge", "other" }, { cwd = f.root }):wait().code == 1)
				local items, done, failure
				require("lazyvcs.backends").changed_files_async(f.file, function(value, err)
					items, done, failure = value, true, err
				end)
				ctx.wait_for(function()
					return done
				end, "conflict status", 15000)
				assert(items, failure)
				assert(items[1].status == "U" and items[1].label == "conflicted")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				local select, picked = vim.ui.select, nil
				vim.ui.select = function(values, _, callback)
					picked = values
					callback(nil)
				end
				local ok, err = pcall(function()
					require("lazyvcs").files()
					ctx.wait_for(function()
						return picked
					end, "files picker", 15000)
					local item = assert(picked)[1]
					assert(item.status == "U" and item.label == "conflicted")
				end)
				vim.ui.select = select
				assert(ok, err)
			end,
		},
	}
end
