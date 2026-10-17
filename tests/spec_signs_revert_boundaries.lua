return function(ctx)
	local s = require("signs_helpers")(ctx)
	local cases = {}
	local function confirm()
		s.wait(function()
			return type(vim.fn.maparg("1", "n", false, true).callback) == "function"
		end, "revert confirmation absent", 15000)
		vim.fn.maparg("1", "n", false, true).callback()
	end
	for _, large in ipairs({ false, true }) do
		cases[#cases + 1] = {
			"test_signs_revert_applies_only_confirmed_boundaries_" .. (large and "large" or "native"),
			s.guard(function()
				local f, buf = s.fixture(false, {
					use_gitsigns = true,
					signs = { max_file_bytes = large and 1 or 1048576 },
					source_control = { confirm_mutations = true },
				})
				local base = {
					"zeta",
					"gamma",
					"gamma",
					"epsilon",
					"epsilon",
					"epsilon",
					"alpha",
					"delta",
					"delta",
					"zeta",
					"gamma",
					"epsilon",
				}
				local edited = {
					"zeta",
					"epsilon changed",
					"gamma",
					"gamma changed",
					"epsilon",
					"alpha changed",
					"delta",
					"delta",
					"gamma",
					"gamma",
					"beta changed",
				}
				s.h.write_file(f.file, table.concat(base, "\n") .. "\n")
				s.h.exec({ "git", "add", "sample.txt" }, f.root)
				s.h.write_file(f.file, table.concat(edited, "\n") .. "\n")
				vim.cmd("edit!")
				if not large then
					s.refresh(buf, true)
				end
				local resets = 0
				package.loaded.gitsigns = {
					get_hunks = function()
						return {
							{
								removed = { start = 3, count = 1, lines = { "gamma" } },
								added = { start = 4, count = 1, lines = { "gamma changed" } },
							},
						}
					end,
					reset_hunk = function()
						resets = resets + 1
						s.api.nvim_buf_set_lines(buf, 3, 4, false, { "gamma", "epsilon", "epsilon" })
					end,
				}
				s.signs.refresh(buf, false)
				s.api.nvim_win_set_cursor(0, { 4, 0 })
				vim.cmd("LazyVCS hunk revert")
				confirm()
				s.wait(function()
					return (s.signs.current_state(buf).native_holds or 0) == 0
				end, "revert did not settle", 15000)
				local expected = vim.deepcopy(edited)
				expected[4] = "gamma"
				assert(
					vim.deep_equal(s.api.nvim_buf_get_lines(buf, 0, -1, false), expected),
					"revert exceeded confirmed boundaries"
				)
				assert(resets == 0, "revert delegated hunk selection again")
				assert(
					table.concat(vim.fn.readfile(f.file, "b"), "\n") == table.concat(edited, "\n") .. "\n",
					"revert changed disk"
				)
				assert(
					s.h.exec({ "git", "show", ":sample.txt" }, f.root) == table.concat(base, "\n") .. "\n",
					"revert changed index"
				)
				vim.cmd.undo()
				assert(vim.deep_equal(s.api.nvim_buf_get_lines(buf, 0, -1, false), edited), "undo lost original edits")
			end),
		}
	end
	for _, base_eol in ipairs({ false, true }) do
		cases[#cases + 1] = {
			"test_signs_large_revert_restores_" .. (base_eol and "final_newline" or "missing_final_newline"),
			s.guard(function()
				local _, buf = s.fixture(false, { use_gitsigns = true, signs = { max_file_bytes = 1 } })
				local resolved = false
				require("lazyvcs.backends").resolve_async(s.api.nvim_buf_get_name(buf), function()
					resolved = true
				end)
				s.wait(function()
					return resolved
				end, "repository did not resolve", 15000)
				s.api.nvim_buf_set_lines(buf, 0, -1, false, { "last changed" })
				vim.bo[buf].endofline = not base_eol
				vim.bo[buf].fixendofline = false
				package.loaded.gitsigns = {
					get_hunks = function()
						return {
							{
								removed = { start = 1, count = 1, lines = { "last" }, no_nl_at_eof = not base_eol },
								added = { start = 1, count = 1, lines = { "last changed" }, no_nl_at_eof = base_eol },
							},
						}
					end,
					reset_hunk = function()
						s.api.nvim_buf_set_lines(buf, 0, -1, false, { "last" })
					end,
				}
				s.api.nvim_win_set_cursor(0, { 1, 0 })
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return s.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "last"
				end, "EOF revert did not finish", 15000)
				assert(vim.bo[buf].endofline == base_eol, "reported hunk EOF state was lost")
				package.loaded.gitsigns.reset_hunk = nil
				-- Exercise deletion anchors, additions and the stored empty-buffer line.
				for _, item in ipairs({
					{ { "tail" }, 0, {}, { "head" }, { "head", "tail" } },
					{ { "head", "tail" }, 1, {}, { "middle" }, { "head", "middle", "tail" } },
					{ { "head" }, 1, {}, { "tail" }, { "head", "tail" } },
					{ { "extra" }, 1, { "extra" }, {}, { "" } },
					{ {}, 0, {}, { "restored" }, { "restored" } },
				}) do
					s.api.nvim_buf_set_lines(buf, 0, -1, false, item[1])
					vim.bo[buf].endofline = true
					---@diagnostic disable-next-line: duplicate-set-field
					package.loaded.gitsigns.get_hunks = function()
						return {
							{
								removed = { start = 1, count = #item[4], lines = item[4] },
								added = { start = item[2], count = #item[3], lines = item[3] },
							},
						}
					end
					s.api.nvim_win_set_cursor(0, { math.max(item[2], 1), 0 })
					vim.cmd("LazyVCS hunk revert")
					assert(
						vim.deep_equal(s.api.nvim_buf_get_lines(buf, 0, -1, false), item[5]),
						"reported slice boundary was lost"
					)
				end
				local file = s.api.nvim_buf_get_name(buf)
				vim.fn.writefile({ "" }, file)
				vim.cmd("edit!")
				s.h.write_file(file, "oversized saved file\n")
				s.signs.refresh(buf, false)
				assert(not require("lazyvcs.compare_text").identity(buf).empty, "blank-line fixture is empty")
				---@diagnostic disable-next-line: duplicate-set-field
				package.loaded.gitsigns.get_hunks = function()
					return {
						{
							removed = { start = 1, count = 1, lines = { "head" } },
							added = { start = 0, count = 0, lines = {} },
						},
					}
				end
				s.api.nvim_win_set_cursor(0, { 1, 0 })
				vim.cmd("LazyVCS hunk revert")
				assert(
					vim.deep_equal(s.api.nvim_buf_get_lines(buf, 0, -1, false), { "head", "" }),
					"revert removed an unchanged blank line"
				)
				for _, stale_eof in ipairs({ false, true }) do
					s.api.nvim_buf_set_lines(buf, 0, -1, false, { "current" })
					vim.bo[buf].endofline = true
					---@diagnostic disable-next-line: duplicate-set-field
					package.loaded.gitsigns.get_hunks = function()
						return {
							{
								removed = { start = 1, count = 1, lines = { "base" } },
								added = {
									start = 1,
									count = 1,
									lines = { stale_eof and "current" or "stale" },
									no_nl_at_eof = stale_eof,
								},
							},
						}
					end
					s.api.nvim_win_set_cursor(0, { 1, 0 })
					vim.cmd("LazyVCS hunk revert")
					assert(
						s.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "current",
						"stale reported slice was reverted"
					)
					assert((s.signs.current_state(buf).native_holds or 0) == 0, "stale reported slice retained a hold")
				end
			end),
		}
	end
	return cases
end
