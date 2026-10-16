return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local ai, util = require("lazyvcs.source_control.ai"), require("lazyvcs.util")
	local input, ops = require("lazyvcs.source_control.input"), require("lazyvcs.source_control.ops")
	local fixture = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures/ai_transport.lua"
	return {
		{
			"test_source_control_popup_ai_repository_cancel_stops_provider",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					ai = { commit_message = {
						provider = "codex",
						confirm_privacy = false,
					} },
				})
				ai._test_set_executable_checker(function()
					return true
				end)
				local start, select = util.system_start, vim.ui.select
				local processes, popups = {}, {}
				local root = h.tempdir()
				local state, other_owner = {}, {}
				local repo = { root = root, name = "fixture", vcs = "git" }
				local held, hold_context
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					if args[1] == "git" then
						if hold_context then
							held = done
							return {
								kill = function()
									done(nil, "cancelled", { cancelled = true })
								end,
							}
						end
						done({ code = 0, stdout = "staged change", stderr = "" })
						return {}
					end
					local path = root .. "/process-" .. (#processes + 1)
					local p = { path = path, done = done }
					processes[#processes + 1] = p
					p.handle = start(
						{ vim.v.progpath, "--headless", "-u", "NONE", "-l", fixture, path },
						{ timeout = 15000 },
						done
					)
					return p.handle
				end
				local function alive(p)
					return require("process_helpers").alive(p.pid)
				end
				local function launched(index)
					wait(function()
						local p = processes[index]
						if p and vim.uv.fs_stat(p.path) then
							p.pid = require("process_helpers").pid(p.path)
							return true
						end
					end, "offline provider did not start", 15000)
					return processes[index]
				end
				local ok, err = xpcall(function()
					local popup = input.open(state, repo, "", function() end)
					popups[#popups + 1] = popup
					for _, map in ipairs(vim.api.nvim_buf_get_keymap(popup.bufnr, "n")) do
						if map.lhs == "gm" then
							map.callback()
						end
					end
					local p = launched(1)
					assert(alive(p))
					assert(
						require("lazyvcs").source_control_cancel(root) > 0,
						"repository cancellation missed popup provider"
					)
					wait(function()
						return not alive(p)
					end, "cancelled popup provider still alive", 3000)
					p.done({ code = 0, stdout = "late message" })
					assert(
						vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)[1] == "",
						"late provider result filled popup"
					)
					assert(
						not vim.inspect(vim.api.nvim_win_get_config(popup.winid).footer):find("Generating", 1, true),
						"popup footer stayed busy"
					)
					popup.generate()
					local retry = launched(2)
					local independent = ai.generate(repo, function() end, { owner = other_owner })
					local unrelated = ai.generate(
						{ root = h.tempdir(), vcs = "git" },
						function() end,
						{ owner = state }
					)
					local third, fourth = launched(3), launched(4)
					assert(ops.cancel(root, { owner = state }) == 1, "popup cancellation count or owner incorrect")
					wait(function()
						return not alive(retry)
					end, "retry provider survived cancellation", 3000)
					assert(alive(third) and alive(fourth), "cancellation crossed root or owner")
					assert(independent):cancel()
					assert(unrelated):cancel()
					popup.generate()
					local closing = launched(5)
					popup.close()
					wait(function()
						return not alive(closing)
					end, "modal closure left provider alive", 3000)
					hold_context = true
					local pending = input.open(state, repo, "original", function() end)
					popups[#popups + 1] = pending
					pending.generate()
					wait(function()
						return held ~= nil
					end, "context did not start")
					assert(ops.cancel(root, { owner = state }) > 0)
					held({ code = 0, stdout = "late context" })
					assert(#processes == 5, "cancelled context started provider")
					pending.close()
					local cancelled, done, cancel_hook = 0, nil, nil
					local sync = input.open_text({
						can_generate = true,
						on_generate = function(callback, on_cancel)
							done, cancel_hook = callback, on_cancel
							callback("synchronous")
							return {
								cancel = function()
									cancelled = cancelled + 1
								end,
							}
						end,
					}, function() end)
					popups[#popups + 1] = sync
					sync.generate()
					assert(not sync.owner.task and cancelled == 0, "synchronous completion retained task")
					local choice
					vim.ui.select = function(_, _, callback)
						choice = callback
					end
					sync.generate()
					assert(choice)
					assert(cancel_hook)()
					assert(done)("stale")
					choice("Replace current message")
					assert(
						vim.api.nvim_buf_get_lines(sync.bufnr, 0, 1, false)[1] == "synchronous",
						"stale confirmation replaced message"
					)
					local config = require("lazyvcs.config").get().ai.commit_message
					config.confirm_privacy = true
					ai._test_reset_privacy()
					local privacy, cancellations = nil, 0
					vim.ui.select = function(_, _, callback)
						privacy = callback
					end
					ai.generate(repo, function()
						error("cancelled privacy completed")
					end, {
						owner = state,
						on_cancel = function()
							cancellations = cancellations + 1
						end,
					})
					assert(privacy and ops.cancel(root, { owner = state }) == 1, "privacy request not registered")
					privacy("Send diff to configured AI provider")
					assert(#processes == 5 and cancellations == 1, "cancelled privacy request started work")
					config.confirm_privacy, hold_context = false, false
					ai._test_set_executable_checker(function()
						return true
					end)
					---@diagnostic disable-next-line: duplicate-set-field
					util.system_start = function()
						error("fixture spawn failure")
					end
					local failed
					ai.generate(repo, function(_, failure)
						failed = failure
					end, { owner = state })
					wait(function()
						return failed ~= nil
					end, "spawn failure did not settle")
					assert(ops.cancel(root, { owner = state }) == 0, "spawn failure retained registration")
				end, debug.traceback)
				for _, p in ipairs(processes) do
					p.handle:kill(15)
				end
				for _, popup in ipairs(popups) do
					pcall(popup.close)
				end
				ops.cancel(root)
				util.system_start, vim.ui.select = start, select
				ai._test_reset_privacy()
				assert(ok, err)
			end,
		},
	}
end
