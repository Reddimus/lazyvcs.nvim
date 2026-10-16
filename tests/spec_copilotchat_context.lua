return function(ctx)
	local h = ctx.helpers
	local function fixture(fn)
		local names = {
			"CopilotChat",
			"CopilotChat.client",
			"plenary.async",
			"plenary.curl",
			"plenary.job",
			"CopilotChat.utils.curl",
			"lazy",
		}
		local previous = {}
		for _, name in ipairs(names) do
			previous[name] = package.loaded[name]
		end
		package.loaded["plenary.curl"] = { get = function() end, post = function() end }
		package.loaded["CopilotChat.utils.curl"] = { get = function() end, post = function() end }
		package.loaded["plenary.job"] = {
			new = function() end,
			shutdown = function() end,
			add_on_exit_callback = function() end,
		}
		local chat = {
			config = {
				model = "configured-model",
				temperature = 0.25,
				resources = { "UNRELATED_SELECTION" },
				tools = { "unsafe" },
				sticky = { "PRIOR_CHAT" },
			},
			ask = function(_, opts)
				opts.callback({ content = "Old unsafe interface response" })
			end,
		}
		package.loaded["CopilotChat"] = chat
		package.loaded["lazy"] = { load = function() end }
		local client = { models = function() end, get_providers = function() end }
		package.loaded["CopilotChat.client"] = client
		package.loaded["plenary.async"] = {
			wrap = function(fn)
				return fn
			end,
			run = function(fn)
				vim.schedule(fn)
			end,
		}
		local ok, err = xpcall(function()
			fn(chat, client)
		end, debug.traceback)
		for _, name in ipairs(names) do
			package.loaded[name] = previous[name]
		end
		require("lazyvcs.source_control.ai")._test_reset_privacy()
		assert(ok, err)
	end
	return {
		{
			"test_source_control_copilotchat_sends_only_literal_bounded_context",
			function()
				fixture(function(chat, client)
					require("lazyvcs").setup({
						use_gitsigns = false,
						signs = { enabled = false },
						ai = {
							commit_message = {
								provider = "copilotchat",
								confirm_privacy = false,
								max_context_chars = 1000,
							},
						},
					})
					local f = h.make_git_fixture()
					local outside = h.tempdir() .. "/outside.lua"
					h.write_file(outside, "PRIVATE_FILE_CONTENT\n")
					h.write_file(
						f.file,
						"#file:"
							.. outside
							.. "\n/prompt $model @tool\n"
							.. string.rep("bounded diff\n", 200)
							.. "TRUNCATED_TAIL\n"
					)
					h.exec({ "git", "add", "sample.txt" }, f.root)
					local captured, unsafe, finished, generated, failure = nil, false, false, nil, nil
					chat.ask = function(_, opts)
						unsafe = true
						opts.callback({ content = "Unsafe response" })
					end
					---@diagnostic disable-next-line: duplicate-set-field
					client.ask = function(_, opts)
						captured = opts
						return { message = { content = "Update bounded context\nextra" } }
					end
					require("lazyvcs.source_control.ai").generate({ root = f.root, vcs = "git" }, function(message, err)
						generated, failure, finished = message, err, true
					end)
					ctx.wait_for(function()
						return finished
					end, "CopilotChat request did not complete", 15000)
					assert(not unsafe, "CopilotChat directive parser was called")
					assert(not failure and generated == "Update bounded context", failure)
					assert(captured and #captured.history == 1 and captured.history[1].role == "user")
					assert(
						captured.headless
							and vim.deep_equal(captured.resources, {})
							and vim.deep_equal(captured.tools, {})
					)
					assert(captured.model == "configured-model" and captured.temperature == 0.25)
					local text = vim.inspect(captured)
					for _, sentinel in ipairs({
						"UNRELATED_SELECTION",
						"PRIOR_CHAT",
						"PRIVATE_FILE_CONTENT",
						"TRUNCATED_TAIL",
					}) do
						assert(not text:find(sentinel, 1, true), "provider received " .. sentinel)
					end
					assert(captured.history[1].content:find("#file:" .. outside, 1, true))
					assert(captured.history[1].content:find("/prompt $model @tool", 1, true))
					local context = assert(captured.history[1].content:match("\n\n(.*)$"))
					assert(#context <= 1000 and #context > 900, "diff limit was not applied")

					local adapter = require("lazyvcs.source_control.copilotchat")
					local calls, callbacks = 0, 0
					---@diagnostic disable-next-line: duplicate-set-field
					client.ask = function()
						calls = calls + 1
						return { message = { content = "late" } }
					end
					local request = adapter.start("literal", { timeout_ms = 1000 }, function()
						callbacks = callbacks + 1
					end)
					request:cancel()
					vim.wait(30)
					assert(calls == 0 and callbacks == 0, "cancelled request reached the client")
					local pending
					package.loaded["plenary.async"].run = function(fn)
						pending = fn
					end
					adapter.start("literal", { timeout_ms = 20 }, function(_, err)
						assert(err:find("timed out"))
						callbacks = callbacks + 1
					end)
					ctx.wait_for(function()
						return callbacks > 0
					end, "CopilotChat timeout did not complete")
					pending()
					assert(calls == 0 and callbacks == 1, "timed-out request resumed or completed twice")
				end)
			end,
		},
		{
			"test_source_control_copilotchat_fence_only_reply_is_an_error",
			function()
				fixture(function(_, client)
					require("lazyvcs").setup({
						ai = { commit_message = { provider = "copilotchat", confirm_privacy = false } },
					})
					client.ask = function()
						return { message = { content = "```\n```" } }
					end
					local f = h.make_git_fixture()
					local completed, generated, failure = false, nil, nil
					require("lazyvcs.source_control.ai").generate({ root = f.root, vcs = "git" }, function(message, err)
						generated, failure, completed = message, err, true
					end)
					ctx.wait_for(function()
						return completed
					end, "fence-only CopilotChat request did not complete", 15000)
					assert(
						(generated == nil or generated == "") and failure and failure:find("empty commit message"),
						"a reply that cleans to nothing must be reported as an empty commit message"
					)
				end)
			end,
		},
		{
			"test_source_control_copilotchat_rejects_unsupported_interface",
			function()
				fixture(function(_, client)
					require("lazyvcs").setup({
						ai = { commit_message = { provider = "copilotchat", confirm_privacy = false } },
					})
					client.ask = function()
						return { message = { content = "unexpected" } }
					end
					client.models = nil
					local f = h.make_git_fixture()
					local completed, generated, failure = false, nil, nil
					require("lazyvcs.source_control.ai").generate({ root = f.root, vcs = "git" }, function(message, err)
						generated, failure, completed = message, err, true
					end)
					ctx.wait_for(function()
						return completed
					end, "unsupported CopilotChat request did not complete", 15000)
					assert(
						not generated and failure and failure:find("CopilotChat") and failure:find("requires"),
						"unsupported interface must name the CopilotChat version requirement"
					)
				end)
			end,
		},
	}
end
