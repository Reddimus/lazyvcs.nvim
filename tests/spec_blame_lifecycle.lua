return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api = t.api
	local blame = require("lazyvcs.blame")
	local function split(buf)
		assert(blame.blame_split())
		t.wait(function()
			local v = blame._test_blame_views()[buf]
			return v and v.winid and api.nvim_win_is_valid(v.winid)
		end, "blame split did not load", 15000)
		return blame._test_blame_views()[buf]
	end
	local function edits(svn)
		local _, buf, win = t.open(svn)
		local before = require("lazyvcs.util").capture_win_options(win, { "scrollbind", "cursorbind" })
		local v = split(buf)
		local original = api.nvim_buf_get_lines(v.bufnr, 0, -1, false)
		api.nvim_buf_set_lines(buf, 0, 0, false, { "new unsaved" })
		api.nvim_exec_autocmds("TextChanged", { buffer = buf })
		t.wait(function()
			return api.nvim_buf_is_valid(v.bufnr) and api.nvim_buf_line_count(v.bufnr) == 4
		end, "split did not reload inserted row", 15000)
		local inserted = api.nvim_buf_get_lines(v.bufnr, 0, -1, false)
		assert(
			inserted[1] == "Uncommitted line" and inserted[2] == original[1] and inserted[4] == original[3],
			"insertion changed unchanged attribution"
		)
		api.nvim_buf_set_lines(buf, 0, 2, false, {})
		api.nvim_exec_autocmds("TextChanged", { buffer = buf })
		t.wait(function()
			return api.nvim_buf_is_valid(v.bufnr) and api.nvim_buf_line_count(v.bufnr) == 2
		end, "split did not reload deleted rows", 15000)
		assert(api.nvim_buf_get_lines(v.bufnr, 1, 2, false)[1] == original[3], "deletion changed unchanged attribution")
		assert(
			blame._test_blame_views()[buf] == v and vim.wo[win].scrollbind and vim.wo[v.winid].cursorbind,
			"reload lost split bindings"
		)
		api.nvim_set_current_win(win)
		vim.cmd.enew({ bang = true })
		t.wait(function()
			return not blame._test_blame_views()[buf]
		end, "source replacement retained split")
		assert(
			not api.nvim_win_is_valid(v.winid) and not api.nvim_buf_is_valid(v.bufnr),
			"source replacement retained report"
		)
		assert(
			vim.deep_equal(require("lazyvcs.util").capture_win_options(win, { "scrollbind", "cursorbind" }), before),
			"source bindings not restored"
		)
	end
	local function selection_replacement()
		local selection, loader = require("lazyvcs.blame_selection"), require("lazyvcs.backends.blame_selection")
		for _, completed in ipairs({ false, true }) do
			for _, hidden in ipairs({ false, true }) do
				local _, source, origin = t.open(false)
				local done, cancelled
				t.patch(loader, "load", function(_, _, callback)
					done = callback
					return {
						kill = function()
							cancelled = true
						end,
					}
				end)
				local request = assert(selection.open(1, 2))
				local win = request.win
				local entries = { { revision = "abc", author = "Alice", date = "2026-04-01" } }
				if completed then
					done(entries)
				end
				if hidden then
					vim.bo[request.buf].bufhidden = "hide"
				end
				vim.cmd.enew()
				local replacement = api.nvim_get_current_buf()
				api.nvim_buf_set_lines(replacement, 0, -1, false, { "user replacement" })
				vim.wait(30)
				assert(request.closed and not request.handle, "replaced report retained its request")
				assert(completed or cancelled, "replaced loading report was not cancelled")
				if selection._test_requests then
					assert(not selection._test_requests()[source], "report retained registry ownership")
				end
				done(entries)
				assert(
					api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == replacement,
					"late report completion changed replacement window"
				)
				assert(api.nvim_buf_get_lines(replacement, 0, -1, false)[1] == "user replacement")
				api.nvim_set_current_win(origin)
				local newer = assert(selection.open(1, 2))
				assert(api.nvim_win_is_valid(win), "reopening blame closed repurposed report window")
				api.nvim_win_close(newer.win, true)
				api.nvim_win_close(win, true)
			end
		end
	end
	return t.cases({
		{ "test_blame_selection_replacement_releases_report_ownership", selection_replacement },
		{
			"test_blame_split_reloads_source_edits_and_closes_on_replacement",
			function()
				edits(false)
			end,
		},
		{
			"test_svn_blame_split_reloads_source_edits_and_closes_on_replacement",
			function()
				edits(true)
			end,
		},
		{
			"test_blame_split_rejects_stale_initial_and_reload_results",
			function()
				local f, buf, _, backend = t.open(false)
				local raw = assert(backend.blame_lines(f.file))
				local original_async = backend.blame_lines_async
				local callbacks, killed = {}, 0
				t.patch(backend, "blame_lines_async", function(_, done)
					callbacks[#callbacks + 1] = done
					return {
						kill = function()
							killed = killed + 1
						end,
					}
				end)
				assert(blame.blame_split())
				api.nvim_buf_set_lines(buf, 0, 0, false, { "initial edit" })
				callbacks[1](raw)
				assert(not (blame._test_blame_views()[buf] or {}).winid, "stale initial result opened a split")
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				t.wait(function()
					return #callbacks >= 2
				end, "edited split did not restart")
				callbacks[2](raw)
				local v = assert(blame._test_blame_views()[buf])
				assert(v.winid, "fresh split did not open")
				api.nvim_buf_set_lines(buf, 0, 0, false, { "reload edit" })
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				t.wait(function()
					return #callbacks >= 3
				end, "reload did not start")
				api.nvim_buf_set_lines(buf, 0, 0, false, { "later edit" })
				callbacks[3]({})
				assert(
					blame._test_blame_views()[buf] == v and api.nvim_win_is_valid(v.winid),
					"held stale reload changed split"
				)
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				t.wait(function()
					return #callbacks >= 4
				end, "latest reload did not start")
				assert(killed >= 1, "superseded reload was not cancelled")
				blame.blame_split()
				t.patch(backend, "blame_lines_async", original_async)
				local edited = false
				local group = api.nvim_create_augroup("lazyvcs_test_blame_build_edit", { clear = true })
				t.cleanups[#t.cleanups + 1] = function()
					api.nvim_del_augroup_by_id(group)
				end
				api.nvim_create_autocmd("BufWinEnter", {
					group = group,
					callback = function(args)
						if not edited and api.nvim_buf_get_name(args.buf):match("^lazyvcs://blame/") then
							edited = true
							api.nvim_buf_set_lines(buf, 0, 0, false, { "edit during construction" })
						end
					end,
				})
				assert(blame.blame_split())
				local building = blame._test_blame_views()[buf]
				t.wait(function()
					return building.winid
						and api.nvim_win_is_valid(building.winid)
						and api.nvim_buf_line_count(building.bufnr) == api.nvim_buf_line_count(buf)
				end, "edit during split construction closed the view", 15000)
				assert(
					edited and blame._test_blame_views()[buf] == building,
					"construction edit retired split ownership"
				)
			end,
		},
		{
			"test_blame_split_reload_follows_grown_source",
			function()
				local _, buf, win = t.open(false)
				local v = split(buf)
				-- An unrelated scrollbound window keeps its own offset through the reload.
				local other_lines = {}
				for i = 1, 200 do
					other_lines[i] = "other " .. i
				end
				local other_buf = api.nvim_create_buf(false, true)
				api.nvim_buf_set_lines(other_buf, 0, -1, false, other_lines)
				local other = api.nvim_open_win(other_buf, false, { split = "below", win = win })
				api.nvim_win_call(other, function()
					vim.fn.winrestview({ lnum = 60, topline = 55 })
				end)
				vim.wo[other][0].scrollbind = true
				api.nvim_win_set_height(win, 5)
				local appended = {}
				for i = 1, 20 do
					appended[i] = "appended " .. i
				end
				api.nvim_buf_set_lines(buf, -1, -1, false, appended)
				local last = api.nvim_buf_line_count(buf)
				api.nvim_win_set_cursor(win, { last, 0 })
				api.nvim_exec_autocmds("TextChanged", { buffer = buf })
				api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
				local function top(w)
					return api.nvim_win_call(w, function()
						return vim.fn.line("w0")
					end)
				end
				local source_top, other_top = top(win), top(other)
				t.wait(function()
					return api.nvim_buf_is_valid(v.bufnr) and api.nvim_buf_line_count(v.bufnr) == last
				end, "split did not reload appended rows", 15000)
				assert(api.nvim_win_get_cursor(v.winid)[1] == last, "reloaded split did not follow the source cursor")
				assert(top(v.winid) == top(win), "reloaded split did not follow the source view")
				assert(
					top(win) == source_top and api.nvim_win_get_cursor(win)[1] == last,
					"reload moved the source window"
				)
				assert(top(other) == other_top, "reload moved an unrelated scrollbound window")
			end,
		},
		{
			"test_blame_split_reopen_survives_previous_cleanup",
			function()
				local _, buf, win = t.open(false)
				local old = split(buf)
				assert(blame.blame_split())
				local new = split(buf)
				vim.wait(100)
				assert(blame._test_blame_views()[buf] == new and new ~= old, "old cleanup retired reopened split")
				api.nvim_win_set_cursor(win, { 3, 0 })
				api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
				assert(api.nvim_win_get_cursor(new.winid)[1] == 3, "reopened split lost cursor sync")
			end,
		},
	})
end
