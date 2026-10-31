return function(ctx)
	local h, uv, util = ctx.helpers, vim.uv, require("lazyvcs.util")
	local cases, links = {}, {}
	local function link(target, path)
		assert(uv.fs_symlink(target, path, vim.fn.has("win32") == 1 and { junction = true } or nil))
		links[#links + 1] = path
	end
	local function collect(path)
		local out = {}
		require("lazyvcs").patch({
			path = path,
			on_done = function(text, err)
				out.text, out.err, out.done = text, err, true
			end,
		})
		ctx.wait_for(function()
			return out.done
		end, "physical parent patch did not settle", 15000)
		return out
	end
	local function add(name, flag, fn)
		cases[#cases + 1] = {
			"test_patch_physical_case_" .. name .. "_" .. tostring(flag),
			function()
				local saved, start = vim.o.fileignorecase, util.system_start
				vim.o.fileignorecase = flag
				local ok, err = xpcall(fn, function(e)
					return type(e) == "table" and e or debug.traceback(e, 2)
				end)
				vim.o.fileignorecase, util.system_start = saved, start
				for _, path in ipairs(links) do
					if uv.fs_lstat(path) then
						assert(uv.fs_unlink(path) or uv.fs_rmdir(path))
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
	for _, flag in ipairs({ false, true }) do
		add("changed_case_parent", flag, function()
			local f, parent = h.make_git_fixture(), h.tempdir()
			assert(uv.fs_rename(f.root, parent .. "/owned"))
			f.root = parent .. "/owned"
			local other = parent .. "/OWNED"
			local made, why = uv.fs_mkdir(other, 448)
			local first, second = assert(uv.fs_stat(f.root)), uv.fs_stat(other)
			if second and first.dev == second.dev and first.ino == second.ino then
				error({ lazyvcs_skip = "fixture filesystem cannot create distinct case-only directories" }, 0)
			end
			assert(made, why)
			assert(second and (first.dev ~= second.dev or first.ino ~= second.ino))
			vim.fn.mkdir(f.root .. "/loose")
			vim.fn.mkdir(other .. "/loose")
			h.write_file(f.root .. "/loose/child.txt", "original owned bytes\n")
			local foreign = "case sibling fixture " .. vim.fn.sha256(parent) .. "\n"
			h.write_file(other .. "/loose/child.txt", foreign)
			local start, swapped, children = util.system_start, false, 0
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, opts, callback)
				if args[1] == "git" and vim.tbl_contains(args, "--no-index") then
					children = children + 1
				end
				if args[1] == "git" and vim.tbl_contains(args, "ls-files") then
					return start(args, opts, function(result, err, raw)
						assert(uv.fs_rename(f.root .. "/loose", f.root .. "/loose.saved"))
						link(other .. "/loose", f.root .. "/loose")
						swapped = true
						callback(result, err, raw)
					end)
				end
				return start(args, opts, callback)
			end
			local out = collect(f.root)
			assert(swapped, "native enumeration did not reach the swap seam")
			assert(not out.text and out.err, "changed physical case parent was published: " .. tostring(out.text))
			assert(children == 0, "changed physical parent reached the native reader")
		end)
		for _, vcs in ipairs({ "git", "svn" }) do
			for _, alias in ipairs({ false, true }) do
				add(vcs .. (alias and "_alias" or "_normal"), flag, function()
					local f = vcs == "git" and h.make_git_fixture() or h.make_svn_fixture()
					vim.fn.mkdir(f.root .. "/MiXeD")
					h.write_file(f.root .. "/MiXeD/NativeCase.txt", "native case bytes\n")
					local selected = f.root
					if alias then
						selected = h.tempdir() .. "/directory alias"
						link(f.root, selected)
					end
					local out = collect(selected)
					assert(out.text and out.text:find("+native case bytes", 1, true), out.err)
					assert(out.text:find("MiXeD/NativeCase.txt", 1, true), "native entry spelling changed")
				end)
			end
		end
	end
	return cases
end
