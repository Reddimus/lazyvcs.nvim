return function(ctx)
	local s = require("signs_helpers")(ctx)
	local cases = {}
	for _, svn in ipairs({ false, true }) do
		cases[#cases + 1] = {
			(svn and "test_svn_" or "test_") .. "signs_deletion_glyph_matches_position",
			s.guard(function()
				local _, buf = s.fixture(svn, { signs = { text = { topdelete = "T", delete = "D" } } })
				for line = 1, 3 do
					local lines = { "one", "two", "three" }
					table.remove(lines, line)
					s.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
					s.refresh(buf, true)
					local marks = s.marks(buf)
					assert(#marks == 1 and marks[1][2] == math.max(0, line - 2))
					assert(
						marks[1][4].sign_text:match("%S+") == (line == 1 and "T" or "D"),
						"deletion below line one used topdelete"
					)
				end
				s.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
				s.refresh(buf, false)
				assert(#s.marks(buf) == 1 and s.marks(buf)[1][2] == 0)
			end),
		}
	end
	cases[#cases + 1] = {
		"test_signs_preview_small_editor_has_no_error_or_leak",
		s.guard(function()
			local _, buf = s.fixture(false)
			s.refresh(buf, true)
			local buffers, windows = s.api.nvim_list_bufs(), s.api.nvim_list_wins()
			local notices = {}
			vim.notify = function(msg)
				notices[#notices + 1] = msg
			end
			for _, height in ipairs({ 5, 6 }) do
				vim.o.lines = height
				for _ = 1, 2 do
					local ok, err = pcall(function()
						vim.cmd("LazyVCS preview")
					end)
					assert(ok, "small preview escaped an error: " .. tostring(err))
					assert(vim.deep_equal(buffers, s.api.nvim_list_bufs()), "small preview leaked a buffer")
					assert(vim.deep_equal(windows, s.api.nvim_list_wins()), "small preview changed windows")
				end
			end
			assert(#notices == 4 and not table.concat(notices):find("\n"), "small preview must notify once per attempt")
			vim.o.lines = 7
			vim.cmd("LazyVCS preview")
			assert(s.api.nvim_win_get_config(0).height == 1)
			s.api.nvim_win_close(0, true)
		end),
	}
	cases[#cases + 1] = {
		"test_signs_preview_open_failure_releases_buffer",
		s.guard(function()
			local _, buf = s.fixture(false)
			s.refresh(buf, true)
			local buffers = s.api.nvim_list_bufs()
			local notices = 0
			vim.notify = function(msg)
				assert(not msg:find("\n"))
				notices = notices + 1
			end
			---@diagnostic disable-next-line: duplicate-set-field
			s.api.nvim_open_win = function()
				error("injected preview failure")
			end
			local ok, err = pcall(function()
				vim.cmd("LazyVCS preview")
			end)
			assert(ok, "preview opening failure escaped: " .. tostring(err))
			assert(vim.deep_equal(buffers, s.api.nvim_list_bufs()), "failed preview leaked its scratch buffer")
			assert(notices == 1, "failed preview must notify once")
		end),
	}
	return cases
end
