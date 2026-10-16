return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api = t.api
	return t.cases({
		{
			"test_blame_inline_resolves_again_after_dirchanged",
			function()
				local f, buf = t.open(false, { blame = { delay_ms = 100 } })
				assert(require("lazyvcs.blame").blame())
				assert(require("lazyvcs.blame")._test_inline_state().views[buf].timer)
				vim.cmd.cd(vim.fn.fnameescape(t.h.tempdir()))
				local _, view = t.loaded(buf)
				assert(
					not view.loading and not view.loading_timer and not view.handle,
					"inline request retained loading state"
				)
				assert(vim.v.errmsg == "", vim.v.errmsg)
			end,
		},
		{
			"test_blame_inline_startup_error_releases_loading",
			function()
				local _, buf, _, backend = t.open(false)
				t.patch(backend, "blame_lines_async", function()
					error("forced startup\nfailure")
				end)
				assert(require("lazyvcs.blame").blame())
				vim.wait(100)
				local _, view = t.inline(buf)
				assert(
					view and not view.loading and not view.loading_timer and not view.handle,
					"startup failure retained loading state"
				)
				assert(#t.notices == 1 and not t.notices[1]:find("\n"), "expected one single-line startup notification")
				local backends = require("lazyvcs.backends")
				backends.invalidate()
				t.patch(backends, "resolve_async", function()
					error("forced resolver\nfailure")
				end)
				t.notices = {}
				local ok, err = pcall(require("lazyvcs.blame").refresh, buf)
				assert(ok, tostring(err))
				assert(
					not require("lazyvcs.blame")._test_inline_state().views[buf],
					"resolver startup retained pending view"
				)
				assert(
					#t.notices == 1 and not t.notices[1]:find("\n"),
					"resolver startup notification was not single-line"
				)
			end,
		},
		{
			"test_blame_inline_tracks_active_duplicate_window",
			function()
				local _, buf, first, backend = t.open(false)
				vim.cmd.vsplit()
				local second = api.nvim_get_current_win()
				local inactive = vim.fn.bufwinid(buf)
				local active = inactive == first and second or first
				api.nvim_win_set_cursor(inactive, { 1, 0 })
				api.nvim_set_current_win(active)
				api.nvim_win_set_cursor(active, { 3, 0 })
				local done
				local raw = assert(backend.blame_lines(api.nvim_buf_get_name(buf)))
				t.patch(backend, "blame_lines_async", function(_, callback)
					done = callback
					return { kill = function() end }
				end)
				assert(require("lazyvcs.blame").blame())
				t.wait(function()
					return done ~= nil
				end, "blame did not start")
				t.wait(function()
					return t.inline(buf) ~= nil
				end, "loading mark absent")
				assert(t.inline(buf)[2] == 2, "loading blame followed inactive window")
				api.nvim_set_current_win(inactive)
				api.nvim_win_set_cursor(inactive, { 2, 0 })
				api.nvim_exec_autocmds("WinEnter", { buffer = buf })
				done(raw)
				assert(t.inline(buf)[2] == 1, "completed blame ignored latest origin")
			end,
		},
	})
end
