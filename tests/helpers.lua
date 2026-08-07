local M = {}
local temp_roots = {}

-- Isolate every git invocation in this Neovim process -- the fixtures' own, and
-- the ones the plugin makes through `vim.system` -- from the developer's git
-- configuration. Setting these in `vim.env` means child processes inherit them.
--
-- A contributor with `commit.gpgsign` / `tag.gpgsign` set globally (normal for
-- anyone who signs releases) turned the fixtures' `git tag v1.0.0` into a
-- signed annotated tag and got `fatal: no tag message?` from three switch
-- specs, and would hit the same on any plugin-driven `git commit`. CI has no
-- global config, so this class of failure is invisible there and looks like a
-- local-machine problem instead of the environment leak it is.
--
-- `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` are git 2.32+. `/dev/null` is not
-- portable to Windows, so point both at an empty file.
local function isolate_git_config()
	local empty = vim.fs.normalize(vim.fn.tempname())
	local handle = io.open(empty, "w")
	if not handle then
		return
	end
	handle:close()
	vim.env.GIT_CONFIG_GLOBAL = empty
	vim.env.GIT_CONFIG_SYSTEM = empty
end

isolate_git_config()

local function join(...)
	return vim.fs.normalize(table.concat({ ... }, "/"))
end

-- vim.fs.normalize(vim.fn.tempname()) returns a backslash path on Windows. The plugin normalizes
-- every path it reports through vim.fs.normalize, so fixtures must do the same or
-- comparisons fail with mixed separators (C:\a\b/c vs C:/a/b/c).
-- macOS puts temporary files under /var, which is a symlink to /private/var, so
-- Neovim reports buffer names in the resolved form while the fixture path stays
-- unresolved. Resolve once at creation so every later comparison matches.
local function tempdir()
	local dir = vim.fs.normalize(vim.fn.tempname())
	vim.fn.mkdir(dir, "p")
	dir = vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
	temp_roots[#temp_roots + 1] = dir
	return dir
end

M.tempdir = tempdir

function M.cleanup()
	local function belongs_to_fixture(path)
		if not path or path == "" then
			return false
		end
		local normalized = vim.fs.normalize(path)
		if package.config:sub(1, 1) == "\\" then
			normalized = normalized:lower()
		end
		for _, root in ipairs(temp_roots) do
			local candidate = package.config:sub(1, 1) == "\\" and root:lower() or root
			if normalized == candidate or vim.startswith(normalized, candidate .. "/") then
				return true
			end
		end
		return false
	end

	local actions = package.loaded["lazyvcs.actions"]
	local session_state = package.loaded["lazyvcs.state"]
	if actions and session_state and type(session_state.list) == "function" then
		for _, session in ipairs(session_state.list()) do
			if belongs_to_fixture(session.source_path or session.root) then
				pcall(actions.close, session.editable_bufnr)
			end
		end
	end

	local jobs = package.loaded["lazyvcs.source_control.jobs"]
	if jobs and type(jobs.cancel) == "function" then
		jobs.cancel(function(job)
			return belongs_to_fixture(job.root)
		end, "test fixture cleanup")
	end

	local removed_buffers = false
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and belongs_to_fixture(vim.api.nvim_buf_get_name(bufnr)) then
			removed_buffers = true
			pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		end
	end
	if removed_buffers then
		vim.wait(100, function()
			return false
		end, 10)
	end

	for index = #temp_roots, 1, -1 do
		pcall(vim.fn.delete, temp_roots[index], "rf")
	end
	temp_roots = {}
end

function M.write_file(path, text)
	local lines = vim.split((text or ""):gsub("\n$", ""), "\n", { plain = true })
	vim.fn.writefile(lines, path)
end

function M.exec(args, cwd)
	local result = vim.system(args, { cwd = cwd, text = true }):wait()
	assert(result.code == 0, table.concat(args, " ") .. "\n" .. (result.stderr or ""))
	return result.stdout or ""
end

---Build a `file://` URL for a local repository path.
---
---POSIX paths already start with `/`, so `file://` yields the required three
---slashes. Windows paths start with a drive letter instead, and `file://C:/...`
---makes `svn` parse `C:` as the URL authority, so every fixture checkout fails.
---Those failures are invisible on CI's Windows runner because it has no `svn`
---and the specs skip, so this must stay correct by construction.
function M.file_url(path)
	local normalized = vim.fs.normalize(path)
	if normalized:sub(1, 1) == "/" then
		return "file://" .. normalized
	end
	return "file:///" .. normalized
end

function M.make_git_fixture()
	local root = tempdir()

	M.exec({ "git", "init" }, root)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, root)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, root)

	local file = join(root, "sample.txt")
	M.write_file(file, "one\ntwo\nthree\n")
	M.exec({ "git", "add", "sample.txt" }, root)
	M.exec({ "git", "commit", "-m", "init" }, root)
	M.write_file(file, "one\nchanged\nthree\n")

	return {
		root = root,
		file = file,
	}
