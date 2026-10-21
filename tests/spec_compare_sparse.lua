return function(ctx)
	local h, api = ctx.helpers, vim.api
	local provider = require("lazyvcs.backends.compare_git")
	local common, util = require("lazyvcs.backends.comparison"), require("lazyvcs.util")
	local function await(start)
		local done, value, failure = false, nil, nil
		start(function(result, err)
			done, value, failure = true, result, err
		end)
		ctx.wait_for(function()
			return done
		end, "sparse preview did not complete", 15000)
		return value, failure
	end
	local function guarded(fn)
		return function()
			local start, read = util.system_start, common.read_file
			local ok, err = xpcall(fn, debug.traceback)
			util.system_start, common.read_file = start, read
			pcall(require("lazyvcs.compare").close)
			assert(ok, err)
		end
	end
	return {
		{
			"test_core_compare_sparse_preview_uses_full_byte_limit",
			guarded(function()
				local f = h.make_git_fixture()
				vim.fn.mkdir(f.root .. "/visible", "p")
				vim.fn.mkdir(f.root .. "/excluded", "p")
				h.write_file(f.root .. "/visible/file", "visible")
				local sizes = { 700001, common.max_file_bytes, common.max_file_bytes + 1 }
				for _, size in ipairs(sizes) do
					h.write_file(f.root .. "/excluded/" .. size, "base")
				end
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "base" }, f.root)
				for _, size in ipairs(sizes) do
					h.write_file(f.root .. "/excluded/" .. size, string.rep("x", size - 1) .. "\n")
				end
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "large contents" }, f.root)
				h.exec({ "git", "sparse-checkout", "init", "--cone" }, f.root)
				h.exec({ "git", "sparse-checkout", "set", "visible" }, f.root)
				local snapshot = assert(await(function(done)
					provider.resolve({ root = f.root }, "HEAD^", done)
				end))
				for _, size in ipairs(sizes) do
					local path = "excluded/" .. size
					local result, err = await(function(done)
						provider.preview(snapshot, { relpath = path, status = "M" }, done)
					end)
					if size <= common.max_file_bytes then
						assert(result, "supported sparse preview rejected: " .. tostring(err))
						assert(
							table.concat(result.right, "\n") .. "\n" == string.rep("x", size - 1) .. "\n",
							"sparse preview bytes changed"
						)
						assert(result.right_label == "INDEX (sparse checkout)")
					else
						assert(
							not result and err and err:find("1 MiB", 1, true),
							"oversized sparse preview was accepted"
						)
					end
					assert(not vim.uv.fs_lstat(f.root .. "/" .. path), "sparse preview materialized the file")
				end
			end),
		},
		{
			"test_core_compare_sparse_omitted_path_uses_index",
			guarded(function()
				local f = h.make_git_fixture()
				vim.fn.mkdir(f.root .. "/visible", "p")
				vim.fn.mkdir(f.root .. "/excluded", "p")
				local path = "excluded/[literal]$HOME.txt"
				for _, name in ipairs({ path, "visible/file.txt", "excluded/binary.txt", "excluded/large.txt" }) do
					h.write_file(f.root .. "/" .. name, "base\n")
				end
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "sparse base" }, f.root)
				h.write_file(f.root .. "/" .. path, "indexed change\n")
				h.write_file(f.root .. "/visible/file.txt", "visible change\n")
				local function bytes(name, data)
					local file = assert(io.open(f.root .. "/" .. name, "wb"))
					file:write(data)
					file:close()
				end
				bytes("excluded/binary.txt", "binary\0contents")
				bytes("excluded/large.txt", string.rep("x", common.max_file_bytes + 1))
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "sparse changes" }, f.root)
				h.exec({ "git", "sparse-checkout", "init", "--cone" }, f.root)
				h.exec({ "git", "sparse-checkout", "set", "visible" }, f.root)
				assert(not vim.uv.fs_lstat(f.root .. "/" .. path))
				local snapshot, err = await(function(done)
					provider.resolve({ root = f.root }, "HEAD^", done)
				end)
				assert(snapshot, err)
				local item = { relpath = path, status = "M" }
				local function preview(value)
					return await(function(done)
						provider.preview(snapshot, value or item, done)
					end)
				end
				local result, failure = preview()
				assert(result, "omitted sparse file unavailable: " .. tostring(failure))
				assert(vim.deep_equal(result.left, { "base" }) and vim.deep_equal(result.right, { "indexed change" }))
				assert(result.right_label == "INDEX (sparse checkout)" and result.right_source.kind == "index")
				assert(not vim.uv.fs_lstat(f.root .. "/" .. path), "preview materialized an omitted file")
				local oid = result.right_source.oid
				local compare = require("lazyvcs.compare")
				local s = assert(compare.open({ editable = false, path = f.root, base = "HEAD^" }))
				ctx.wait_for(function()
					return s.snapshot and not s.job and not s.preview_job
				end, "sparse UI did not load", 15000)
				api.nvim_set_current_win(s.sidewin)
				api.nvim_win_set_cursor(s.sidewin, { s.row_by_path[path], 0 })
				s.actions.preview()
				ctx.wait_for(function()
					return s.preview_result
				end, "sparse UI preview did not load", 15000)
				assert(api.nvim_buf_get_lines(s.right, 0, 1, false)[1] == "indexed change")
				assert(tostring(util.get_win_option(s.rightwin, "winbar")):find("INDEX (sparse checkout)", 1, true))
				compare.close(s)
				vim.fn.mkdir(f.root .. "/excluded", "p")
				h.write_file(f.root .. "/" .. path, "present bytes\n")
				result = assert(preview())
				assert(result.right[1] == "present bytes" and result.right_label == "SAVED WORKTREE")
				assert(os.remove(f.root .. "/" .. path))
				for _, name in ipairs({ "excluded/binary.txt", "excluded/large.txt" }) do
					local value = preview({ relpath = name, status = "M" })
					assert(not value, "invalid index contents bypassed preview bounds")
				end
				assert(os.remove(f.file))
				assert(not preview({ relpath = "sample.txt", status = "M" }), "ordinary missing file used the index")
				result = assert(preview({ relpath = "sample.txt", status = "D" }))
				assert(#result.right == 0 and result.right_label == "SAVED WORKTREE")
				local read = common.read_file
				---@diagnostic disable-next-line: duplicate-set-field
				common.read_file = function(_, _, done)
					done(nil, "EACCES: denied")
				end
				result, failure = preview()
				common.read_file = read
				assert(not result and failure and failure:find("EACCES", 1, true), "non-ENOENT failure used the index")
				local start = util.system_start
				local held, task, delivered
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					return start(args, opts, function(raw)
						if args[3] == "cat-file" then
							held = function()
								done(raw)
							end
						else
							done(raw)
						end
					end)
				end
				task = provider.preview(snapshot, item, function()
					delivered = true
				end)
				ctx.wait_for(function()
					return held
				end, "index read did not run", 15000)
				task:cancel()
				held()
				util.system_start = start
				vim.wait(30)
				assert(not delivered, "cancelled sparse preview delivered")
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					return start(args, opts, function(raw)
						if args[3] == "cat-file" then
							h.exec({ "git", "update-index", "--force-remove", "--", path }, f.root)
						end
						done(raw)
					end)
				end
				result, failure = preview()
				util.system_start = start
				assert(
					not result and failure and failure:find("Index changed", 1, true),
					"changed index validated stale bytes"
				)
				assert(not preview(), "absent stage zero used stale contents")
				h.exec({ "git", "update-index", "--add", "--cacheinfo", "120000," .. oid .. "," .. path }, f.root)
				h.exec({ "git", "update-index", "--skip-worktree", "--", path }, f.root)
				assert(not preview(), "index symlink was treated as a regular file")
				local commit = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root))
				h.exec({ "git", "update-index", "--cacheinfo", "160000," .. commit .. "," .. path }, f.root)
				h.exec({ "git", "update-index", "--skip-worktree", "--", path }, f.root)
				assert(not preview(), "index gitlink was treated as a regular file")
				local stages = vim.system({ "git", "update-index", "--index-info" }, {
					cwd = f.root,
					stdin = "0 "
						.. string.rep("0", #oid)
						.. "\t"
						.. path
						.. "\n100644 "
						.. oid
						.. " 1\t"
						.. path
						.. "\n100644 "
						.. oid
						.. " 2\t"
						.. path
						.. "\n",
				}):wait()
				assert(stages.code == 0, stages.stderr)
				assert(not preview(), "unmerged index entries were treated as stage zero")
			end),
		},
	}
end
