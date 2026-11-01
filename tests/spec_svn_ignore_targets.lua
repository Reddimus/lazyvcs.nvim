return function(ctx)
	local h, uv = ctx.helpers, vim.uv
	local cases = {}
	local function write(path, bytes)
		local fd = assert(uv.fs_open(path, "w", 384))
		assert(uv.fs_write(fd, bytes, 0) == #bytes)
		assert(uv.fs_close(fd))
	end
	local function read(path)
		local fd = assert(uv.fs_open(path, "r", 438))
		local bytes = assert(uv.fs_read(fd, assert(uv.fs_fstat(fd)).size, 0))
		assert(uv.fs_close(fd))
		return bytes
	end
	local function fixture(parent)
		local f = h.make_svn_fixture()
		f.relative = parent .. "/leaf"
		h.exec({ "svn", "mkdir", "--", f.root .. "/" .. parent, f.root .. "/" .. f.relative }, f.root)
		write(f.root .. "/" .. f.relative .. "/tracked.txt", "versioned leaf\n")
		write(f.root .. "/" .. f.relative .. "/literal@.txt", "versioned at leaf\n")
		h.exec(
			{ "svn", "add", "--", "./" .. f.relative .. "/tracked.txt@", "./" .. f.relative .. "/literal@.txt@" },
			f.root
		)
		h.exec({ "svn", "commit", "-m", "literal local tree" }, f.root)
		local source = h.file_url(f.repo) .. "/" .. (parent == "^" and "%5E" or parent) .. "/leaf"
		h.exec({ "svn", "copy", source, h.file_url(f.repo) .. "/branch", "-m", "branch copy" }, f.root)
		h.exec({ "svn", "update", "." }, f.root)
		h.exec({ "svn", "propset", "svn:global-ignores", "*.hidden", "branch" }, f.root)
		h.exec({ "svn", "commit", "-m", "branch ignore policy" }, f.root)
		h.exec({ "svn", "switch", h.file_url(f.repo) .. "/branch", "--", "./" .. f.relative }, f.root)
		write(f.root .. "/" .. f.relative .. "/loose.txt", "owned literal caret bytes\n")
		write(f.root .. "/" .. f.relative .. "/ignored.hidden", "excluded sibling bytes\n")
		write(f.file, "tracked neighbor remains visible\n")
		return f
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_svn_ignore_targets_" .. name,
			function()
				local ok, err = xpcall(fn, debug.traceback)
				h.cleanup()
				assert(ok, err)
			end,
		}
	end
	local function patch(f, include, selected)
		local out = {}
		require("lazyvcs").patch({
			path = selected or f.root,
			include_untracked = include,
			on_done = function(text, err)
				out.text, out.err, out.done = text, err, true
			end,
		})
		ctx.wait_for(function()
			return out.done
		end, "literal SVN boundary patch did not settle", 15000)
		return out
	end
	case("native_url_syntax_is_not_disabled_by_separator", function()
		local f = fixture("^")
		for _, rel in ipairs({ f.relative, f.relative .. "/tracked.txt" }) do
			local outputs = {}
			for _, operand in ipairs({ f.root .. "/" .. rel, "./" .. rel, rel }) do
				local r = vim.system(
					{ "svn", "propget", "--xml", "--show-inherited-props", "svn:global-ignores", "--", operand .. "@" },
					{ cwd = f.root, text = false }
				):wait(15000)
				outputs[#outputs + 1] = r
			end
			assert(outputs[1].code == 0 and outputs[2].code == 0)
			assert(outputs[1].stdout:find("*.hidden", 1, true) and outputs[2].stdout:find("*.hidden", 1, true))
			assert(
				outputs[3].code ~= 0 and outputs[3].stderr:find("E150000", 1, true),
				"bare caret operand did not resolve as a repository URL"
			)
		end
	end)
	for _, parent in ipairs({ "^", "ordinary" }) do
		case("public_patch_native_apply_" .. parent, function()
			local f = fixture(parent)
			local before = read(f.file)
			local text = assert(patch(f, true).text, "public patch rejected literal switched directory")
			assert(text:find("+owned literal caret bytes", 1, true))
			assert(not text:find("excluded sibling bytes", 1, true))
			assert(
				read(f.file) == before
					and read(f.root .. "/" .. f.relative .. "/loose.txt") == "owned literal caret bytes\n"
			)
			local dest = h.tempdir()
			h.exec({ "svn", "checkout", h.file_url(f.repo), dest .. "/wc" }, dest)
			write(dest .. "/literal.patch", text)
			h.exec({ "svn", "patch", dest .. "/literal.patch" }, dest .. "/wc")
			assert(read(dest .. "/wc/" .. f.relative .. "/loose.txt") == "owned literal caret bytes\n")
		end)
	end
	case("public_compare_preserves_switched_scope", function()
		local f, out = fixture("^"), {}
		require("lazyvcs.backends.compare_svn").list(
			{ root = f.root, vcs = "svn", url = h.file_url(f.repo), revision = "HEAD", base = "BASE" },
			true,
			function(items, err)
				out.items, out.err, out.done = items, err, true
			end
		)
		ctx.wait_for(function()
			return out.done
		end, "literal SVN Compare discovery did not settle", 15000)
		local paths = {}
		for _, item in ipairs(assert(out.items, out.err)) do
			paths[item.relpath] = true
		end
		assert(paths["^/leaf/loose.txt"] and not paths["^/leaf/ignored.hidden"])
	end)
	case("excluded_untracked_directory_does_not_widen_patch", function()
		local f = fixture("^")
		local out = patch(f, false)
		local text = assert(out.text, out.err)
		assert(text:find("sample.txt", 1, true) and not text:find("owned literal caret bytes", 1, true))
		assert(read(f.root .. "/^/leaf/loose.txt") == "owned literal caret bytes\n")
	end)
	for _, selected in ipairs({ "tracked.txt", "literal@.txt", "loose.txt", "new/child.txt" }) do
		case("public_selected_" .. selected, function()
			local f = fixture("^")
			local path = f.root .. "/^/leaf/" .. selected
			if selected == "new/child.txt" then
				assert(uv.fs_mkdir(f.root .. "/^/leaf/new", 448))
			end
			write(path, "selected literal endpoint bytes\n")
			local out = patch(f, true, path)
			local text = assert(out.text, out.err)
			assert(text:find("+selected literal endpoint bytes", 1, true))
			assert(not text:find("tracked neighbor remains visible", 1, true))
			assert(not text:find("excluded sibling bytes", 1, true))
			assert(read(path) == "selected literal endpoint bytes\n")
			local dest = h.tempdir()
			h.exec({ "svn", "checkout", h.file_url(f.repo), dest .. "/wc" }, dest)
			write(dest .. "/selected.patch", text)
			h.exec({ "svn", "patch", dest .. "/selected.patch" }, dest .. "/wc")
			assert(read(dest .. "/wc/^/leaf/" .. selected) == "selected literal endpoint bytes\n")
		end)
	end
	return cases
end