end

function M.make_git_transfer_fixture()
	local root = tempdir()

	M.exec({ "git", "init" }, root)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, root)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, root)

	local file1 = join(root, "alpha.txt")
	local file2 = join(root, "beta.txt")
	local base1 = { "one", "two", "three", "four", "five" }
	local base2 = { "red", "blue", "green", "yellow", "orange" }
	M.write_file(file1, table.concat(base1, "\n") .. "\n")
	M.write_file(file2, table.concat(base2, "\n") .. "\n")
	M.exec({ "git", "add", "alpha.txt", "beta.txt" }, root)
	M.exec({ "git", "commit", "-m", "init" }, root)
	M.write_file(file1, "one\nchanged\nthree\nfour\nfive\n")
	M.write_file(file2, "red\nblue\ngreen\namber\norange\nviolet\n")

	return {
		root = root,
		file1 = file1,
		file2 = file2,
		base1 = base1,
		base2 = base2,
	}
end

function M.make_git_markdown_transfer_fixture()
	local root = tempdir()
	local lua_root = join(root, "lua", "lazyvcs")
	vim.fn.mkdir(lua_root, "p")

	M.exec({ "git", "init" }, root)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, root)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, root)

	local lua_file = join(lua_root, "actions.lua")
	local readme = join(root, "README.md")
	local lua_base = {
		"local M = {}",
		"function M.demo()",
		"  return 'base'",
		"end",
		"return M",
	}
	local readme_base = {
		"# lazyvcs.nvim",
		"",
		"Base line",
		"",
		"- alpha",
		"- beta",
	}
	M.write_file(lua_file, table.concat(lua_base, "\n") .. "\n")
	M.write_file(readme, table.concat(readme_base, "\n") .. "\n")
	M.exec({ "git", "add", "README.md", "lua/lazyvcs/actions.lua" }, root)
	M.exec({ "git", "commit", "-m", "init" }, root)
	M.write_file(lua_file, "local M = {}\nfunction M.demo()\n  return 'changed'\nend\nreturn M\n")
	M.write_file(readme, "# lazyvcs.nvim\n\nChanged line\n\n- alpha\n- gamma\n")

	return {
		root = root,
		file1 = lua_file,
		file2 = readme,
		base1 = lua_base,
		base2 = readme_base,
	}
end

function M.make_svn_fixture()
	if vim.fn.executable("svnadmin") ~= 1 then
		-- Raised as a structured value so the test runner classifies this as a
		-- SKIP instead of a hard failure that aborts the rest of the suite.
		error({ lazyvcs_skip = "svnadmin not installed — SVN tests skipped" })
	end

	local root = tempdir()
	local repo = join(root, "repo")
	local seed = join(root, "seed")
	local wc = join(root, "wc")

	vim.fn.mkdir(root, "p")
	vim.fn.mkdir(seed, "p")
	M.exec({ "svnadmin", "create", repo }, root)

	local file = join(seed, "sample.txt")
	M.write_file(file, "one\ntwo\nthree\n")
	M.exec({ "svn", "import", seed, M.file_url(repo), "-m", "init" }, root)
	M.exec({ "svn", "checkout", M.file_url(repo), wc }, root)

	local wc_file = join(wc, "sample.txt")
	M.write_file(wc_file, "one\nchanged\nthree\n")

	return {
		root = wc,
		file = wc_file,
		repo = repo,
	}
