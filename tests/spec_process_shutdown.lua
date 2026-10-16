return function(ctx)
	local h, p = ctx.helpers, require("process_helpers")
	local function shutdown(mode, sidebar)
		if vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "POSIX process groups" })
		end
		local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
		local dir = h.tempdir()
		p.guarded(dir, function()
			p.editor(root .. "/tests/fixtures/process_shutdown.lua", dir, { root, dir, mode, sidebar })
			ctx.wait_for(function()
				return p.dead(dir)
			end, "owned processes survived editor exit", 1000)
			assert(vim.fn.filereadable(dir .. "/queued") == 0, "queued command started during shutdown")
			assert(vim.fn.filereadable(dir .. "/callback") == 0, "application callback ran during shutdown")
			local state = vim.json.decode(table.concat(vim.fn.readfile(dir .. "/shutdown.json"), "\n"))
			assert(state.closed and state.rejected, "shutdown did not reject new work")
			assert(state.preflight_settled, "completed preflight advanced instead of settling during shutdown")
			assert(state.elapsed_ms < 500, "shutdown exceeded its shared deadlines")
			local seen = {}
			for _, item in ipairs(state.history) do
				assert(not seen[item.id], "shutdown recorded a job twice")
				seen[item.id] = true
				assert(item.status == "cancelled", "shutdown did not cancel job")
			end
			assert(#state.history == (mode == "cancelled" and 1 or 9), "shutdown did not drain all queues")
		end)
	end
	local function message_shutdown(sidebar, output)
		if vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "POSIX process groups" })
		end
		local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
		local f = h.make_git_fixture()
		h.exec({ "git", "add", "sample.txt" }, f.root)
		local before = h.exec({ "git", "rev-parse", "HEAD" }, f.root)
		local message = "Survived shutdown\n\n" .. string.rep("full message body\n", 16000) .. "Tail"
		vim.fn.writefile({ message }, f.root .. "/message", "b")
		h.write_file(
			f.root .. "/.git/hooks/pre-commit",
			"#!/bin/sh\necho $PPID > mutation.pid\necho $$ > hook.pid\nwhile [ ! -f release ]; do sleep 0.05; done\n"
				.. (output and "echo stdout after shutdown\necho stderr after shutdown >&2\n" or "")
		)
		vim.uv.fs_chmod(f.root .. "/.git/hooks/pre-commit", 493)
		p.guarded(f.root, function()
			p.editor(
				root .. "/tests/fixtures/process_mutation_shutdown.lua",
				f.root,
				{ root, f.root, sidebar and "sidebar" or "ops" }
			)
			assert(p.alive(p.pid(f.root .. "/mutation.pid")), "commit was cancelled by editor or sidebar shutdown")
			if sidebar then
				assert(
					vim.fn.readfile(f.root .. "/sidebar-shutdown")[1] == "true",
					"sidebar teardown ran before runtime shutdown"
				)
			end
			-- Shutdown requests KILL without waiting for the kernel to finish termination.
			ctx.wait_for(function()
				return p.dead(f.root .. "/status") and p.dead(f.root .. "/fetch")
			end, "read-only commands survived", 3000)
			local path = vim.fn.readfile(f.root .. "/message-path")[1]
			assert(vim.fn.filereadable(path) == 1, "commit message file disappeared at editor exit")
			h.write_file(f.root .. "/release", "finish")
			ctx.wait_for(function()
				return p.dead(f.root)
			end, "commit did not finish after release", 5000)
			local after = h.exec({ "git", "rev-parse", "HEAD" }, f.root)
			if output then
				assert(after == before, "hook writing to closed pipes unexpectedly committed")
				assert(
					h.exec({ "git", "diff", "--cached", "--name-only" }, f.root):match("sample.txt"),
					"aborted commit lost staged change"
				)
			else
				assert(after ~= before, "preserved commit failed after slow hook")
				local object = h.exec({ "git", "cat-file", "commit", "HEAD" }, f.root)
				assert(object:match("\n\n(.*)$") == message .. "\n", "preserved commit truncated or changed message")
			end
			assert(vim.fn.filereadable(f.root .. "/.git/index.lock") == 0, "commit left an index lock")
			assert(vim.fn.filereadable(f.root .. "/queued") == 0, "queued mutation started at exit")
		end)
	end
	return {
		{
			"test_source_control_popup_exit_kills_context_and_provider",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX process groups" })
				end
				local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
				for _, stage in ipairs({ "context", "provider" }) do
					local f = h.make_git_fixture()
					p.guarded(f.root, function()
						p.editor(root .. "/tests/fixtures/popup_shutdown.lua", f.root, { root, f.root, stage })
						ctx.wait_for(function()
							return p.dead(f.root)
						end, "popup process tree survived editor exit", 1000)
						local state = vim.json.decode(table.concat(vim.fn.readfile(f.root .. "/popup-exit.json"), "\n"))
						assert(state.closed and not state.active, "exit did not cancel popup request registration")
						assert(state.message == "original", "shutdown changed popup text")
						assert(vim.fn.filereadable(f.root .. "/callback") == 0, "shutdown delivered popup result")
					end)
				end
			end,
		},
		{
			"test_source_control_commit_file_survives_slow_hook_after_exit",
			function()
				message_shutdown(false, false)
			end,
		},
		{
			"test_source_control_sidebar_exit_preserves_full_commit_message",
			function()
				message_shutdown(true, false)
			end,
		},
		{
			"test_source_control_commit_hook_output_after_exit_aborts_cleanly",
			function()
				message_shutdown(true, true)
			end,
		},
		{
			"test_source_control_process_exit_preserves_running_mutation_and_kills_status",
			function()
				if vim.fn.has("win32") == 1 then
					error({ lazyvcs_skip = "POSIX process groups" })
				end
				local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
				for _, guarded in ipairs({ "no", "yes" }) do
					local f = h.make_git_fixture()
					h.exec({ "git", "add", "sample.txt" }, f.root)
					h.write_file(
						f.root .. "/.git/hooks/pre-commit",
						"#!/bin/sh\necho $PPID > mutation.pid\necho $$ > hook.pid\nwhile [ ! -f release ]; do sleep 0.05; done\n"
					)
					vim.uv.fs_chmod(f.root .. "/.git/hooks/pre-commit", 493)
					p.guarded(f.root, function()
						p.editor(
							root .. "/tests/fixtures/process_mutation_shutdown.lua",
							f.root,
							{ root, f.root, guarded }
						)
						assert(p.alive(p.pid(f.root .. "/mutation.pid")), "running mutation died at editor shutdown")
						-- Shutdown requests KILL without waiting for the kernel to finish termination.
						ctx.wait_for(function()
							return p.dead(f.root .. "/status")
						end, "status survived editor shutdown", 3000)
						ctx.wait_for(function()
							return p.dead(f.root .. "/fetch")
						end, "fetch survived editor shutdown", 3000)
						assert(vim.fn.filereadable(f.root .. "/queued") == 0, "queued mutation started during shutdown")
						h.write_file(f.root .. "/release", "finish")
						ctx.wait_for(function()
							return p.dead(f.root)
						end, "mutation did not finish after editor exit")
						assert(h.exec({ "git", "log", "-1", "--format=%s" }, f.root):match("survived shutdown"))
						assert(vim.fn.filereadable(f.root .. "/.git/index.lock") == 0, "mutation left an index lock")
						assert(vim.fn.filereadable(f.root .. "/callback") == 0, "application callback ran at shutdown")
					end)
				end
			end,
		},
		{
			"test_source_control_process_shutdown_cleans_private_attachment",
			function()
				local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
				local f = h.make_git_fixture()
				p.editor(root .. "/tests/fixtures/process_cleanup_shutdown.lua", f.root, { root, f.root })
			end,
		},
		{
			"test_source_control_process_shutdown_returns_inert_handles",
			function()
				local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
				local f = h.make_git_fixture()
				p.editor(root .. "/tests/fixtures/process_cleanup_shutdown.lua", f.root, { root, f.root, "handles" })
			end,
		},
		{
			"test_source_control_process_exit_kills_editor_and_repository_trees",
			function()
				shutdown("running", "no")
				shutdown("running", "yes")
			end,
		},
		{
			"test_source_control_process_exit_forces_already_cancelled_tree",
			function()
				shutdown("cancelled", "yes")
			end,
		},
	}
end
