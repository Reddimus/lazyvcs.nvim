return function(ctx)
	local h = ctx.helpers
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		assert(fd:close())
	end
	local function read(path)
		local fd = assert(io.open(path, "rb"))
		local bytes = fd:read("*a")
		assert(fd:close())
		return bytes
	end
	local function fixture(contents, intent, flags)
		local f = h.make_git_fixture()
		f.relpath = "node-[x]"
		f.path = f.root .. "/" .. f.relpath
		vim.fn.mkdir(f.path, "p")
		write(f.path .. "/child.txt", "committed child\n")
		h.exec({ "git", "add", "--", f.relpath }, f.root)
		h.exec({ "git", "commit", "-m", "tree" }, f.root)
		vim.fn.delete(f.path, "rf")
		write(f.path, contents)
		h.exec({ "git", "rm", "-r", "--cached", "--", f.relpath }, f.root)
		local args = { "git", "add" }
		if intent then
			args[#args + 1] = "-N"
		end
		vim.list_extend(args, { "--", f.relpath })
		h.exec(args, f.root)
		for _, flag in ipairs(flags or {}) do
			h.exec({ "git", "update-index", flag, "--", f.relpath }, f.root)
		end
		return f
	end
	local function discard(f, async)
		local backend = require("lazyvcs.backends")
		if not async then
			return backend.revert_file(f.path)
		end
		local result, failure, finished
		backend.revert_file_async(f.path, function(value, err)
			result, failure, finished = value, err, true
		end, { root = f.root })
		ctx.wait_for(function()
			return finished
		end, "tree replacement discard did not finish", 15000)
		return result, failure
	end
	return {
		{
			"test_core_git_intent_tree_replacement_restores_ordinary_index_files",
			function()
				for _, contents in ipairs({ "indexed replacement\n", "" }) do
					for _, async in ipairs({ false, true }) do
						local f = fixture(contents, false)
						write(f.path, "working replacement\n")
						local result, err = discard(f, async)
						assert(result, tostring(err))
						assert(read(f.path) == contents, "ordinary tree replacement did not restore INDEX")
					end
				end
			end,
		},
		{
			"test_core_git_intent_tree_replacement_refuses_hidden_intent_files",
			function()
				for _, flags in ipairs({
					{},
					{ "--assume-unchanged" },
					{ "--skip-worktree" },
					{ "--assume-unchanged", "--skip-worktree" },
				}) do
					for _, async in ipairs({ false, true }) do
						local f = fixture("private replacement\n", true, flags)
						local index = h.exec({ "git", "ls-files", "--stage", "-z", "--", f.relpath }, f.root)
						local result, err = discard(f, async)
						assert(not result and err and err:find("Intent-to-add", 1, true), tostring(err))
						assert(read(f.path) == "private replacement\n", "tree replacement lost ITA bytes")
						assert(
							h.exec({ "git", "ls-files", "--stage", "-z", "--", f.relpath }, f.root) == index,
							"refused tree replacement changed INDEX"
						)
					end
				end
			end,
		},
	}
end
