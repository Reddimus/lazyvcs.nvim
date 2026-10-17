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
				-- Without fixendofline the offset already omits the final newline.
				s.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcdefghijk" })
				assert(not vim.bo[buf].endofline and not vim.bo[buf].fixendofline)
				assert(not s.refresh(buf, true), "nofixendofline content one byte over the limit was admitted")
				local skipped = s.signs.current_state(buf)
				assert(not skipped or skipped.skipped, "nofixendofline content one byte over the limit was not skipped")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_signs_one_byte_over_limit_uses_large_revert",
		s.guard(function()
			local f, buf = s.fixture(false, { use_gitsigns = true, signs = { max_file_bytes = 10 } })
			s.h.write_file(f.file, "123456789\n")
			s.h.exec({ "git", "add", "sample.txt" }, f.root)
			s.h.exec({ "git", "commit", "-m", "exact limit" }, f.root)
			vim.cmd("edit!")
			s.refresh(buf, true)
			s.edit(buf, { "1234567890" })
			vim.bo[buf].fixendofline = true
			assert(not s.refresh(buf, false), "oversized buffer was admitted")
			local state = s.signs.current_state(buf)
			assert(state and state.skipped and not state.loaded, "serialized limit + 1 was not marked too_large")
			local reads, loads = 0, 0
			package.loaded.gitsigns = {
				get_hunks = function()
					reads = reads + 1
					return {
						{
							removed = { start = 1, count = 1, lines = { "123456789" } },
							added = { start = 1, count = 1, lines = { "1234567890" } },
						},
					}
				end,
			}
			local backends = require("lazyvcs.backends")
			local load = backends.load_base_async
			---@diagnostic disable-next-line: duplicate-set-field
			backends.load_base_async = function(...)
				loads = loads + 1
				return load(...)
			end
			vim.cmd("LazyVCS hunk revert")
			s.wait(function()
				return s.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "123456789"
			end, "one-byte-over-limit revert did not finish")
			assert(reads > 0 and loads == 0, "oversized revert used the native base path")
			assert(table.concat(vim.fn.readfile(f.file, "b"), "\n") == "123456789\n", "revert changed disk")
		end),
	}
	return cases
end
