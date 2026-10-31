return function(ctx)
	local h = ctx.helpers
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		assert(fd:close())
	end
	local function fixture(format, committed, intent, flags)
		local root = h.tempdir()
		h.exec({ "git", "init", "--object-format=" .. format }, root)
		h.exec({ "git", "config", "user.name", "diff-style-test" }, root)
		h.exec({ "git", "config", "user.email", "diff-style@example.test" }, root)
		local path = root .. "/intent.txt"
		if committed then
			write(path, "committed contents\n")
			h.exec({ "git", "add", "intent.txt" }, root)
			h.exec({ "git", "commit", "-m", "original" }, root)
			h.exec({ "git", "rm", "--cached", "intent.txt" }, root)
		end
		write(path, intent and "private contents\n" or "")
		h.exec(intent and { "git", "add", "-N", "intent.txt" } or { "git", "add", "intent.txt" }, root)
		for _, flag in ipairs(flags or {}) do
			h.exec({ "git", "update-index", flag, "intent.txt" }, root)
		end
		return root, path
	end
	local function await(start)
		local value, failure, finished
		local task = start(function(result, err)
			value, failure, finished = result, err, true
		end)
		ctx.wait_for(function()
			return finished
		end, "index presence did not settle", 15000)
		return assert(value, failure), task
	end
	return {
		{
			"test_live_diff_style_authoritative_ita_and_empty_index_matrix",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false }, debounce_ms = 5 })
				for _, format in ipairs({ "sha1", "sha256" }) do
					for _, committed in ipairs({ false, true }) do
						for _, flags in ipairs({
							{},
							{ "--assume-unchanged" },
							{ "--skip-worktree" },
							{ "--assume-unchanged", "--skip-worktree" },
						}) do
							for _, intent in ipairs({ true, false }) do
								local root, path = fixture(format, committed, intent, flags)
								local loaded = await(function(done)
									return require("lazyvcs.backends").load_async(path, done, { root = root })
								end)
								assert(loaded.base_bytes == "", "fixture must use an empty index base")
								assert(
									loaded.presence.left == (intent and "absent" or "present"),
									format .. ": incorrect empty-index presence " .. vim.inspect(loaded.presence)
								)
								assert((loaded.presence.intent_to_add == true) == intent)
								vim.cmd.edit(vim.fn.fnameescape(path))
								local session = ctx.open_diff()
								ctx.wait_for(function()
									return intent == (session.rail ~= nil)
								end, "ITA rail did not match index evidence", 15000)
								local left = vim.wo[session.base_win].winbar
								local right = vim.wo[session.editable_win].winbar
								assert(
									intent and left:find("no file at index", 1, true) or left:find(" | empty", 1, true)
								)
								assert((right:find("intent to add", 1, true) ~= nil) == intent)
								if not intent then
									assert(#session.hunks == 0, "real empty index/file gained hunks")
								end
								require("lazyvcs.actions").close(session)
								h.cleanup()
							end
						end
					end
				end
			end,
		},
		{
			"test_core_diff_style_cancelled_intent_read_starts_no_followup",
			function()
				local util = require("lazyvcs.util")
				local original = util.system_start
				local root, path = fixture("sha1", false, true)
				local held, reads, following, completed = nil, 0, 0, false
				local task
				local ok, err = xpcall(function()
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						if vim.tbl_contains(args, "--ita-visible-in-index") then
							reads = reads + 1
							if reads == 1 then
								held = done
								return {
									cancel = function()
										done(nil, "Cancelled", { code = 130, stdout = "", cancelled = true })
									end,
								}
							end
						end
						if held then
							following = following + 1
						end
						return original(args, opts, done)
					end
					task = require("lazyvcs.backends.git").load_base_async(path, function()
						completed = true
					end, { root = root })
					ctx.wait_for(function()
						return held
					end, "index intent read was not held", 15000)
					task:kill()
					assert(held)({ code = 0, signal = 0, stdout = "" })
					vim.wait(40)
					assert(reads == 1 and following == 0 and not completed, "canceled presence read continued")
				end, debug.traceback)
				if task then
					task:kill()
				end
				util.system_start = original
				assert(ok, err)
			end,
		},
		{
			"test_core_diff_style_intent_failure_stays_unknown_and_nonempty_skips_reads",
			function()
				local util = require("lazyvcs.util")
				local original = util.system_start
				local ok, err = xpcall(function()
					for _, failure in ipairs({ "error", "truncated", "malformed", "invisible_truncated" }) do
						local root, path = fixture("sha1", false, true)
						local inspected = false
						---@diagnostic disable-next-line: duplicate-set-field
						util.system_start = function(args, opts, done)
							if
								vim.tbl_contains(args, "--ita-visible-in-index")
									and failure ~= "invisible_truncated"
								or vim.tbl_contains(args, "--ita-invisible-in-index")
									and failure == "invisible_truncated"
							then
								inspected = true
								vim.schedule(function()
									local raw = {
										code = failure == "error" and 1 or 0,
										signal = 0,
										stdout = failure == "malformed" and "invalid\0" or "",
										stdout_truncated = failure:find("truncated", 1, true) ~= nil,
									}
									done(
										failure ~= "error" and raw or nil,
										failure == "error" and "read failed" or nil,
										raw
									)
								end)
								return { cancel = function() end }
							end
							return original(args, opts, done)
						end
						local loaded = await(function(done)
							return require("lazyvcs.backends.git").load_base_async(path, done, { root = root })
						end)
						assert(inspected and loaded.presence.left == "unknown" and not loaded.presence.intent_to_add)
					end
					local f = h.make_git_fixture()
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						assert(
							not vim.tbl_contains(args, "--ita-visible-in-index")
								and not vim.tbl_contains(args, "--ita-invisible-in-index"),
							"nonempty base launched unnecessary intent reads"
						)
						return original(args, opts, done)
					end
					assert(await(function(done)
						return require("lazyvcs.backends.git").load_base_async(f.file, done, { root = f.root })
					end).presence.left == "present")
				end, debug.traceback)
				util.system_start = original
				assert(ok, err)
			end,
		},
	}
end
