return function(ctx)
	local s = require("signs_helpers")(ctx)
	local cases = {}
	for _, svn in ipairs({ false, true }) do
		cases[#cases + 1] = {
			(svn and "test_svn_" or "test_") .. "signs_disabled_preserves_native_commands",
			s.guard(function()
				local _, buf = s.fixture(svn, { signs = { enabled = false } })
				assert(s.signs.current_state(buf) == nil, "disabled signs started background loading")
				s.api.nvim_win_set_cursor(0, { 1, 0 })
				vim.cmd("LazyVCS hunk next")
				s.wait(function()
					return s.api.nvim_win_get_cursor(0)[1] == 2
				end, "disabled signs prevented hunk navigation", 15000)
				assert(#s.marks(buf) == 0, "disabled signs rendered decorations")
				local source = s.api.nvim_get_current_win()
				vim.cmd("LazyVCS preview")
				s.wait(function()
					return s.api.nvim_get_current_win() ~= source
				end, "disabled signs prevented preview")
				assert(table.concat(s.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("+changed", 1, true))
				s.api.nvim_win_close(0, true)
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "two"
				end, "disabled signs prevented revert", 15000)
				s.edit(buf, { "one", "again", "three" })
				vim.cmd.write()
				assert(s.signs.current_state(buf) == nil, "disabled state survived write invalidation")
				s.api.nvim_win_set_cursor(0, { 1, 0 })
				vim.cmd("LazyVCS hunk next")
				s.wait(function()
					return s.api.nvim_win_get_cursor(0)[1] == 2
				end, "explicit command did not reload after write", 15000)
				assert(#s.marks(buf) == 0)
			end),
		}
	end
	cases[#cases + 1] = {
		"test_signs_cold_cache_dispatches_original_command",
		s.guard(function()
			local _, buf = s.fixture(false, { use_gitsigns = true })
			local calls = {}
			package.loaded.gitsigns = {
				get_hunks = function()
					return {}
				end,
				nav_hunk = function(direction)
					calls[#calls + 1] = direction
				end,
				preview_hunk = function()
					calls[#calls + 1] = "preview"
				end,
				reset_hunk = function()
					calls[#calls + 1] = "revert"
				end,
			}
			local backends = require("lazyvcs.backends")
			for i, operation in ipairs({ "next", "prev", "preview", "revert" }) do
				backends.invalidate()
				vim.cmd(operation == "preview" and "LazyVCS preview" or "LazyVCS hunk " .. operation)
				s.wait(function()
					return #calls == i
				end, "cold cache dropped " .. operation, 15000)
				assert(calls[i] == operation and #s.marks(buf) == 0)
			end
			local resolve, pending = backends.resolve_async, nil
			---@diagnostic disable-next-line: duplicate-set-field
			backends.resolve_async = function(_, cb)
				pending = cb
				return { kill = function() end }
			end
			for _, change in ipairs({ "cursor", "edit", "window", "rename", "unload" }) do
				backends.invalidate()
				vim.cmd("LazyVCS hunk next")
				assert(pending, "command did not resolve asynchronously")
				if change == "cursor" then
					s.api.nvim_win_set_cursor(0, { 2, 0 })
				elseif change == "edit" then
					s.edit(buf, { "edited" })
				elseif change == "window" then
					vim.cmd.split()
				elseif change == "rename" then
					s.api.nvim_buf_set_name(buf, vim.api.nvim_buf_get_name(buf) .. ".renamed")
				else
					vim.cmd("enew!")
					s.api.nvim_buf_delete(buf, { unload = true, force = true })
				end
				pending({ name = "git" })
				assert(#calls == 4, "stale command executed after " .. change)
			end
			backends.resolve_async = resolve
		end),
	}
	cases[#cases + 1] = {
		"test_signs_unattached_gitsigns_uses_native_fallback",
		s.guard(function()
			local f, buf = s.fixture(false, { use_gitsigns = true })
			local untracked = f.root .. "/new.txt"
			s.h.write_file(untracked, "new\ncontent\n")
			vim.cmd.edit(vim.fn.fnameescape(untracked))
			buf = s.api.nvim_get_current_buf()
			vim.b[buf].gitsigns_status_dict = { added = 2 }
			local delegated = 0
			package.loaded.gitsigns = {
				get_hunks = function()
					return nil
				end,
				nav_hunk = function()
					delegated = delegated + 1
				end,
				preview_hunk = function()
					delegated = delegated + 1
				end,
				reset_hunk = function()
					delegated = delegated + 1
				end,
			}
			vim.cmd("LazyVCS preview")
			s.wait(function()
				return vim.bo.filetype == "diff"
			end, "unattached gitsigns suppressed native preview", 15000)
			s.api.nvim_win_close(0, true)
			vim.cmd("LazyVCS hunk revert")
			s.wait(function()
				return s.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == ""
			end, "untracked revert did not use empty base", 15000)
			assert(delegated == 0, "unattached gitsigns received a command")
			package.loaded.gitsigns.get_hunks = function()
				return {}
			end
			vim.cmd("LazyVCS hunk next")
			assert(delegated == 1, "usable empty gitsigns state should delegate")
			package.loaded.gitsigns.nav_hunk = nil
			s.edit(buf, { "new" })
			vim.cmd("LazyVCS preview")
			assert(delegated == 2)
			package.loaded.gitsigns.preview_hunk = nil
			vim.cmd("LazyVCS preview")
			s.wait(function()
				return vim.bo.filetype == "diff"
			end, "missing gitsigns method suppressed native fallback", 15000)
			s.api.nvim_win_close(0, true)
		end),
	}
	return cases
end
