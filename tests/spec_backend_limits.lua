return function(ctx)
	return {
		{
			"test_svn_xml_attributes_consume_quoted_values_once",
			function()
				local xml = require("lazyvcs.backends.xml")
				local attrs =
					xml.attributes([[path="value fake='wrong' &amp; more" other='say fake2="wrong"' final="ok"]])

				local function elapsed(size)
					local tag = 'path="' .. string.rep("a", size) .. '" item="modified"'
					local start = vim.uv.hrtime()
					for _ = 1, 600 do
						assert(xml.attributes(tag).path == string.rep("a", size))
					end
					return vim.uv.hrtime() - start
				end
				elapsed(64)
				local short, long = elapsed(64), elapsed(254)
				assert(long / short < 8, "XML attribute scaling exceeded eightfold")
				assert(attrs.fake == nil and attrs.fake2 == nil, "XML parsed an assignment inside a quoted value")
				assert(
					attrs.path == "value fake='wrong' & more"
						and attrs.other == 'say fake2="wrong"'
						and attrs.final == "ok"
				)
			end,
		},
		{
			"test_core_git_recreated_files_use_bounded_batches",
			function()
				local h = ctx.helpers
				local f = h.make_git_fixture()
				h.exec({ "git", "reset", "--hard" }, f.root)
				local names =
					{ "one.txt", "two.txt", "three.txt", vim.fn.has("win32") == 1 and "four.txt" or "four\nline.txt" }
				for _, name in ipairs(names) do
					h.write_file(f.root .. "/" .. name, "base")
				end
				if vim.fn.has("win32") == 0 then
					h.exec({ "git", "config", "filter.upper.clean", "tr a-z A-Z" }, f.root)
					h.write_file(f.root .. "/.gitattributes", "two.txt filter=upper")
				end
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "collision bases" }, f.root)
				h.exec({ "git", "rm", "--cached", "--", unpack(names) }, f.root)
				local common = require("lazyvcs.backends.comparison")
				local command, count = common.command, 0
				---@diagnostic disable-next-line: duplicate-set-field
				common.command = function(...)
					count = count + 1
					return command(...)
				end
				local function discover()
					local done, value, err
					require("lazyvcs.backends.compare_git").list(
						{ root = f.root, vcs = "git", revision = "HEAD" },
						true,
						function(items, failure)
							value, err, done = items, failure, true
						end
					)
					ctx.wait_for(function()
						return done
					end, "recreated file discovery", 15000)
					return assert(value, err)
				end
				local ok, err = pcall(function()
					local items = discover()
					assert(#items == 0, "identical retained files remained in comparison")
					assert(
						count <= 6,
						"recreated files launched " .. count .. " discovery commands; expected at most six"
					)
					h.write_file(f.root .. "/one.txt", "changed")
					if vim.fn.has("win32") == 0 then
						assert(vim.uv.fs_chmod(f.root .. "/three.txt", 493))
					end
					items = discover()
					local paths = {}
					for _, item in ipairs(items) do
						paths[item.relpath] = true
					end
					assert(paths["one.txt"], "changed retained content disappeared")
					if vim.fn.has("win32") == 0 then
						assert(paths["three.txt"], "executable change disappeared")
					end
					local paths_to_remove = { "git", "rm", "--cached", "--" }
					for index = 1, 129 do
						local name = "batch-" .. index .. ".txt"
						h.write_file(f.root .. "/" .. name, "batch")
						paths_to_remove[#paths_to_remove + 1] = name
					end
					h.exec({ "git", "add", "." }, f.root)
					h.exec({ "git", "commit", "-m", "batch cancellation bases" }, f.root)
					h.exec(paths_to_remove, f.root)
					local trees, hashes, cancelled, delivered = 0, 0, false, false
					---@diagnostic disable-next-line: duplicate-set-field
					common.command = function(task, repo, args, cb, opts)
						if vim.tbl_contains(args, "ls-tree") then
							trees = trees + 1
						end
						return command(task, repo, args, function(raw, failure, result)
							if vim.tbl_contains(args, "hash-object") then
								hashes = hashes + 1
								task:kill()
								cancelled = true
							end
							cb(raw, failure, result)
						end, opts)
					end
					require("lazyvcs.backends.compare_git").list(
						{ root = f.root, vcs = "git", revision = "HEAD" },
						true,
						function()
							delivered = true
						end
					)
					ctx.wait_for(function()
						return cancelled
					end, "hash batch cancellation", 15000)
					vim.wait(100, function()
						return false
					end, 10)
					assert(
						trees == 1 and hashes == 1 and not delivered,
						"cancellation started another reconciliation chunk"
					)
				end)
				common.command = command
				assert(ok, err)
			end,
		},
	}
end
