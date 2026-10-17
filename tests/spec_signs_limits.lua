return function(ctx)
	local s = require("signs_helpers")(ctx)
	local cases = {}
	for _, svn in ipairs({ false, true }) do
		cases[#cases + 1] = {
			(svn and "test_svn_" or "test_") .. "signs_exact_limit_without_final_newline_is_supported",
			s.guard(function()
				local f = s.fixture(svn, { signs = { max_file_bytes = 10 } })
				local file = f.root .. "/limit.txt"
				local function write(bytes)
					local handle = assert(io.open(file, "wb"))
					handle:write(bytes)
					handle:close()
				end
				write("1234567890")
				if svn then
					s.h.exec({ "svn", "add", file }, f.root)
				end
				vim.cmd.edit(vim.fn.fnameescape(file))
				local buf = s.api.nvim_get_current_buf()
				vim.bo[buf].fixendofline = true
				local state = s.refresh(buf, true)
				assert(state and state.loaded and #state.hunks == 1, "exact-limit content was rejected")
				assert(not vim.bo[buf].endofline and #s.marks(buf) > 0)
				vim.cmd("LazyVCS hunk next")
				assert(s.api.nvim_win_get_cursor(0)[1] == 1)
				local source = s.api.nvim_get_current_win()
				vim.cmd("LazyVCS preview")
				s.wait(function()
					return s.api.nvim_get_current_win() ~= source
				end, "exact-limit preview did not open")
				assert(table.concat(s.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("+1234567890", 1, true))
				vim.fn.maparg("q", "n", false, true).callback()
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return s.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
				end, "exact-limit revert did not finish", 15000)
				assert(table.concat(vim.fn.readfile(file, "b"), "\n") == "1234567890", "revert wrote file")
				write("12345678901")
				vim.cmd("edit!")
				assert(not s.refresh(buf, true), "oversized disk file was admitted")
				write("1234567890")
				vim.cmd("edit!")
				s.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdefghij" })
				vim.bo[buf].fixendofline = true
				assert(not s.refresh(buf, true), "modified fixendofline serialization exceeded the limit")
				vim.bo[buf].fixendofline = false
				state = s.refresh(buf, true)
				assert(state and state.loaded and #state.hunks == 1, "nofixendofline exact-limit content was rejected")
			end),
		}
	end
	return cases
end
