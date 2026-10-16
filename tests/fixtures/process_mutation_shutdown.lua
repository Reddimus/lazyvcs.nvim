local root, dir, guarded = arg[1], arg[2], arg[3]
vim.env.XDG_CACHE_HOME = dir .. "/cache"
vim.env.XDG_STATE_HOME = dir .. "/state"
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
local p = require("process_helpers")
-- Exercise loading native before the runtime directly, as well as an open sidebar.
local native = guarded == "sidebar" and require("lazyvcs.source_control.native") or nil
local jobs = require("lazyvcs.source_control.jobs")
local util = require("lazyvcs.util")
require("lazyvcs.config").setup({ source_control = { confirm_mutations = false, background = { git_workers = 3 } } })
local repo = { root = dir, vcs = "git", name = "fixture" }
local opts = { scope = "mutation", timeout_ms = 60000 }
if guarded == "yes" then
	local ref = assert(util.system({ "git", "symbolic-ref", "HEAD" }, { cwd = dir })).stdout
	opts.start = function(args, process_opts, cb)
		return require("lazyvcs.source_control.mutation_start").start(
			repo,
			args,
			process_opts,
			{ branch_ref = util.trim(ref) },
			cb
		)
	end
end
local mutation_id
if guarded == "ops" or guarded == "sidebar" then
	native = native or require("lazyvcs.source_control.native")
	local state = guarded == "sidebar" and native.open({ path = dir }) or {}
	assert(guarded ~= "sidebar" or vim.api.nvim_win_is_valid(state.winid), "sidebar did not open")
	if guarded == "sidebar" then
		local cancel_owner = jobs.cancel_owner
		---@diagnostic disable-next-line: duplicate-set-field
		jobs.cancel_owner = function(owner, cancel_opts)
			if owner == state then
				vim.fn.writefile(
					{ tostring(require("lazyvcs.process_runtime").is_shutting_down()) },
					dir .. "/sidebar-shutdown"
				)
			end
			return cancel_owner(owner, cancel_opts)
		end
	end
	state.lazyvcs_repo_cache =
		{ [dir] = vim.tbl_extend("force", repo, {
			counts = { staged = 1, local_changes = 1 },
		}) }
	state.lazyvcs_commit_drafts = { [dir] = table.concat(vim.fn.readfile(dir .. "/message", "b"), "\n") }
	local start = util.system_start
	---@diagnostic disable-next-line: duplicate-set-field
	util.system_start = function(args, process_opts, cb)
		if vim.tbl_contains(args, "commit") then
			assert(process_opts.preserve_on_shutdown and process_opts.on_exit_during_shutdown)
			vim.fn.writefile({ args[vim.fn.index(args, "-F") + 2] }, dir .. "/message-path")
		end
		return start(args, process_opts, cb)
	end
	require("lazyvcs.source_control.ops").commit_repo(state, { path = dir })
	assert(
		vim.wait(4000, function()
			return vim.fn.filereadable(dir .. "/message-path") == 1
		end, 10),
		"commit did not start"
	)
	util.system_start = start
else
	mutation_id = jobs.command(repo, "git_commit", { "git", "commit", "-m", "survived shutdown" }, opts, function()
		vim.fn.writefile({ "unexpected" }, dir .. "/callback")
	end)
end
assert(
	vim.wait(4000, function()
		return p.pid(dir .. "/mutation.pid") ~= nil
	end, 10),
	"commit hook not ready"
)
vim.fn.mkdir(dir .. "/status", "p")
jobs.command(repo, "status", p.tree(dir .. "/status"), { kill_grace_ms = 10000 }, function()
	vim.fn.writefile({ "unexpected" }, dir .. "/callback")
end)
assert(
	vim.wait(4000, function()
		return p.ready(dir .. "/status")
	end, 10),
	"status not ready"
)
vim.fn.mkdir(dir .. "/fetch", "p")
-- Fill the remaining worker so the fetch must survive a queued start. Sidebar
-- hydration can cause this ordering on slower hosts, including macOS CI.
local release_worker
jobs.command(repo, "fixture_barrier", { "held" }, {
	start = function(_, _, done)
		release_worker = done
		return {}
	end,
})
assert(
	vim.wait(4000, function()
		return release_worker ~= nil
	end, 10),
	"fixture barrier did not start"
)
local original = vim.system
vim.system = function(args, process_opts, cb)
	if args[1] == "git" and args[2] == "fetch" then
		return original(p.tree(dir .. "/fetch"), process_opts, cb)
	end
	return original(args, process_opts, cb)
end
if guarded == "ops" or guarded == "sidebar" then
	jobs.command(repo, "git_fetch", { "git", "fetch" }, { scope = "git_fetch" })
else
	require("lazyvcs.source_control.ops").run_primary_action({
		lazyvcs_repo_cache = { [dir] = repo },
	}, { type = "action_button", extra = { repo_root = dir, action = "fetch" } })
end
vim.defer_fn(function()
	release_worker({ code = 0, stdout = "", stderr = "" })
end, 20)
assert(
	vim.wait(4000, function()
		return p.ready(dir .. "/fetch")
	end, 10),
	"fetch not ready"
)
vim.system = original
jobs.command(repo, "git_commit", { "sh", "-c", 'echo queued > "$1/queued"', "sh", dir }, { scope = "mutation" })
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		for _, item in ipairs(jobs.history()) do
			assert(item.id ~= mutation_id, "running mutation was marked cancelled")
		end
	end,
})
vim.cmd("qa!")
