return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local util = require("lazyvcs.util")
	local links = {}
	local function write(path, text)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(text))
		assert(fd:close())
	end
	local function link(target, path, directory)
		local ok, err =
			uv.fs_symlink(target, path, vim.fn.has("win32") == 1 and directory and { junction = true } or nil)
		if not ok and vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "fixture link unavailable: " .. tostring(err) }, 0)
		end
		assert(ok, err)
		links[#links + 1] = path
	end
	local function collect(path, untracked)
		local text, failure, done
		require("lazyvcs").patch({
			path = path,
			include_untracked = untracked,
			on_done = function(value, err)
				text, failure, done = value, err, true
			end,
		})
		ctx.wait_for(function()
			return done
		end, "directory alias patch did not settle", 15000)
		assert(text, failure)
		return text
	end
	local cases = {}
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_directory_" .. name,
			function()
				local ok, err = xpcall(fn, function(value)
					return type(value) == "table" and value or debug.traceback(value, 2)
				end)
				for index = #links, 1, -1 do
					local path = links[index]
					if uv.fs_lstat(path) then
						if not uv.fs_unlink(path) then
							assert(uv.fs_rmdir(path))
						end
					end
				end
				links = {}
				h.cleanup()
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	for _, vcs in ipairs({ "git", "svn" }) do
		for _, untracked in ipairs({ false, true }) do
			case(vcs .. "_root_alias_untracked_" .. tostring(untracked), function()
				local f = vcs == "git" and h.make_git_fixture() or h.make_svn_fixture()
				vim.fn.mkdir(f.root .. "/loose")
				write(f.root .. "/loose/child", "ordinary loose bytes\n")
				local aliases = h.tempdir()
				local root_alias, parent_alias = aliases .. "/root alias", aliases .. "/parent alias"
				link(f.root, root_alias, true)
				link(vim.fs.dirname(f.root), parent_alias, true)
				local through_parent = parent_alias .. "/" .. vim.fs.basename(f.root)
				local native = vcs == "git" and { "git", "rev-parse", "--show-toplevel" }
					or { "svn", "info", "--show-item", "wc-root", "--", root_alias .. "@" }
				local root = h.exec(native, root_alias):gsub("\r?\n$", "")
				assert(util.canonical_path(root) == f.root, "native alias resolved a different repository")
				local diff = vcs == "git" and { "git", "diff", "HEAD" } or { "svn", "diff", "--internal-diff" }
				assert(h.exec(diff, root_alias):find("+changed", 1, true), "native alias diff failed")
				local physical = collect(f.root, untracked)
				assert(physical:find("+changed", 1, true))
				assert((physical:find("+ordinary loose bytes", 1, true) ~= nil) == untracked)
				assert(collect(through_parent, untracked) == physical, "parent alias changed patch bytes")
				assert(collect(root_alias, untracked) == physical, "root alias changed patch bytes")
			end)
		end
		case(vcs .. "_file_link_entry_retarget_and_dangling", function()
			local f = vcs == "git" and h.make_git_fixture() or h.make_svn_fixture()
			local outside = h.tempdir()
			local first, second = outside .. "/first", outside .. "/second"
			local nonce = "FOREIGN CONTENT " .. vim.fn.sha256(outside)
			write(first, nonce .. " first\n")
			write(second, nonce .. " second\n")
			local path = f.root .. "/link"
			local previous
			for _, target in ipairs({ first, second, outside .. "/missing" }) do
				if uv.fs_lstat(path) then
					assert(uv.fs_unlink(path))
				end
				link(target, path, false)
				local text = collect(path, true)
				assert(not text:find(nonce, 1, true), "file link followed foreign content")
				assert(not text:find("+changed", 1, true), "file link selected the whole repository")
				if vcs == "git" then
					assert(text:find("new file mode 120000", 1, true), "file link lost its native entry mode")
					assert(text ~= previous, "retargeted file link retained stale entry bytes")
					previous = text
				else
					assert(text == "", "SVN untracked file link bypassed regular-file-only collection")
				end
				assert(collect(path, false) == "", "untracked file link was included when disabled")
			end
		end)
	end
	return cases
end
