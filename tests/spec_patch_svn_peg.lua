return function(ctx)
	local h = ctx.helpers
	local function write(path, bytes)
		local file = assert(io.open(path, "wb"))
		assert(file:write(bytes))
		file:close()
	end
	local function read(path)
		local file = assert(io.open(path, "rb"))
		local bytes = file:read("*a")
		file:close()
		return bytes
	end
	local function command(args, cwd)
		return vim.system(args, { cwd = cwd, text = false }):wait(15000)
	end
	local cases = {}
	for _, directory in ipairs({ false, true }) do
		cases[#cases + 1] = {
			"test_patch_svn_literal_worktree_" .. (directory and "directories" or "files"),
			function()
				local fixture = h.make_svn_fixture()
				local scopes = { "ordinary", "middle@name", "numeric@1", "trailing@" }
				local function leaf(scope)
					return directory and scope .. "/child.txt" or scope
				end
				for _, scope in ipairs(scopes) do
					local path = fixture.root .. "/" .. leaf(scope)
					vim.fn.mkdir(vim.fs.dirname(path), "p")
					write(path, "base " .. leaf(scope) .. "\n")
				end
				h.exec({ "svn", "add", "--force", "--", "." }, fixture.root)
				h.exec({ "svn", "commit", "-m", "literal target fixtures" }, fixture.root)
				for _, scope in ipairs(scopes) do
					write(fixture.root .. "/" .. leaf(scope), "edited " .. leaf(scope) .. "\n")
				end
				for _, scope in ipairs(scopes) do
					local done, text, err
					local task = require("lazyvcs").patch({
						path = fixture.root .. "/" .. scope,
						include_untracked = false,
						on_done = function(value, reason)
							done, text, err = true, value, reason
						end,
					})
					if not vim.wait(15000, function()
						return done
					end, 10) then
						task:cancel()
						error("literal SVN patch did not settle")
					end
					assert(not err, err)
					local native = command({ "svn", "diff", "--internal-diff", "--", scope }, fixture.root)
					assert(native.code == 0 and (native.signal or 0) == 0, native.stderr)
					assert(text == native.stdout, "literal native diff bytes changed")
					local header = text:match("^Index: ([^\r\n]+)\r?\n")
					assert(header == leaf(scope), "literal Index path changed")
					assert(text:find("--- " .. leaf(scope) .. "\t", 1, true))
					assert(text:find("+++ " .. leaf(scope) .. "\t", 1, true))
					local wrong = command({ "svn", "diff", "--internal-diff", "--", scope .. "@" }, fixture.root)
					assert(
						wrong.code == 1 and (wrong.signal or 0) == 0 and wrong.stderr:find("E155010", 1, true),
						"appended peg suffix did not report the changed filename"
					)
					local checkout, patch_dir = h.tempdir(), h.tempdir()
					h.exec({ "svn", "checkout", h.file_url(fixture.repo), checkout }, fixture.root)
					local patch_file = patch_dir .. "/scope.patch"
					write(patch_file, text)
					local applied = command({ "svn", "patch", patch_file, checkout }, fixture.root)
					assert(applied.code == 0 and (applied.signal or 0) == 0, applied.stderr)
					assert(read(checkout .. "/" .. leaf(scope)) == "edited " .. leaf(scope) .. "\n")
				end
			end,
		}
	end
	return cases
end
