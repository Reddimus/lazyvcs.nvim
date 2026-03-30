local M = {}

local function join(...)
	return table.concat({ ... }, "/")
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

function M.make_git_fixture()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")

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

function M.make_svn_fixture()
	assert(vim.fn.executable("svnadmin") == 1, "svnadmin is required for SVN tests")

	local root = vim.fn.tempname()
	local repo = join(root, "repo")
	local seed = join(root, "seed")
	local wc = join(root, "wc")

	vim.fn.mkdir(root, "p")
	vim.fn.mkdir(seed, "p")
	M.exec({ "svnadmin", "create", repo }, root)

	local file = join(seed, "sample.txt")
	M.write_file(file, "one\ntwo\nthree\n")
	M.exec({ "svn", "import", seed, "file://" .. repo, "-m", "init" }, root)
	M.exec({ "svn", "checkout", "file://" .. repo, wc }, root)

	local wc_file = join(wc, "sample.txt")
	M.write_file(wc_file, "one\nchanged\nthree\n")

	return {
		root = wc,
		file = wc_file,
	}
end

return M