end

function M.make_svn_added_fixture()
	if vim.fn.executable("svnadmin") ~= 1 then
		error({ lazyvcs_skip = "svnadmin not installed — SVN tests skipped" })
	end

	local root = tempdir()
	local repo = join(root, "repo")
	local wc = join(root, "wc")

	vim.fn.mkdir(root, "p")
	M.exec({ "svnadmin", "create", repo }, root)
	M.exec({ "svn", "checkout", M.file_url(repo), wc }, root)

	local wc_file = join(wc, "added.txt")
	M.write_file(wc_file, "alpha\nbeta\n")
	M.exec({ "svn", "add", "added.txt" }, wc)

	return {
		root = wc,
		file = wc_file,
		repo = repo,
	}
end

function M.make_git_remote_fixture()
	local root = tempdir()
	local origin = join(root, "origin.git")
	local seed = join(root, "seed")
	local clone = join(root, "clone")

	vim.fn.mkdir(root, "p")
	vim.fn.mkdir(seed, "p")
	M.exec({ "git", "init", "--bare", origin }, root)
	M.exec({ "git", "init" }, seed)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, seed)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, seed)

	local seed_file = join(seed, "sample.txt")
	M.write_file(seed_file, "one\ntwo\n")
	M.exec({ "git", "add", "sample.txt" }, seed)
	M.exec({ "git", "commit", "-m", "init" }, seed)
	M.exec({ "git", "branch", "-M", "main" }, seed)
	M.exec({ "git", "remote", "add", "origin", origin }, seed)
	M.exec({ "git", "push", "-u", "origin", "main" }, seed)
	M.exec({ "git", "--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main" }, root)

	M.exec({ "git", "clone", origin, clone }, root)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, clone)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, clone)

	local clone_file = join(clone, "sample.txt")
	M.write_file(clone_file, "one\ntwo\nthree\n")
	M.exec({ "git", "commit", "-am", "ahead" }, clone)

	return {
		root = clone,
		file = clone_file,
		origin = origin,
	}
end

function M.make_git_switch_fixture()
	local root = tempdir()
	local origin = join(root, "origin.git")
	local seed = join(root, "seed")
	local clone = join(root, "clone")

	vim.fn.mkdir(root, "p")
	vim.fn.mkdir(seed, "p")
	M.exec({ "git", "init", "--bare", origin }, root)
	M.exec({ "git", "init" }, seed)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, seed)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, seed)

	M.write_file(join(seed, "sample.txt"), "one\ntwo\n")
	M.exec({ "git", "add", "sample.txt" }, seed)
	M.exec({ "git", "commit", "-m", "init" }, seed)
	M.exec({ "git", "branch", "-M", "main" }, seed)
	M.exec({ "git", "remote", "add", "origin", origin }, seed)
	M.exec({ "git", "push", "-u", "origin", "main" }, seed)
	M.exec({ "git", "--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main" }, root)

	M.exec({ "git", "checkout", "-b", "feature/remote" }, seed)
	M.write_file(join(seed, "remote.txt"), "remote branch\n")
	M.exec({ "git", "add", "remote.txt" }, seed)
	M.exec({ "git", "commit", "-m", "remote branch" }, seed)
	M.exec({ "git", "push", "-u", "origin", "feature/remote" }, seed)
	M.exec({ "git", "checkout", "main" }, seed)

	M.exec({ "git", "clone", origin, clone }, root)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, clone)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, clone)

	M.exec({ "git", "checkout", "-b", "feature/local" }, clone)
	M.write_file(join(clone, "local.txt"), "local branch\n")
	M.exec({ "git", "add", "local.txt" }, clone)
	M.exec({ "git", "commit", "-m", "local branch" }, clone)
	M.exec({ "git", "checkout", "main" }, clone)
	M.exec({ "git", "tag", "v1.0.0" }, clone)
	M.exec({ "git", "fetch", "--all", "--prune" }, clone)

	return {
		root = clone,
		origin = origin,
	}
