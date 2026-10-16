local root, dir, guarded = arg[1], arg[2], arg[3]
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
local p = require("process_helpers")
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
local mutation_id = jobs.command(repo, "git_commit", { "git", "commit", "-m", "survived shutdown" }, opts, function()
	vim.fn.writefile({ "unexpected" }, dir .. "/callback")
end)
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
local original = vim.system
vim.system = function(args, process_opts, cb)
	assert(args[1] == "git" and args[2] == "fetch", "unexpected fetch command")
	return original(p.tree(dir .. "/fetch"), process_opts, cb)
end
require("lazyvcs.source_control.ops").run_primary_action({
	lazyvcs_repo_cache = { [dir] = repo },
}, { type = "action_button", extra = { repo_root = dir, action = "fetch" } })
vim.system = original
assert(
	vim.wait(4000, function()
		return p.ready(dir .. "/fetch")
	end, 10),
	"fetch not ready"
)
jobs.command(repo, "git_commit", { "sh", "-c", 'echo queued > "$1/queued"', "sh", dir }, { scope = "mutation" })
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		for _, item in ipairs(jobs.history()) do
			assert(item.id ~= mutation_id, "running mutation was marked cancelled")
		end
	end,
})
vim.cmd("qa!")
