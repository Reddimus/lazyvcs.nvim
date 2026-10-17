return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, util, blame = t.api, require("lazyvcs.util"), require("lazyvcs.blame")
	local original = { wrap = true, foldenable = true, scrollbind = false, cursorbind = false }
	local keys = vim.tbl_keys(original)
	local function options(win)
		return util.capture_win_options(win, keys)
	end
	local function equal(win, expected, message)
		assert(vim.deep_equal(options(win), expected), message .. ": " .. vim.inspect(options(win)))
	end
	local function open(buf)
		assert(blame.blame_split())
		t.wait(function()
			local v = blame._test_blame_views()[buf]
			return v and v.winid and api.nvim_win_is_valid(v.winid)
		end, "blame split did not load", 15000)
		return blame._test_blame_views()[buf]
	end
	local function restored(svn)
		for _, command in ipairs({ "split", "vsplit" }) do
			for _, close in ipairs({ "toggle", "q", "close" }) do
				local _, buf, win = t.open(svn)
				util.set_win_options(win, original)
				local globals = {}
				for _, key in ipairs(keys) do
					globals[key] = api.nvim_get_option_value(key, { win = win, scope = "global" })
				end
				local v = open(buf)
				api.nvim_set_current_win(win)
				vim.cmd(command)
				local clone = api.nvim_get_current_win()
				vim.cmd(command)
				local grandchild = api.nvim_get_current_win()
				if close == "toggle" then
					assert(blame.blame_split())
				else
					api.nvim_set_current_win(v.winid)
					if close == "q" then
						api.nvim_feedkeys("q", "x", false)
					else
						vim.cmd.close()
					end
				end
				t.wait(function()
					return not api.nvim_buf_is_valid(v.bufnr)
				end, "blame buffer retained")
				for _, owned in ipairs({ win, clone, grandchild }) do
					equal(owned, original, "split descendant retained temporary blame options")
					for key, value in pairs(globals) do
						assert(
							api.nvim_get_option_value(key, { win = owned, scope = "global" }) == value,
							"global " .. key .. " changed"
						)
					end
				end
				assert(not blame._test_blame_views()[buf] and not api.nvim_win_is_valid(v.winid))
				assert(
					vim.tbl_isempty(require("lazyvcs.blame_source_options")._test_records()),
					"released ownership retained"
				)
				vim.cmd("only!")
			end
		end
	end
	local function ownership()
		local _, buf, win = t.open(false)
		local baseline = vim.tbl_extend("force", original, { wrap = false, scrollbind = true })
		util.set_win_options(win, baseline)
		vim.cmd.vsplit()
		local independent = api.nvim_get_current_win()
		local untouched = { wrap = false, foldenable = false, scrollbind = true, cursorbind = true }
		util.set_win_options(independent, untouched)
		api.nvim_set_current_win(win)
		local v = open(buf)
		vim.cmd.vsplit()
		local clone = api.nvim_get_current_win()
		util.set_win_option(clone, "wrap", true)
		util.set_win_option(win, "scrollbind", false)
		-- Open the source from an unrelated donor with identical temporary values.
		api.nvim_set_current_win(independent)
		vim.cmd.vsplit()
		local unrelated_donor = api.nvim_get_current_win()
		vim.cmd.enew()
		util.set_win_options(unrelated_donor, untouched)
		vim.cmd("sbuffer " .. buf)
		local unrelated = api.nvim_get_current_win()
		util.set_win_options(unrelated, untouched)
		api.nvim_set_current_win(win)
		vim.cmd("tab sbuffer " .. buf)
		local tabbed = api.nvim_get_current_win()
		util.set_win_options(tabbed, untouched)
		api.nvim_set_current_win(clone)
		assert(blame.blame_split())
		t.wait(function()
			return not api.nvim_buf_is_valid(v.bufnr)
		end, "blame buffer retained")
		equal(
			clone,
			vim.tbl_extend("force", baseline, { wrap = true }),
			"user override prevented other option restoration"
		)
		equal(win, vim.tbl_extend("force", baseline, { scrollbind = false }), "source override prevented restoration")
		equal(independent, untouched, "pre-existing source window was enrolled")
		equal(unrelated, untouched, "unrelated source window was enrolled")
		equal(tabbed, untouched, "source in unrelated tab was enrolled")
		api.nvim_win_close(tabbed, true)
		util.set_win_options(win, original)
		api.nvim_set_current_win(win)
		v = open(buf)
		vim.cmd.vsplit()
		clone = api.nvim_get_current_win()
		api.nvim_win_close(win, true)
		t.wait(function()
			return not api.nvim_buf_is_valid(v.bufnr)
		end, "original close retained blame")
		equal(clone, original, "original close lost clone ownership")
		-- A deferred restore must settle before a newer lease captures its baseline.
		api.nvim_set_current_win(clone)
		v = open(buf)
		local other = api.nvim_create_buf(false, true)
		util.show_win_buffer(clone, other)
		t.wait(function()
			return not blame._test_blame_views()[buf]
		end, "hidden source retained blame")
		local replacement = options(clone)
		vim.cmd.vsplit()
		local pending_clone = api.nvim_get_current_win()
		util.show_win_buffer(pending_clone, buf)
		local live = open(buf)
		local temporary = options(pending_clone)
		util.show_win_buffer(pending_clone, other)
		util.show_win_buffer(pending_clone, buf)
		equal(pending_clone, temporary, "deferred cleanup overwrote newer session")
		assert(blame._test_blame_views()[buf] == live)
		assert(blame.blame_split())
		equal(pending_clone, original, "new lease captured temporary baseline")
		equal(clone, replacement, "pending restore changed replacement buffer")
		util.show_win_buffer(clone, buf)
		equal(clone, original, "pending original restore was lost")
		assert(vim.tbl_isempty(require("lazyvcs.blame_source_options")._test_records()), "pending ownership retained")
	end
	return t.cases({
		{
			"test_blame_split_restores_inherited_source_window_options",
			function()
				restored(false)
				ownership()
			end,
		},
		{
			"test_svn_blame_split_restores_inherited_source_window_options",
			function()
				restored(true)
			end,
		},
	})
end
