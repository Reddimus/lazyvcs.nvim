local root, dir, stage = arg[1], arg[2], arg[3]
vim.opt.runtimepath:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path
local p = require("process_helpers")
require("lazyvcs").setup({
	use_gitsigns = false,
	signs = { enabled = false },
	source_control = { remote_refresh = "manual" },
	ai = { commit_message = { provider = "codex", confirm_privacy = false } },
})
local native = require("lazyvcs.source_control.native")
local state = native.open({ path = dir })
assert(
	vim.wait(10000, function()
		return not state.lazyvcs_discovering and not state.lazyvcs_hydration_active
	end, 10),
	"sidebar did not load"
)
local ai = require("lazyvcs.source_control.ai")
ai._test_set_executable_checker(function()
	return true
end)
local util = require("lazyvcs.util")
local start = util.system_start
local work = dir .. "/" .. stage
vim.fn.mkdir(work, "p")
---@diagnostic disable-next-line: duplicate-set-field
util.system_start = function(args, opts, done)
	if args[1] == "git" and stage == "provider" then
		done({ code = 0, stdout = "staged diff", stderr = "" })
		return {}
	end
	assert(args[1] == (stage == "context" and "git" or "codex"), "unexpected command")
	return start(p.tree(work), opts, done)
end
local generate, request = ai.generate, nil
---@diagnostic disable-next-line: duplicate-set-field
ai.generate = function(repo, done, opts)
	request = generate(repo, function(...)
		vim.fn.writefile({ "unexpected result" }, dir .. "/callback")
		done(...)
	end, opts)
	return request
end
local popup = require("lazyvcs.source_control.input").open(
	state,
	state.lazyvcs_repo_cache[dir],
	"original",
	function() end
)
popup.generate()
assert(
	vim.wait(4000, function()
		return p.ready(work)
	end, 10),
	"popup process tree did not start"
)
native.close()
assert(request and request.active, "sidebar close cancelled popup")
assert(vim.api.nvim_win_is_valid(popup.winid), "sidebar close removed popup")
assert(p.alive(p.pid(work .. "/parent.pid")), "popup process died before exit")
vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		vim.fn.writefile({
			vim.json.encode({
				closed = require("lazyvcs.process_runtime").is_shutting_down(),
				active = request.active,
				message = vim.api.nvim_buf_get_lines(popup.bufnr, 0, 1, false)[1],
			}),
		}, dir .. "/popup-exit.json")
	end,
})
vim.cmd("qa!")