end

function M.make_svn_transfer_fixture()
	if vim.fn.executable("svnadmin") ~= 1 then
		error({ lazyvcs_skip = "svnadmin not installed — SVN tests skipped" })
	end

	local root = tempdir()
	local repo = join(root, "repo")
	local seed = join(root, "seed")
	local wc = join(root, "wc")

	vim.fn.mkdir(root, "p")
	vim.fn.mkdir(seed, "p")
	M.exec({ "svnadmin", "create", repo }, root)

	local file1 = join(seed, "alpha.txt")
	local file2 = join(seed, "beta.txt")
	local base1 = { "one", "two", "three", "four", "five" }
	local base2 = { "red", "blue", "green", "yellow", "orange" }
	M.write_file(file1, table.concat(base1, "\n") .. "\n")
	M.write_file(file2, table.concat(base2, "\n") .. "\n")
	M.exec({ "svn", "import", seed, M.file_url(repo), "-m", "init" }, root)
	M.exec({ "svn", "checkout", M.file_url(repo), wc }, root)

	local wc_file1 = join(wc, "alpha.txt")
	local wc_file2 = join(wc, "beta.txt")
	local wc_added = join(wc, "added.txt")
	local wc_untracked = join(wc, "scratch.txt")
	M.write_file(wc_file1, "one\nchanged\nthree\nfour\nfive\n")
	M.write_file(wc_file2, "red\nblue\ngreen\namber\norange\nviolet\n")
	M.write_file(wc_added, "new\nfile\n")
	M.write_file(wc_untracked, "scratch\nfile\n")
	M.exec({ "svn", "add", "added.txt" }, wc)

	return {
		root = wc,
		file1 = wc_file1,
		file2 = wc_file2,
		added = wc_added,
		untracked = wc_untracked,
		base1 = base1,
		base2 = base2,
	}
end

function M.make_svn_update_fixture()
	if vim.fn.executable("svnadmin") ~= 1 then
		error({ lazyvcs_skip = "svnadmin not installed — SVN tests skipped" })
	end

	local root = tempdir()
	local repo = join(root, "repo")
	local seed = join(root, "seed")
	local wc = join(root, "wc")
	local peer = join(root, "peer")

	vim.fn.mkdir(root, "p")
	vim.fn.mkdir(seed, "p")
	M.exec({ "svnadmin", "create", repo }, root)

	local file = join(seed, "sample.txt")
	M.write_file(file, "one\ntwo\nthree\n")
	M.exec({ "svn", "import", seed, M.file_url(repo), "-m", "init" }, root)
	M.exec({ "svn", "checkout", M.file_url(repo), wc }, root)
	M.exec({ "svn", "checkout", M.file_url(repo), peer }, root)

	local peer_file = join(peer, "sample.txt")
	M.write_file(peer_file, "one\nupdated\nthree\n")
	M.exec({ "svn", "commit", "-m", "remote change", peer }, peer)

	return {
		root = wc,
		file = join(wc, "sample.txt"),
		peer = peer,
		repo = repo,
	}
end

function M.make_svn_switch_fixture()
	if vim.fn.executable("svnadmin") ~= 1 then
		error({ lazyvcs_skip = "svnadmin not installed — SVN tests skipped" })
	end

	local root = tempdir()
	local repo = join(root, "repo")
	local seed = join(root, "seed")
	local wc = join(root, "wc")

	vim.fn.mkdir(root, "p")
	vim.fn.mkdir(join(seed, "trunk"), "p")
	vim.fn.mkdir(join(seed, "branches", "release"), "p")
	vim.fn.mkdir(join(seed, "tags", "v1.0.0"), "p")
	M.exec({ "svnadmin", "create", repo }, root)

	M.write_file(join(seed, "trunk", "sample.txt"), "trunk\n")
	M.write_file(join(seed, "branches", "release", "sample.txt"), "release\n")
	M.write_file(join(seed, "tags", "v1.0.0", "sample.txt"), "tag\n")
	M.exec({ "svn", "import", seed, M.file_url(repo), "-m", "init" }, root)
	M.exec({ "svn", "checkout", M.file_url(repo) .. "/trunk", wc }, root)

	return {
		root = wc,
		repo = repo,
		trunk_url = M.file_url(repo) .. "/trunk",
		release_url = M.file_url(repo) .. "/branches/release",
		tag_url = M.file_url(repo) .. "/tags/v1.0.0",
	}
