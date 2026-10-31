return function(ctx)
	local h = ctx.helpers
	local ops = require("lazyvcs.source_control.ops")
	local jobs = require("lazyvcs.source_control.jobs")
	local state = require("lazyvcs.state")
	local util = require("lazyvcs.util")
	local function bytes(path)
		local file = assert(io.open(path, "rb"))
		local value = file:read("*a")
		file:close()
		return value
	end
	local function guard(fn)
		return function()
			local options = vim.deepcopy(require("lazyvcs.config").get())
			local notify, start = util.notify, util.system_start
			require("lazyvcs.config").setup({ source_control = { confirm_mutations = false } })
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function() end
			local ok, err = xpcall(fn, debug.traceback)
			util.notify, util.system_start = notify, start
			require("lazyvcs.config").setup(options)
			assert(ok, err)
		end
	end
	local function fixture(kind)
		local f = h.make_git_fixture()
		local rel, status, section, renamed_from = "sample.txt", "M ", "staged", nil
		if kind == "addition" then
			rel, status = "new.txt", "A "
			h.write_file(f.root .. "/" .. rel, "staged addition\n")
		elseif kind == "tree" then
			rel, status = "tree", "A "
			vim.fn.mkdir(f.root .. "/tree", "p")
			h.write_file(f.root .. "/tree/child.txt", "old child\n")
			h.exec({ "git", "add", "--", "tree" }, f.root)
			h.exec({ "git", "commit", "-m", "tree base" }, f.root)
			vim.fn.delete(f.root .. "/tree", "rf")
			h.write_file(f.root .. "/tree", "staged replacement\n")
		elseif kind == "rename_destination" or kind == "rename_source" then
			rel, status, renamed_from = "renamed.txt", "R ", "sample.txt"
			h.exec({ "git", "checkout", "--", "sample.txt" }, f.root)
			h.exec({ "git", "mv", "--", "sample.txt", rel }, f.root)
		elseif kind == "conflict" then
			status, section = "UU", "merge"
		end
		h.exec({ "git", "add", "-A", "--", rel }, f.root)
		local node = {
			type = "file",
			path = f.root .. "/" .. rel,
			extra = {
				repo_root = f.root,
				relpath = rel,
				section = section,
				status = status,
				index_status = status:sub(1, 1),
				renamed_from = renamed_from,
			},
		}
		return f, node
	end
	local function discard(f, node)
		local repo = { root = f.root, name = "fixture", vcs = "git", counts = { local_changes = 1, staged = 1 } }
		ops.revert_file(
			{ path = f.root, lazyvcs_repo_cache = { [f.root] = repo }, lazyvcs_render = function() end },
			node
		)
		ctx.wait_for(function()
			for _, job in ipairs(jobs.history()) do
				if job.root == f.root and job.kind == "discard_staged" then
					return true
				end
			end
		end, "staged discard did not settle", 15000)
		return state.get_repo_job(f.root)
	end
	local function make_intent(f, node, kind, flags)
		local rel = kind == "rename_source" and node.extra.renamed_from or node.extra.relpath
		-- A recreated HEAD path also has an ordinary staged deletion. Status alone
		-- cannot identify its index intent, especially with hidden worktree flags.
		h.exec({ "git", "rm", "--cached", "-f", "--ignore-unmatch", "--", rel }, f.root)
		h.write_file(f.root .. "/" .. rel, "private bytes absent from Git: " .. kind .. "\n")
		h.exec({ "git", "add", "-N", "--", rel }, f.root)
		for _, flag in ipairs(flags) do
			h.exec({ "git", "update-index", flag, "--", rel }, f.root)
		end
		return f.root .. "/" .. rel
	end
	return {
		{
			"test_source_control_staged_discard_refuses_every_intent_destination",
			guard(function()
				for _, kind in ipairs({
					"modified",
					"addition",
					"conflict",
					"rename_destination",
					"rename_source",
					"tree",
				}) do
					for _, flags in ipairs({
						{},
						{ "--assume-unchanged" },
						{ "--skip-worktree" },
						{ "--assume-unchanged", "--skip-worktree" },
					}) do
						local f, node = fixture(kind)
						local path = make_intent(f, node, kind, flags)
						local before, index = bytes(path), h.exec({ "git", "ls-files", "--stage", "-z" }, f.root)
						local job = discard(f, node)
						assert(
							vim.uv.fs_lstat(path) and bytes(path) == before,
							kind .. " discarded intent-to-add bytes: " .. table.concat(flags, ",")
						)
						assert(
							h.exec({ "git", "ls-files", "--stage", "-z" }, f.root) == index,
							kind .. " changed index before refusal"
						)
						assert(
							job and job.error and job.error:find("intent-to-add", 1, true),
							kind .. ": " .. vim.inspect(job)
						)
					end
				end
			end),
		},
		{
			"test_source_control_staged_discard_keeps_ordinary_index_controls",
			guard(function()
				for _, kind in ipairs({ "modified", "addition", "tree" }) do
					for _, empty in ipairs({ false, true }) do
						local f, node = fixture(kind)
						if empty then
							h.write_file(node.path, "")
							h.exec({ "git", "add", "--", node.extra.relpath }, f.root)
						end
						h.write_file(node.path, "ordinary unstaged bytes\n")
						local job = discard(f, node)
						assert(not job, kind .. ": " .. vim.inspect(job))
						if kind == "modified" then
							assert(bytes(node.path) == "one\ntwo\nthree\n")
						else
							assert(not vim.uv.fs_lstat(node.path), "ordinary staged addition was not discarded")
						end
					end
				end
			end),
		},
		{
			"test_source_control_staged_intent_preflight_failures_and_cancel_settle",
			guard(function()
				local start = util.system_start
				require("lazyvcs.config").setup({
					source_control = { confirm_mutations = false, background = { git_workers = 1 } },
				})
				for _, failure in ipairs({
					"error",
					"truncated",
					"invisible_truncated",
					"malformed",
					"wrong_path",
					"cancel",
				}) do
					local f, node = fixture("modified")
					local before = bytes(node.path)
					local queries, mutations, held = 0, 0, nil
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function(args, opts, done)
						if vim.tbl_contains(args, "--ita-visible-in-index") then
							queries = queries + 1
							if failure == "cancel" then
								held = done
								vim.schedule(function()
									ops.cancel(f.root)
								end)
								return {
									cancel = function()
										vim.schedule(function()
											done(
												nil,
												"Cancelled",
												{ code = 130, cancelled = true, stderr = "Cancelled" }
											)
										end)
									end,
								}
							end
							vim.schedule(function()
								if failure == "error" then
									done(nil, "index unavailable", { code = 128, stderr = "index unavailable" })
								else
									local result = {
										code = 0,
										signal = 0,
										stdout = failure == "malformed" and "not raw"
											or failure == "wrong_path" and (":000000 100644 " .. string.rep("0", 40) .. " " .. string.rep(
												"a",
												40
											) .. " A\0other.txt\0")
											or "",
										stdout_truncated = failure == "truncated",
									}
									done(result, nil, result)
								end
							end)
							return { cancel = function() end }
						end
						if failure == "invisible_truncated" and vim.tbl_contains(args, "--ita-invisible-in-index") then
							vim.schedule(function()
								local result = { code = 0, signal = 0, stdout = "", stdout_truncated = true }
								done(result, nil, result)
							end)
							return { cancel = function() end }
						end
						if vim.tbl_contains(args, "restore") or vim.tbl_contains(args, "rm") then
							mutations = mutations + 1
						end
						return start(args, opts, done)
					end
					local job = discard(f, node)
					util.system_start = start
					assert(
						queries == 1 and mutations == 0 and bytes(node.path) == before,
						failure .. " bypassed intent preflight"
					)
					assert(failure == "cancel" and not job or failure ~= "cancel" and job and job.error)
					local recovered = false
					jobs.command(
						{ root = f.root, vcs = "git" },
						"status",
						{ "git", "status", "--short" },
						{},
						function(result)
							recovered = result ~= nil
						end
					)
					ctx.wait_for(function()
						return recovered
					end, "refused intent preflight retained its worker", 15000)
					if held then
						local result = { code = 0, signal = 0, stdout = "" }
						held(result, nil, result)
						assert(mutations == 0, "late cancelled completion mutated")
					end
				end
			end),
		},
	}
end
