return function(ctx)
	local s = require("signs_helpers")(ctx)
	local cases = {}
	for _, svn in ipairs({ false, true }) do
		cases[#cases + 1] = {
			(svn and "test_svn_" or "test_") .. "signs_resume_after_shrinking_below_limit",
			s.guard(function()
				local f, buf = s.fixture(svn, { signs = { max_file_bytes = 64 } })
				s.refresh(buf, true)
				assert(#s.marks(buf) > 0)
				s.edit(buf, { string.rep("x", 100) })
				s.wait(function()
					return #s.marks(buf) == 0
				end, "oversized signs did not clear")
				assert(not s.signs.current_state(buf) or not s.signs.current_state(buf).base_text)
				s.edit(buf, { "one", "changed", "three" })
				s.wait(function()
					return #s.marks(buf) > 0
				end, "signs did not resume after shrinking")
				s.h.write_file(f.file, string.rep("x", 100))
				s.edit(buf, { "small" })
				s.wait(function()
					return #s.marks(buf) == 0
				end, "oversized disk file should stay skipped")
				s.h.write_file(f.file, "one\nchanged\nthree\n")
				s.edit(buf, { "one", "small", "three" })
				s.wait(function()
					return #s.marks(buf) > 0
				end, "disk size recovery should resume signs")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_signs_unload_releases_base_and_rejects_late_work",
		s.guard(function()
			local f, buf = s.fixture(false)
			s.refresh(buf, true)
			vim.o.hidden = true
			vim.cmd.enew()
			assert(s.signs.current_state(buf).loaded, "hidden loaded buffer should retain cache")
			vim.cmd.buffer(buf)
			local backends, held = require("lazyvcs.backends"), nil
			---@diagnostic disable-next-line: duplicate-set-field
			backends.load_base_async = function(_, cb)
				held = cb
				return { kill = function() end }
			end
			s.signs.refresh(buf, true)
			s.wait(function()
				return held ~= nil
			end, "held load did not start", 15000)
			local callbacks = {}
			vim.uv.new_timer = function()
				return {
					start = function(_, _, _, cb)
						callbacks[#callbacks + 1] = cb
					end,
					stop = function() end,
					close = function() end,
					is_closing = function()
						return false
					end,
				}
			end
			s.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
			vim.o.hidden = false
			vim.cmd.enew()
			assert(s.api.nvim_buf_is_valid(buf) and not s.api.nvim_buf_is_loaded(buf))
			assert(s.signs.current_state(buf) == nil, "unloaded buffer retained sign base")
			local deliver = function()
				assert(held)({ root = f.root, relpath = "sample.txt", base_lines = { "old" } })
				callbacks[1]()
				vim.wait(30)
			end
			deliver()
			assert(s.signs.current_state(buf) == nil, "late work resurrected unloaded state")
			vim.cmd.buffer(buf)
			local replacement = s.signs.current_state(buf)
			deliver()
			assert(
				s.signs.current_state(buf) == replacement and not replacement.loaded,
				"old work changed reloaded state"
			)
		end),
	}
	return cases
end