end

function M.make_git_source_control_fixture()
	local root = tempdir()

	local git_dirty = join(root, "apps", "git-dirty")
	vim.fn.mkdir(git_dirty, "p")
	M.exec({ "git", "init" }, git_dirty)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, git_dirty)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, git_dirty)
	M.write_file(join(git_dirty, "sample.txt"), "one\ntwo\nthree\n")
	M.exec({ "git", "add", "sample.txt" }, git_dirty)
	M.exec({ "git", "commit", "-m", "init" }, git_dirty)
	M.write_file(join(git_dirty, "sample.txt"), "one\nchanged\nthree\n")

	local git_clean = join(root, "libs", "git-clean")
	vim.fn.mkdir(git_clean, "p")
	M.exec({ "git", "init" }, git_clean)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, git_clean)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, git_clean)
	M.write_file(join(git_clean, "clean.txt"), "alpha\nbeta\n")
	M.exec({ "git", "add", "clean.txt" }, git_clean)
	M.exec({ "git", "commit", "-m", "init" }, git_clean)

	return {
		root = root,
		git_dirty = git_dirty,
		git_clean = git_clean,
	}
end

function M.make_mixed_source_control_fixture()
	if vim.fn.executable("svnadmin") ~= 1 then
		error({ lazyvcs_skip = "svnadmin not installed — SVN tests skipped" })
	end

	local root = tempdir()

	local git_dirty = join(root, "apps", "git-dirty")
	vim.fn.mkdir(git_dirty, "p")
	M.exec({ "git", "init" }, git_dirty)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, git_dirty)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, git_dirty)
	M.write_file(join(git_dirty, "sample.txt"), "one\ntwo\nthree\n")
	M.exec({ "git", "add", "sample.txt" }, git_dirty)
	M.exec({ "git", "commit", "-m", "init" }, git_dirty)
	M.write_file(join(git_dirty, "sample.txt"), "one\nchanged\nthree\n")

	local git_clean = join(root, "libs", "git-clean")
	vim.fn.mkdir(git_clean, "p")
	M.exec({ "git", "init" }, git_clean)
	M.exec({ "git", "config", "user.name", "lazyvcs-test" }, git_clean)
	M.exec({ "git", "config", "user.email", "lazyvcs@example.com" }, git_clean)
	M.write_file(join(git_clean, "clean.txt"), "alpha\nbeta\n")
	M.exec({ "git", "add", "clean.txt" }, git_clean)
	M.exec({ "git", "commit", "-m", "init" }, git_clean)

	local svn_root = join(root, "platform")
	local svn_repo = join(root, "svn-repo")
	local svn_seed = join(root, "svn-seed")
	local svn_wc = join(svn_root, "projects")
	vim.fn.mkdir(svn_seed, "p")
	M.exec({ "svnadmin", "create", svn_repo }, root)
	M.write_file(join(svn_seed, "app.txt"), "red\nblue\ngreen\n")
	M.exec({ "svn", "import", svn_seed, M.file_url(svn_repo), "-m", "init" }, root)
	vim.fn.mkdir(svn_root, "p")
	M.exec({ "svn", "checkout", M.file_url(svn_repo), svn_wc }, root)
	M.write_file(join(svn_wc, "app.txt"), "red\nteal\ngreen\n")

	return {
		root = root,
		git_dirty = git_dirty,
		git_clean = git_clean,
		svn_wc = svn_wc,
	}
end

return M
