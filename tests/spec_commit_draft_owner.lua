return function(ctx)
	local api, h, wait = vim.api, ctx.helpers, ctx.wait_for
	local native = require("lazyvcs.source_control.native")
	local state = require("lazyvcs.state")
	local util, ai = require("lazyvcs.util"), require("lazyvcs.source_control.ai")
	local release
	local function guard(fn)
		return function()
			local start, generate, notify = util.system_start, ai.generate, util.notify
			local picker = require("lazyvcs.picker")
			local select = picker.select
			local options = vim.deepcopy(require("lazyvcs.config").get())
			local ok, err = xpcall(fn, function(value)
				return type(value) == "table" and value or debug.traceback(value, 2)
			end)
			if release then
				release()
				release = nil
			end
			util.system_start, ai.generate, util.notify, picker.select = start, generate, notify, select
			pcall(native.close)
			h.cleanup()
			require("lazyvcs.config").setup(options)
			if not ok then
				error(err, 0)
			end
		end
	end
	local function row(s, kind)
		for line, node in pairs(s.lazyvcs_line_nodes) do
			if node.type == kind then
				return line
			end
		end
	end
	local function at(s, kind)
		api.nvim_set_current_win(s.winid)
		api.nvim_win_set_cursor(s.winid, { assert(row(s, kind), "missing sidebar row " .. kind), 0 })
	end
	local function popup(s)
		at(s, "commit_input")
		native.dispatch("smart_e")
		local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		assert(api.nvim_buf_get_name(buf):match("^lazyvcs://commit%-input/"))
		return { win = win, buf = buf }
	end
	local function submit(p, value)
		api.nvim_set_current_win(p.win)
		api.nvim_buf_set_lines(p.buf, 0, -1, false, { value })
		vim.cmd.stopinsert()
		api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
	end
	local function fixture(svn, stage_all)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			ai = { commit_message = { provider = "off" } },
			source_control = { confirm_mutations = false },
		})
		local f = svn and h.make_svn_fixture() or h.make_git_fixture()
		if not svn and not stage_all then
			h.exec({ "git", "add", "sample.txt" }, f.root)
		end
		local s = native.open({ path = f.root })
		wait(function()
			local repo = s.lazyvcs_repo_cache[f.root]
			return repo and repo.summary_loaded and not repo.loading_summary
		end, "sidebar summary absent", 15000)
		native.render(s)
		at(s, "repo_changes")
		native.dispatch("open")
		wait(function()
			return row(s, "commit_input") ~= nil
		end, "commit row absent", 15000)
		submit(popup(s), "submitted old subject")
		assert(s.lazyvcs_commit_drafts[f.root] == "submitted old subject")
		return f, s
	end
	local function hook(f, fail)
		local started, gate = f.root .. "/.git/draft-started", f.root .. "/.git/draft-release"
		local function quote(path)
			return "'" .. path:gsub("'", "'\\''") .. "'"
		end
		h.write_file(
			f.root .. "/.git/hooks/pre-commit",
			"#!/bin/sh\n: > "
				.. quote(started)
				.. "\nattempts=0\nwhile [ ! -f "
				.. quote(gate)
				.. ' ]; do\n attempts=$((attempts + 1))\n [ "$attempts" -lt 1500 ] || exit 42\n sleep 0.01\ndone\nexit '
				.. (fail and "1" or "0")
				.. "\n"
		)
		assert(vim.uv.fs_chmod(f.root .. "/.git/hooks/pre-commit", 493))
		release = function()
			h.write_file(gate, "release\n")
		end
		return function()
			wait(function()
				return vim.uv.fs_stat(started) ~= nil
			end, "real pending Git commit did not enter its hook", 15000)
		end
	end
	local function completed(root)
		wait(function()
			local job = state.get_repo_job(root)
			return not job or job.status ~= "running"
		end, "commit did not settle", 15000)
	end
	local function run_git(change, stage_all)
		local f, s = fixture(false, stage_all)
		local entered = hook(f, change == "failure")
		local obsolete, cancelled
		if change == "old_ai" then
			---@diagnostic disable-next-line: duplicate-set-field
			ai.generate = function(_, done)
				obsolete = done
				return {
					cancel = function()
						cancelled = true
					end,
				}
			end
			at(s, "commit_input")
			native.dispatch("generate_commit_message")
		end
		local p = change ~= "unchanged" and popup(s) or nil
		if stage_all then
			---@diagnostic disable-next-line: duplicate-set-field
			require("lazyvcs.picker").select = function(_, _, done)
				done("Stage all and commit")
			end
		end
		at(s, "commit_input")
		native.dispatch("commit_repo")
		entered()
		local expected = change == "same_bytes" and "submitted old subject" or "new next commit draft"
		if p then
			submit(p, expected)
			assert(s.lazyvcs_commit_drafts[f.root] == expected)
		end
		if change == "cancel" then
			at(s, "commit_input")
			native.dispatch("cancel_repo")
		end
		assert(release)()
		completed(f.root)
		if change == "old_ai" then
			assert(cancelled, "new manual submission did not cancel obsolete AI owner")
			assert(obsolete)("obsolete generated subject")
		end
		local failure = change == "failure" or change == "cancel"
		if failure then
			assert(vim.trim(h.exec({ "git", "log", "-1", "--format=%s" }, f.root)) == "init")
		else
			assert(not state.get_repo_job(f.root), "commit failed")
			assert(vim.trim(h.exec({ "git", "log", "-1", "--format=%s" }, f.root)) == "submitted old subject")
		end
		assert(
			s.lazyvcs_commit_drafts[f.root] == (change == "unchanged" and "" or expected),
			"old commit cleared a newer submitted draft revision"
		)
	end
	local cases = {}
	for _, change in ipairs({ "newer", "same_bytes", "unchanged", "failure", "cancel", "old_ai" }) do
		cases[#cases + 1] = {
			"test_source_control_commit_draft_owner_" .. change,
			guard(function()
				run_git(change)
			end),
		}
	end
	cases[#cases + 1] = {
		"test_source_control_commit_draft_owner_stage_all",
		guard(function()
			run_git("newer", true)
		end),
	}
	cases[#cases + 1] = {
		"test_svn_source_control_commit_draft_owner_no_revision",
		guard(function()
			local f, s = fixture(true)
			local start = util.system_start
			local committed = false
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, opts, done)
				if args[1] == "svn" and args[2] == "commit" then
					committed = true
					h.exec({ "svn", "revert", "sample.txt" }, f.root)
				end
				return start(args, opts, done)
			end
			at(s, "commit_input")
			native.dispatch("commit_repo")
			completed(f.root)
			assert(committed and not state.get_repo_job(f.root), "no-revision SVN commit failed")
			assert(s.lazyvcs_commit_drafts[f.root] == "submitted old subject", "no-revision SVN commit lost draft")
		end),
	}
	return cases
end
