return function(ctx)
	local h, wait = ctx.helpers, ctx.wait_for
	local ai, util = require("lazyvcs.source_control.ai"), require("lazyvcs.util")
	local input, ops = require("lazyvcs.source_control.input"), require("lazyvcs.source_control.ops")
	local fixture = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/fixtures/ai_transport.lua"
	local function cancel_reopened_popup(stage, second_tab, use_key)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { remote_refresh = "manual" },
			ai = { commit_message = { provider = "codex", confirm_privacy = false } },
		})
		ai._test_set_executable_checker(function()
			return true
		end)
		local native = require("lazyvcs.source_control.native")
		local f = h.make_git_fixture()
		local function open()
			local state = native.open({ path = f.root })
			wait(function()
				return not state.lazyvcs_discovering and not state.lazyvcs_hydration_active
			end, "sidebar did not load", 15000)
			return state
		end
		local state = open()
		local start, notify = util.system_start, vim.notify
		local held, popup, killed, provider_calls, cancellation_notice
		killed, provider_calls = 0, 0
		local ok, err = xpcall(function()
			---@diagnostic disable-next-line: duplicate-set-field
			util.system_start = function(args, opts, done)
				local context = args[1] == "git" and vim.tbl_contains(args, "diff")
				local provider = args[1] == "codex"
				if provider then
					provider_calls = provider_calls + 1
				end
				if context and stage == "context" or provider and stage == "provider" then
					held = done
					return {
						kill = function()
							killed = killed + 1
							done(nil, "cancelled", { cancelled = true })
						end,
					}
				elseif context then
					done({ code = 0, stdout = "staged diff", stderr = "" })
					return {}
				end
				return start(args, opts, done)
			end
			popup = input.open(state, state.lazyvcs_repo_cache[f.root], "original", function() end)
			popup.generate()
			wait(function()
				return held ~= nil
			end, "popup generation did not start")
			if second_tab then
				vim.cmd.tabnew()
			else
				native.close()
				assert(vim.api.nvim_win_is_valid(popup.winid), "sidebar closed popup")
				assert(killed == 0, "sidebar close killed popup generation")
			end
			state = open()
			local count
			if use_key then
				vim.notify = function(message)
					cancellation_notice = message
				end
				local repo_row
				for row, node in pairs(state.lazyvcs_line_nodes) do
					if node.type == "repo_changes" and node.extra.repo_root == f.root then
						repo_row = row
						break
					end
				end
				assert(repo_row, "repository changes row not found")
				vim.api.nvim_set_current_win(state.winid)
				vim.api.nvim_win_set_cursor(state.winid, { repo_row, 0 })
				assert(vim.api.nvim_get_current_win() == state.winid, "sidebar is not focused")
				assert(vim.api.nvim_win_get_cursor(state.winid)[1] == repo_row, "cursor missed repository row")
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("X", true, false, true), "xt", false)
				assert(
					cancellation_notice
						== "Cancelled the active operation for " .. state.lazyvcs_repo_cache[f.root].name,
					"X did not report exactly one cancellation: " .. tostring(cancellation_notice)
				)
			else
				count = require("lazyvcs").source_control_cancel(f.root)
				assert(count == 1, "repository cancellation missed popup or counted it twice: " .. count)
			end
			assert(killed == 1, "popup generation survived repository cancellation")
			assert(held)({ code = 0, stdout = "late generated message", stderr = "" })
			assert(vim.api.nvim_buf_get_lines(popup.bufnr, 0, 1, false)[1] == "original", "late result changed popup")
			assert(provider_calls == (stage == "provider" and 1 or 0), "cancelled context started provider")
		end, debug.traceback)
		if popup then
			popup.close()
		end
		pcall(native.close)
		vim.cmd("silent! tabonly!")
		pcall(native.close)
		util.system_start, vim.notify = start, notify
		ai._test_reset_privacy()
		assert(ok, err)
	end
	return {
		{
			"test_source_control_concurrent_popups_for_same_repository",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					ai = { commit_message = { provider = "codex", confirm_privacy = false } },
				})
				ai._test_set_executable_checker(function()
					return true
				end)
				local start = util.system_start
				local popups, requests, transports = {}, {}, {}
				local repo = { root = h.tempdir(), name = "fixture", vcs = "git" }
				local stage
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, _, done)
					if args[1] == "git" and stage == "provider" then
						done({ code = 0, stdout = "staged diff", stderr = "" })
						return {}
					end
					assert(args[1] == "git" or args[1] == "codex", "unexpected transport")
					local transport = { done = done, killed = 0 }
					transports[#transports + 1] = transport
					return {
						kill = function()
							transport.killed = transport.killed + 1
							done(nil, "cancelled", { cancelled = true })
						end,
					}
				end
				local function generate(popup)
					local count = #transports
					popup.generate()
					wait(function()
						return #transports == count + 1
					end, "popup request did not start")
					local request = assert(popup.owner.task)
					requests[#requests + 1] = request
					return request, transports[#transports]
				end
				local ok, err = xpcall(function()
					for _, current_stage in ipairs({ "context", "provider" }) do
						stage = current_stage
						for _, outcome in ipairs({ "finish", "close" }) do
							local first_tab = vim.api.nvim_get_current_tabpage()
							local first = input.open({}, repo, "", function() end)
							popups[#popups + 1] = first
							local first_request, first_transport = generate(first)
							vim.cmd.tabnew()
							local second = input.open({}, repo, "", function() end)
							popups[#popups + 1] = second
							local second_request, second_transport = generate(second)
							local api_request = assert(ai.generate(repo, function()
								error("cancelled API request completed")
							end, { owner = repo.root }))
							requests[#requests + 1] = api_request
							wait(function()
								return api_request.handle ~= nil
							end, "API request did not start")
							local api_transport = transports[#transports]
							assert(first_request ~= second_request, "popups shared a request")
							assert(first_request.active and second_request.active and api_request.active)
							vim.api.nvim_set_current_tabpage(first_tab)
							if outcome == "finish" then
								local count = #transports
								first_transport.done({ code = 0, stdout = "generated message", stderr = "" })
								if stage == "context" then
									wait(function()
										return #transports == count + 1
									end, "first popup provider did not start")
									transports[#transports].done({ code = 0, stdout = "generated message", stderr = "" })
								end
								wait(function()
									return not first_request.active
								end, "first popup did not finish")
								assert(vim.api.nvim_buf_get_lines(first.bufnr, 0, 1, false)[1] == "generated message")
								assert(not first.owner.task, "finished popup retained request")
							else
								first.close()
								assert(not first_request.active and first_transport.killed == 1)
								first_transport.done({ code = 0, stdout = "late closed result", stderr = "" })
							end
							assert(second_request.active and api_request.active, "one popup stopped another request")
							assert(
								second_transport.killed == 0 and api_transport.killed == 0,
								"other transport was killed"
							)
							assert(vim.api.nvim_buf_get_lines(second.bufnr, 0, 1, false)[1] == "")
							if outcome == "close" then
								first = input.open({}, repo, "", function() end)
								popups[#popups + 1] = first
							end
							first_request, first_transport = generate(first)
							local before = vim.api.nvim_buf_get_lines(first.bufnr, 0, 1, false)[1]
							assert(
								require("lazyvcs").source_control_cancel(repo.root) == 3,
								"root cancellation missed requests"
							)
							assert(not first_request.active and not second_request.active and not api_request.active)
							assert(
								first_transport.killed == 1
									and second_transport.killed == 1
									and api_transport.killed == 1
							)
							first_transport.done({ code = 0, stdout = "late first result", stderr = "" })
							second_transport.done({ code = 0, stdout = "late second result", stderr = "" })
							assert(vim.api.nvim_buf_get_lines(first.bufnr, 0, 1, false)[1] == before)
							assert(vim.api.nvim_buf_get_lines(second.bufnr, 0, 1, false)[1] == "")
							first.close()
							second.close()
							vim.cmd("silent! tabonly!")
						end
					end
				end, debug.traceback)
				for _, request in ipairs(requests) do
					request:cancel()
				end
				for _, popup in ipairs(popups) do
					popup.close()
				end
				vim.cmd("silent! tabonly!")
				util.system_start = start
				ai._test_reset_privacy()
				assert(ok, err)
			end,
		},
		{
			"test_source_control_jobs_release_completed_request_owners",
			function()
				local jobs = require("lazyvcs.source_control.jobs")
				local repo = { root = h.tempdir(), vcs = "git" }
				local owners = setmetatable({}, { __mode = "v" })
				for index = 1, 100 do
					local owner = {}
					owners[index] = owner
					jobs.command(repo, "ai_context", { "fixture" }, {
						owner = owner,
						scope = "request:" .. index,
						generation = index,
						start = function(_, _, done)
							if index % 2 == 0 then
								done({ code = 0, stdout = "", stderr = "" })
							end
							return {
								kill = function()
									done(nil, "cancelled", { cancelled = true })
								end,
							}
						end,
					}, function() end)
					assert(jobs.cancel_owner(owner) == index % 2, "completed owner retained cancellable work")
				end
				-- JIT traces can retain completed callback closures and their owners.
				if jit then
					jit.flush()
				end
				collectgarbage("collect")
				collectgarbage("collect")
				assert(next(owners) == nil, "scheduler retained completed request owners")
			end,
		},
		{
			"test_source_control_popup_cancel_after_sidebar_reopen",
			function()
				for _, stage in ipairs({ "context", "provider" }) do
					cancel_reopened_popup(stage, false, false)
					cancel_reopened_popup(stage, false, true)
				end
			end,
		},
		{
			"test_source_control_popup_cancel_from_second_tab",
			function()
				for _, stage in ipairs({ "context", "provider" }) do
					cancel_reopened_popup(stage, true, false)
					cancel_reopened_popup(stage, true, true)
				end
			end,
		},
		{
			"test_source_control_popup_context_survives_sidebar_close",
			function()
				require("lazyvcs").setup({
					use_gitsigns = false,
					signs = { enabled = false },
					source_control = { remote_refresh = "manual" },
					ai = { commit_message = { provider = "codex", confirm_privacy = false } },
				})
				ai._test_set_executable_checker(function()
					return true
				end)
				local f = h.make_git_fixture()
				local native = require("lazyvcs.source_control.native")
				local state = native.open({ path = f.root })
				wait(function()
					return not state.lazyvcs_discovering and not state.lazyvcs_hydration_active
				end, "sidebar did not load", 15000)
				local start, held, popup, killed, provider_calls = util.system_start, nil, nil, 0, 0
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, _, done)
					if args[1] == "git" then
						held = done
						return {
							kill = function()
								killed = killed + 1
								done(nil, "cancelled", { cancelled = true })
							end,
						}
					end
					provider_calls = provider_calls + 1
					done({ code = 0, stdout = "Generated after sidebar close", stderr = "" })
					return {}
				end
				local ok, err = xpcall(function()
					popup = input.open(state, state.lazyvcs_repo_cache[f.root], "", function() end)
					popup.generate()
					wait(function()
						return held ~= nil
					end, "popup context did not start")
					native.close()
					assert(vim.api.nvim_win_is_valid(popup.winid), "sidebar closure closed commit popup")
					assert(killed == 0, "sidebar closure cancelled live popup context")
					assert(held)({ code = 0, stdout = "staged diff", stderr = "" })
					wait(function()
						return vim.api.nvim_buf_get_lines(popup.bufnr, 0, 1, false)[1]
							== "Generated after sidebar close"
					end, "live popup lost generation after sidebar closure")
					held = nil
					popup.generate()
					wait(function()
						return held ~= nil
					end, "popup retry context did not start")
					popup.close()
					assert(killed == 1, "popup closure left its context job alive")
					assert(held)({ code = 0, stdout = "late context", stderr = "" })
					assert(provider_calls == 1, "closed popup started a late provider")
				end, debug.traceback)
				util.system_start = start
				if popup then
					popup.close()
				end
				pcall(native.close)
				ai._test_reset_privacy()
				assert(ok, err)
			end,
		},
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
				local config = require("lazyvcs.config").get().ai.commit_message
				local confirm_privacy = config.confirm_privacy
				local processes, popups = {}, {}
				local root = h.tempdir()
				local state, other_owner = {}, {}
				local repo = { root = root, name = "fixture", vcs = "git" }
				local held, hold_context
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, _opts, done)
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
							-- The pid file can exist before the provider has written its pid.
							p.pid = require("process_helpers").pid(p.path)
							return p.pid ~= nil
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
					assert(ops.cancel(root, { owner = root }) == 1, "popup cancellation count or owner incorrect")
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
					assert(ops.cancel(root, { owner = root }) == 1)
					held({ code = 0, stdout = "late context" })
					assert(#processes == 5, "cancelled context started provider")
					pending.close()
					local cancelled, done, cancel_hook, generations = 0, nil, nil, 0
					local sync = input.open_text({
						can_generate = true,
						on_generate = function(callback, on_cancel)
							done, cancel_hook = callback, on_cancel
							generations = generations + 1
							callback(generations == 1 and "synchronous" or "second")
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
					local failed, failed_provider
					ai.generate(repo, function(_, failure, provider)
						failed, failed_provider = failure, provider
					end, { owner = state })
					wait(function()
						return failed ~= nil
					end, "spawn failure did not settle")
					assert(failed:find("fixture spawn failure", 1, true))
					assert(ops.cancel(root, { owner = state }) == 0, "spawn failure retained registration")
					config.confirm_privacy = true
					ai._test_reset_privacy()
					vim.ui.select = function()
						error("fixture guarded failure\nsecond line")
					end
					failed = nil
					ai.generate(repo, function(_, failure, provider)
						failed, failed_provider = failure, provider
					end, { owner = state })
					assert(failed and not failed:find("[\r\n]"), "guarded error did not settle with sanitized text")
					assert(failed_provider == nil, "guarded error passed a replacement count as provider")
					assert(ops.cancel(root, { owner = state }) == 0, "guarded failure retained registration")
				end, debug.traceback)
				for _, p in ipairs(processes) do
					p.handle:kill(15)
				end
				for _, popup in ipairs(popups) do
					pcall(popup.close)
				end
				ops.cancel(root)
				util.system_start, vim.ui.select = start, select
				config.confirm_privacy = confirm_privacy
				ai._test_reset_privacy()
				assert(ok, err)
			end,
		},
	}
end
