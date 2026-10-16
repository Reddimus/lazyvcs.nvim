return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local ops = require("lazyvcs.source_control.ops")
	local util = require("lazyvcs.util")
	local picker = require("lazyvcs.picker")
	local session = require("lazyvcs.state")
	local cases = {}
	for _, stage_all in ipairs({ false, true }) do
		cases[#cases + 1] = {
			"test_source_control_git_commit_overrides_legacy_message_encoding_"
				.. (stage_all and "stage_all" or "staged"),
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { confirm_mutations = false },
				})
				local f = h.make_git_fixture()
				h.exec({ "git", "config", "i18n.commitEncoding", "ISO-8859-1" }, f.root)
				if not stage_all then
					h.exec({ "git", "add", "sample.txt" }, f.root)
				end
				local message = "café résumé ✓\n\nUTF-8 draft"
				local state = {
					path = f.root,
					lazyvcs_commit_drafts = { [f.root] = message },
					lazyvcs_repo_cache = {
						[f.root] = {
							root = f.root,
							vcs = "git",
							name = "repo",
							counts = { staged = stage_all and 0 or 1, local_changes = 1 },
						},
					},
					lazyvcs_render = function() end,
				}
				local start, select = util.system_start, picker.select
				local path
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if vim.tbl_contains(args, "commit") then
						path = args[vim.fn.index(args, "-F") + 2]
						assert(
							path and table.concat(vim.fn.readfile(path, "b"), "\n") == message,
							"private UTF-8 message changed"
						)
					end
					return start(args, opts, done)
				end
				---@diagnostic disable-next-line: duplicate-set-field
				picker.select = function(_, _, done)
					done("Stage all and commit")
				end
				local ok, err = xpcall(function()
					ops.commit_repo(state, { path = f.root })
					wait(function()
						local job = session.get_repo_job(f.root)
						return not job or job.status ~= "running"
					end, "UTF-8 commit did not settle", 15000)
					assert(not session.get_repo_job(f.root), "UTF-8 commit failed")
					local object = h.exec({ "git", "cat-file", "commit", "HEAD" }, f.root)
					assert(
						not object:match("^(.-)\n\n"):find("\nencoding ", 1, true),
						"UTF-8 draft inherited conflicting commit encoding header"
					)
					assert(object:match("\n\n(.*)$") == message .. "\n", "commit object changed UTF-8 bytes")
					assert(
						h.exec({ "git", "log", "-1", "--encoding=UTF-8", "--format=%B" }, f.root) == message .. "\n\n",
						"UTF-8 log displays mojibake"
					)
					assert(
						util.trim(h.exec({ "git", "config", "i18n.commitEncoding" }, f.root)) == "ISO-8859-1",
						"repository encoding configuration changed"
					)
					assert(path and not vim.uv.fs_stat(path), "private message file leaked")
					assert(state.lazyvcs_commit_drafts[f.root] == "", "successful draft was not cleared")
				end, debug.traceback)
				util.system_start, picker.select = start, select
				assert(ok, err)
			end,
		}
	end
	return cases
end
