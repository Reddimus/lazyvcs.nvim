return function(ctx)
	local h = ctx.helpers
	local function write(path, bytes)
		local file = assert(io.open(path, "wb"))
		assert(file:write(bytes))
		assert(file:close())
	end
	local function await(start)
		local result, failure, finished
		start(function(value, err)
			result, failure, finished = value, err, true
		end)
		ctx.wait_for(function()
			return finished
		end, "discard did not finish", 15000)
		return result, failure
	end
	local function bytes(path)
		local file = assert(io.open(path, "rb"))
		local value = file:read("*a")
		file:close()
		return value
	end
	return {
		{
			"test_core_git_discard_refuses_hidden_intent_to_add",
			function()
				local git = require("lazyvcs.backends.git")
				for _, flags in ipairs({
					{},
					{ "--assume-unchanged" },
					{ "--skip-worktree" },
					{ "--assume-unchanged", "--skip-worktree" },
				}) do
					for _, async in ipairs({ false, true }) do
						local f = h.make_git_fixture()
						local rel = "literal-[?]*.txt"
						local path = f.root .. "/" .. rel
						local expected = "private contents to retain\n"
						write(path, expected)
						h.exec({ "git", "add", "-N", "--", ":(literal)" .. rel }, f.root)
						for _, flag in ipairs(flags) do
							h.exec({ "git", "update-index", flag, "--", rel }, f.root)
						end
						local result, err
						if async then
							result, err = await(function(done)
								git.revert_file_async(path, done, { root = f.root })
							end)
						else
							result, err = git.revert_file(path)
						end
						assert(
							bytes(path) == expected,
							"discard erased hidden intent-to-add bytes ("
								.. table.concat(flags, ",")
								.. ", async="
								.. tostring(async)
								.. ")"
						)
						assert(not result and err and err:find("Intent-to-add", 1, true), tostring(err))
					end
				end
			end,
		},
		{
			"test_core_git_intent_api_keeps_empty_and_hidden_ordinary_controls",
			function()
				local index = require("lazyvcs.backends.git_index")
				for _, head in ipairs({ false, true }) do
					for _, kind in ipairs({ "ita", "empty", "ordinary", "recreated" }) do
						if head or kind ~= "recreated" then
							for _, flag in ipairs({ false, "--assume-unchanged", "--skip-worktree" }) do
								local f = head and h.make_git_fixture() or { root = h.tempdir() }
								if not head then
									h.exec({ "git", "init" }, f.root)
								end
								local rel = "control-[?]*.txt"
								local path = f.root .. "/" .. rel
								local spec = ":(literal)" .. rel
								if head and (kind == "ordinary" or kind == "recreated") then
									write(path, "committed control\n")
									h.exec({ "git", "add", "--", spec }, f.root)
									h.exec({ "git", "commit", "-m", "control" }, f.root)
								end
								if kind == "recreated" then
									h.exec({ "git", "rm", "--cached", "--", spec }, f.root)
								end
								if kind == "ita" or kind == "recreated" then
									write(path, "valuable contents\n")
									h.exec({ "git", "add", "-N", "--", spec }, f.root)
								else
									write(path, kind == "empty" and "" or "indexed contents\n")
									h.exec({ "git", "add", "--", spec }, f.root)
									write(path, "working contents\n")
								end
								if flag then
									h.exec({ "git", "update-index", flag, "--", rel }, f.root)
								end
								local expected = kind == "ita" or kind == "recreated"
								local value, err = index.intent_to_add(f.root, rel)
								assert(value == expected, kind .. " " .. tostring(flag) .. ": " .. tostring(err))
								value, err = await(function(done)
									index.intent_to_add_async(f.root, rel, require("lazyvcs.util").system_start, done)
								end)
								assert(value == expected, kind .. " " .. tostring(flag) .. ": " .. tostring(err))
								if not flag and not expected then
									local result, why = require("lazyvcs.backends.git").revert_file(path)
									assert(result, why)
									assert(
										bytes(path) == (kind == "empty" and "" or "indexed contents\n"),
										"ordinary indexed control was misclassified: "
											.. kind
											.. " "
											.. tostring(head)
											.. " "
											.. vim.inspect(bytes(path))
									)
								end
							end
						end
					end
				end
			end,
		},
		{
			"test_core_git_intent_api_rejects_incomplete_or_wrong_path_results",
			function()
				local index = require("lazyvcs.backends.git_index")
				local sha = string.rep("a", 40)
				local raw = ":000000 100644 " .. string.rep("0", 40) .. " " .. sha .. " A\0literal*.txt\0"
				assert(index.parse_intent(raw, "", "literal*.txt") == true)
				assert(index.parse_intent(raw, raw, "literal*.txt") == false)
				for _, bad in ipairs({ raw .. raw, raw:gsub("literal%*%.txt", "other.txt"), ":invalid\0literal*.txt\0" }) do
					local value, err = index.parse_intent(bad, "", "literal*.txt")
					assert(value == nil and err, "unsafe raw result accepted")
				end
				for _, result in ipairs({
					{ code = 0, stdout = raw, stdout_truncated = true },
					{ code = 0, stdout = raw, stderr_truncated = true },
					{ code = 128, stdout = "" },
					{ code = 0, signal = 9, stdout = "" },
					{ code = 0, stdout = string.rep("x", 4096) },
				}) do
					local value, err = await(function(done)
						index.intent_to_add_async(h.tempdir(), "literal*.txt", function(_, _, callback)
							callback(result)
							return {}
						end, done)
					end)
					assert(value == nil and err, "failed index inspection was allowed")
				end
				local reads, completed, held = 0, false, nil
				local owner = index.intent_to_add_async(h.tempdir(), "literal*.txt", function(_, _, callback)
					reads = reads + 1
					held = callback
					return { cancel = function() end }
				end, function()
					completed = true
				end)
				owner:kill()
				assert(held)({ code = 0, stdout = raw })
				assert(reads == 1 and not completed, "cancelled index check started a second command")
			end,
		},
	}
end
