return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local fs, paths = require("lazyvcs.file_io"), require("lazyvcs.backends.patch_path")
	local cases = {}
	local function wait(fn)
		ctx.wait_for(fn, "administration alias check did not settle", 15000)
	end
	local function stat(path)
		local done, entry, failure
		fs.fs_lstat(path, function(err, value)
			done, entry, failure = true, value, err
		end)
		wait(function()
			return done
		end)
		return entry, failure
	end
	local function fixture()
		local f, inner = h.make_git_fixture(), h.make_svn_fixture()
		h.write_file(inner.root .. "/secret.txt", "OWNED_PRISTINE_NONCE\n")
		h.exec({ "svn", "add", "secret.txt" }, inner.root)
		h.exec({ "svn", "commit", "-m", "Owned fixture" }, inner.root)
		h.exec({ "svn", "checkout", "--force", h.file_url(inner.repo), f.root }, f.root)
		assert(uv.fs_unlink(f.root .. "/secret.txt"))
		h.write_file(f.root .. "/ordinary.txt", "OUTER_ORDINARY\n")
		return f
	end
	local function collect(root)
		require("lazyvcs.backends").invalidate()
		local out = {}
		out.task = require("lazyvcs").patch({
			path = root,
			on_done = function(text, err)
				out.text, out.err, out.done = text, err, true
			end,
		})
		return out
	end
	local function finish(out)
		wait(function()
			return out.done
		end)
		return assert(out.text, out.err)
	end
	local function ordinary(text)
		assert(text:find("+OUTER_ORDINARY", 1, true), "ordinary outer file was lost")
		assert(not text:find("OWNED_PRISTINE_NONCE", 1, true), "administrative pristine bytes were exported")
		assert(not text:find(".SVN/", 1, true), "administration alias was exported")
	end
	local function add(name, fn)
		cases[#cases + 1] = {
			"test_patch_admin_alias_" .. name,
			function()
				local realpath, lstat = uv.fs_realpath, fs.fs_lstat
				local ok, err = xpcall(fn, function(e)
					return type(e) == "table" and e or debug.traceback(e, 2)
				end)
				uv.fs_realpath, fs.fs_lstat = realpath, lstat
				h.cleanup()
				if not ok then
					error(err, 0)
				end
			end,
		}
	end
	local function controlled()
		local f, realpath = fixture(), uv.fs_realpath
		if uv.fs_stat(f.root .. "/.SVN") then
			error({ lazyvcs_skip = "controlled distinct-directory alias seam requires a case-sensitive fixture" }, 0)
		end
		vim.fn.mkdir(f.root .. "/.SVN/pristine/aa", "p")
		h.write_file(f.root .. "/.SVN/pristine/aa/secret.svn-base", "OWNED_PRISTINE_NONCE\n")
		-- Recorded case-alias transport only; provider identities remain native.
		---@diagnostic disable-next-line: duplicate-set-field
		uv.fs_realpath = function(path, ...)
			---@diagnostic disable-next-line: return-type-mismatch
			return realpath(path == f.root .. "/.svn" and f.root .. "/.SVN" or path, ...)
		end
		return f
	end
	add("controlled_same_identity_excludes", function()
		local f = controlled()
		ordinary(finish(collect(f.root)))
	end)
	add("distinct_uppercase_names_remain_ordinary", function()
		local f = fixture()
		if uv.fs_stat(f.root .. "/.SVN") then
			error({ lazyvcs_skip = "distinct uppercase ordinary names require a case-sensitive fixture" }, 0)
		end
		vim.fn.mkdir(f.root .. "/.SVN", "p")
		vim.fn.mkdir(f.root .. "/.GIT", "p")
		h.write_file(f.root .. "/.SVN/ordinary", "UPPER_SVN_ORDINARY\n")
		h.write_file(f.root .. "/.GIT/ordinary", "UPPER_GIT_ORDINARY\n")
		assert(not paths.same(assert(stat(f.root .. "/.svn")), assert(stat(f.root .. "/.SVN"))))
		local text = finish(collect(f.root))
		assert(text:find("+UPPER_SVN_ORDINARY", 1, true) and text:find("+UPPER_GIT_ORDINARY", 1, true))
		assert(not text:find("OWNED_PRISTINE_NONCE", 1, true))
	end)
	add("plain_file_marker_is_not_administration", function()
		local f = h.make_git_fixture()
		h.write_file(f.root .. "/.SVN", "PLAIN_UPPER_FILE\n")
		if not uv.fs_stat(f.root .. "/.svn") then
			h.write_file(f.root .. "/.svn", "PLAIN_LOWER_FILE\n")
		end
		assert(finish(collect(f.root)):find("+PLAIN_UPPER_FILE", 1, true))
	end)
	add("missing_standard_marker_keeps_uppercase", function()
		local f = h.make_git_fixture()
		vim.fn.mkdir(f.root .. "/.SVN", "p")
		h.write_file(f.root .. "/.SVN/ordinary", "ORDINARY_UPPER_WITHOUT_MARKER\n")
		if uv.fs_stat(f.root .. "/.svn") then
			error({ lazyvcs_skip = "distinct missing-marker fixture requires a case-sensitive filesystem" }, 0)
		end
		assert(finish(collect(f.root)):find("+ORDINARY_UPPER_WITHOUT_MARKER", 1, true))
	end)
	add("native_case_insensitive_administration", function()
		local f = fixture()
		assert(uv.fs_rename(f.root .. "/.svn", f.root .. "/admin-temporary"))
		assert(uv.fs_rename(f.root .. "/admin-temporary", f.root .. "/.SVN"))
		local upper = assert(stat(f.root .. "/.SVN"))
		local lower, err = stat(f.root .. "/.svn")
		if not lower and tostring(err):match("^ENOENT:") then
			assert(uv.fs_rename(f.root .. "/.SVN", f.root .. "/.svn"))
			error({ lazyvcs_skip = "native filesystem does not alias .SVN and .svn" }, 0)
		end
		assert(lower and paths.same(lower, upper), err or "administration alias identity is unverifiable")
		h.exec({ "svn", "info", "--xml", "--", "." }, f.root)
		local native = h.exec({ "git", "ls-files", "-z", "--others", "--exclude-standard" }, f.root)
		assert(native:find(".SVN/pristine/", 1, true), "native Git did not expose the alias fixture")
		ordinary(finish(collect(f.root)))
	end)
	add("native_alias_link_leaf_is_excluded", function()
		local f = fixture()
		if uv.fs_stat(f.root .. "/.SVN") then
			error({ lazyvcs_skip = "distinct linked alias fixture requires case-sensitive names" }, 0)
		end
		local linked, err = uv.fs_symlink(f.root .. "/.svn", f.root .. "/.SVN", { dir = true })
		if not linked then
			error({ lazyvcs_skip = "native administrative link fixture unavailable: " .. tostring(err) }, 0)
		end
		local text = finish(collect(f.root))
		assert(text:find("+OUTER_ORDINARY", 1, true) and not text:find(".SVN", 1, true))
	end)
	add("unique_identity_pair_is_cached", function()
		local f, original = controlled(), fs.fs_lstat
		for i = 1, 20 do
			h.write_file(f.root .. "/.SVN/pristine/aa/other" .. i, "OWNED_PRISTINE_NONCE\n")
		end
		local count = 0
		---@diagnostic disable-next-line: duplicate-set-field
		fs.fs_lstat = function(path, cb)
			if path == f.root .. "/.SVN" then
				count = count + 1
			end
			return original(path, cb)
		end
		ordinary(finish(collect(f.root)))
		assert(count == 2, "directory alias identities were not checked once per request")
	end)
	for _, mode in ipairs({ "error", "unverifiable" }) do
		add("identity_" .. mode .. "_refuses", function()
			local f, original = controlled(), fs.fs_lstat
			---@diagnostic disable-next-line: duplicate-set-field
			fs.fs_lstat = function(path, cb)
				if path == f.root .. "/.SVN" then
					if mode == "error" then
						return original(path, function(_, entry)
							assert(entry and paths.identity(entry), "native error fixture has no identity")
							cb("EACCES: owned fixture denied", entry)
						end)
					end
					vim.schedule(function()
						cb(nil, {
							type = "directory",
							dev = -1,
							ino = 0,
						})
					end)
					return
				end
				return original(path, cb)
			end
			local out = collect(f.root)
			wait(function()
				return out.done
			end)
			assert(not out.text and out.err, "unverified administration alias published a patch")
		end)
	end
	add("canceled_identity_ignores_late_callback", function()
		local f, original, held, out = controlled(), fs.fs_lstat, nil, nil
		---@diagnostic disable-next-line: duplicate-set-field
		fs.fs_lstat = function(path, cb)
			if path == f.root .. "/.SVN" then
				return original(path, function(err, entry)
					held = function()
						cb(err, entry)
					end
				end)
			end
			return original(path, cb)
		end
		out = collect(f.root)
		wait(function()
			return held ~= nil or out.done
		end)
		assert(held, "administration alias identities were not checked")
		out.task:cancel()
		held()
		vim.wait(30, function()
			return out.done
		end, 5)
		assert(not out.done and not out.task:is_active())
	end)
	return cases
end
