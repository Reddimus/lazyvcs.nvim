return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, blame = t.api, require("lazyvcs.blame")
	local function commit(f, author, contents)
		t.h.exec({ "git", "config", "user.name", author }, f.root)
		t.h.write_file(f.file, contents)
		t.h.exec({ "git", "commit", "-am", author }, f.root)
		return vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
	end
	local function alice()
		local f, buf, win, backend = t.open(false)
		commit(f, "Alice", "Alice one\nAlice two\n")
		vim.cmd("edit!")
		assert(blame.blame())
		local _, view = t.loaded(buf)
		assert(view.entries[1].author == "Alice")
		return f, buf, win, backend
	end
	local function bob(buf, revision)
		t.wait(function()
			local view = blame._test_inline_state().views[buf]
			return view and view.entries and #view.entries == 3 and view.entries[1].author == "Bob"
		end, "reloaded contents retained Alice's attribution", 15000)
		for line = 1, 3 do
			api.nvim_win_set_cursor(0, { line, 0 })
			api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
			local mark, view = t.inline(buf)
			assert(mark and mark[2] == line - 1, "reloaded line has no inline mark")
			assert(view.entries[line].full_revision == revision and view.entries[line].author == "Bob")
		end
	end
	return t.cases({
		{
			"test_blame_inline_refreshes_after_unload_and_reload",
			function()
				local f, buf = alice()
				vim.cmd("hide enew")
				api.nvim_buf_delete(buf, { unload = true })
				local revision = commit(f, "Bob", "Bob one\nBob two\nBob three\n")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				assert(api.nvim_get_current_buf() == buf, "reload used a different buffer")
				bob(buf, revision)
			end,
		},
		{
			"test_blame_inline_refreshes_after_loaded_buffer_reread",
			function()
				local f, buf = alice()
				local revision = commit(f, "Bob", "Bob one\nBob two\nBob three\n")
				vim.cmd("edit!")
				bob(buf, revision)
			end,
		},
		{
			"test_blame_inline_unload_rejects_late_callbacks",
			function()
				local f, buf, _, backend = t.open(false)
				local callbacks, killed = {}, 0
				local raw = assert(backend.blame_lines(f.file))
				t.patch(backend, "blame_lines_async", function(_, callback)
					callbacks[#callbacks + 1] = callback
					return {
						kill = function()
							killed = killed + 1
						end,
					}
				end)
				assert(blame.blame())
				t.wait(function()
					return #callbacks == 1
				end, "initial request absent")
				local old = blame._test_inline_state().views[buf]
				vim.cmd("hide enew")
				api.nvim_buf_delete(buf, { unload = true })
				assert(
					not blame._test_inline_state().views[buf] and killed == 1,
					"unload retained the old inline request"
				)
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				t.wait(function()
					return #callbacks == 2
				end, "reload request absent")
				callbacks[1](raw)
				local view = blame._test_inline_state().views[buf]
				assert(view ~= old and view.loading and not view.entries, "late callback restored stale attribution")
				callbacks[2](raw)
				assert(view.entries and not view.loading and not view.handle)
				t.patch(require("lazyvcs.compare_text"), "capture_file", function()
					error("cursor movement serialized contents")
				end)
				t.patch(backend, "blame_lines_async", function()
					error("cursor movement started blame")
				end)
				for line = 1, 3 do
					api.nvim_win_set_cursor(0, { line, 0 })
					api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
				end
				assert(
					blame._test_inline_state().views[buf] == view and #t.notices == 0,
					"cursor movement invalidated cached attribution"
				)
			end,
		},
	})
end
