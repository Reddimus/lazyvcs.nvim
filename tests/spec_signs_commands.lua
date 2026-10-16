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
	cases[#cases + 1] = {
		"test_signs_late_gitsigns_attach_cancels_native_load",
		s.guard(function()
			local f, buf = s.fixture(false, { use_gitsigns = true })
			s.refresh(buf, true)
			local attached, held, loads, completed = false, nil, 0, 0
			package.loaded.gitsigns = {
				get_hunks = function()
					return attached and {} or nil
				end,
			}
			local backends = require("lazyvcs.backends")
			---@diagnostic disable-next-line: duplicate-set-field
			backends.load_base_async = function(_, cb)
				loads, held = loads + 1, cb
				return { kill = function() end }
			end
			s.signs.refresh(buf, true, function(state, err)
				assert(not state and err:find("delegated", 1, true))
				completed = completed + 1
			end)
			s.wait(function()
				return held ~= nil
			end, "native load did not start", 15000)
			attached = true
			assert(held)({ root = f.root, relpath = "sample.txt", base_lines = { "one", "two", "three" } })
			assert(#s.marks(buf) == 0, "late gitsigns attach left native signs")
			assert(completed == 1, "delegation did not release the native load waiter")
			s.signs.refresh(buf, true)
			vim.wait(30)
			assert(loads == 1, "delegated buffer started another native load")
		end),
	}
	for _, trigger in ipairs({ "gitsigns_update", "refresh", "reload" }) do
		cases[#cases + 1] = {
			trigger == "gitsigns_update" and "test_signs_gitsigns_update_invalidates_target_and_releases_waiters"
				or (
					trigger == "reload" and "test_signs_reload_preserves_native_command_load"
					or "test_signs_non_native_refresh_preserves_native_command_load"
				),
			s.guard(function()
				local f, buf = s.fixture(false, { use_gitsigns = true })
				s.refresh(buf, true)
				local attached, held, completed, loaded, failure = false, nil, 0, nil, nil
				package.loaded.gitsigns = {
					get_hunks = function(target)
						return target == buf and attached and {} or nil
					end,
				}
				local backends = require("lazyvcs.backends")
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_base_async = function(_, cb)
					held = cb
					return { kill = function() end }
				end
				s.signs.refresh(buf, true)
				s.api.nvim_win_set_cursor(0, { 1, 0 })
				vim.cmd("LazyVCS hunk next")
				s.wait(function()
					return held ~= nil
				end, "native command load did not start", 15000)
				s.signs.refresh(buf, false, function(state, err)
					completed, loaded, failure = completed + 1, state and state.loaded, err
				end, true)
				if trigger ~= "gitsigns_update" then
					if trigger == "reload" then
						held = nil
					end
					s.signs.refresh(buf, trigger == "reload")
					s.wait(function()
						return held ~= nil
					end, "replacement command load did not start", 15000)
					assert(s.signs.current_state(buf).native, "non-native refresh reset the native load")
				end
				attached = true
				if trigger ~= "refresh" then
					s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
				else
					s.signs.refresh(buf, false)
				end
				assert(completed == 0, "delegation failed the native command's waiter before its load completed")
				assert(held)({ root = f.root, relpath = "sample.txt", base_lines = { "one", "two", "three" } })
				assert(completed == 1 and loaded and not failure, "native command waiter did not receive loaded state")
				assert(s.api.nvim_win_get_cursor(0)[1] == 2, "late delegation prevented native hunk navigation")
				assert(#s.marks(buf) == 0, "command completion left native signs beside gitsigns")
				assert(s.signs.current_state(buf).delegated and not s.signs.current_state(buf).base_lines)
				if trigger == "gitsigns_update" then
					attached = false
					held = nil
					s.signs.refresh(buf, true)
					s.wait(function()
						return held ~= nil
					end, "replacement native load did not start", 15000)
					assert(held)({ root = f.root, relpath = "sample.txt", base_lines = { "one", "two", "three" } })
					assert(#s.marks(buf) > 0)
					vim.o.hidden = true
					vim.cmd("enew!")
					attached = true
					s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
					assert(#s.marks(buf) == 0, "gitsigns update left native signs in background buffer")
					assert(s.signs.current_state(buf).delegated)
				end
			end),
		}
	end
	for _, choice in ipairs({ "confirm", "cancel" }) do
		cases[#cases + 1] = {
			"test_signs_late_attach_revert_" .. choice .. "_settles_before_delegation",
			s.guard(function()
				local f, buf = s.fixture(false, {
					use_gitsigns = true,
					source_control = { confirm_mutations = true },
				})
				local state = assert(s.refresh(buf, true))
				local backends = require("lazyvcs.backends")
				local load, held = backends.load_base_async, nil
				local attached = false
				package.loaded.gitsigns = {
					get_hunks = function()
						return attached and {} or nil
					end,
				}
				---@diagnostic disable-next-line: duplicate-set-field
				backends.load_base_async = function(_, cb)
					held = cb
					return { kill = function() end }
				end
				s.signs.refresh(buf, true)
				s.api.nvim_win_set_cursor(0, { 2, 0 })
				vim.cmd("LazyVCS hunk revert")
				s.wait(function()
					return held ~= nil
				end, "revert load did not start", 15000)
				attached = true
				s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
				-- Keep the real Git base identity so revert also exercises async validation.
				load(f.file, assert(held))
				s.wait(function()
					return type(vim.fn.maparg("1", "n", false, true).callback) == "function"
				end, "revert confirmation did not open", 15000)
				assert(not state.delegated and state.loaded, "delegated before confirmation settled")
				local generation = state.base_generation
				s.signs.refresh(buf, false)
				s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
				assert(state.base_generation == generation, "deferred delegation invalidated the base")
				vim.fn.maparg(choice == "confirm" and "1" or "3", "n", false, true).callback()
				s.wait(function()
					return state.delegated
				end, "settled revert did not delegate", 15000)
				assert(s.api.nvim_buf_get_lines(buf, 1, 2, false)[1] == (choice == "confirm" and "two" or "changed"))
				assert(state.native_holds == 0, "settled revert retained a native hold")
				assert(#s.marks(buf) == 0, "settled revert left native signs")
			end),
		}
	end
	cases[#cases + 1] = {
		"test_signs_deferred_refresh_waiters_settle_once_on_load_failure",
		s.guard(function()
			local _, buf = s.fixture(false, { use_gitsigns = true })
			s.refresh(buf, true)
			local attached, held = false, nil
			package.loaded.gitsigns = {
				get_hunks = function()
					return attached and {} or nil
				end,
			}
			local backends = require("lazyvcs.backends")
			---@diagnostic disable-next-line: duplicate-set-field
			backends.load_base_async = function(_, cb)
				held = cb
				return { kill = function() end }
			end
			s.signs.refresh(buf, true)
			vim.cmd("LazyVCS hunk next")
			s.wait(function()
				return held ~= nil
			end, "command load did not start", 15000)
			attached = true
			s.api.nvim_exec_autocmds("User", { pattern = "GitSignsUpdate", data = { buffer = buf } })
			local calls, results = { 0, 0 }, {}
			for i = 1, 2 do
				s.signs.refresh(buf, false, function(loaded, err)
					calls[i], results[i] = calls[i] + 1, { loaded, err }
				end, i == 2)
			end
			local state = s.signs.current_state(buf)
			assert(held)(nil, "Injected native load failure")
			assert(held)(nil, "Duplicate stale completion")
			assert(calls[1] == 1 and calls[2] == 1, "load failure lost or duplicated a refresh waiter")
			for _, result in ipairs(results) do
				assert(result[1] == nil and result[2] == "Injected native load failure")
			end
			assert(state.native_holds == 0, "failed load retained a command hold")
			assert(s.signs.current_state(buf) == nil, "failed load recreated a detached state")
		end),
	}
	cases[#cases + 1] = {
		"test_signs_unloaded_gitsigns_is_not_required_by_refresh",
		s.guard(function()
			local required = 0
			package.loaded.gitsigns = nil
			-- An importable module models an installed plugin that has not loaded yet.
			package.preload.gitsigns = function()
				required = required + 1
				return {
					get_hunks = function()
						return {}
					end,
				}
			end
			local _, buf = s.fixture(false, { use_gitsigns = true })
			assert(required == 0, "refresh required unloaded gitsigns")
			local state = s.refresh(buf, true)
			assert(required == 0 and package.loaded.gitsigns == nil, "refresh required unloaded gitsigns")
			assert(state and state.loaded, "unloaded gitsigns suppressed native loading")
			assert(#s.marks(buf) > 0, "unloaded gitsigns suppressed native signs")
			s.edit(buf, { "one", "another change", "three" })
			s.wait(function()
				local state = s.signs.current_state(buf)
				return state
					and state.rendered_identity
					and state.rendered_identity.changedtick == s.api.nvim_buf_get_changedtick(buf)
			end, "debounced native refresh did not finish")
			assert(required == 0 and package.loaded.gitsigns == nil, "debounced refresh loaded gitsigns")
			assert(#s.marks(buf) > 0)
		end),
	}
	cases[#cases + 1] = {
		"test_signs_guard_restores_globals_and_config_after_failure",
		s.guard(function()
			local config = require("lazyvcs.config")
			local settings, notify = vim.deepcopy(config.get()), vim.notify
			local loaded, preload = package.loaded.gitsigns, package.preload.gitsigns
			local ok, err = pcall(s.guard(function()
				config.get().use_gitsigns = not settings.use_gitsigns
				vim.notify = function() end
				package.loaded.gitsigns = {}
				package.preload.gitsigns = function()
					return {}
				end
				error("injected signs spec failure")
			end))
			assert(not ok and tostring(err):find("injected signs spec failure", 1, true))
			assert(vim.notify == notify, "guard leaked vim.notify after failure")
			assert(package.loaded.gitsigns == loaded, "guard leaked loaded gitsigns after failure")
			assert(vim.deep_equal(config.get(), settings), "guard leaked in-place config changes after failure")
			assert(package.preload.gitsigns == preload, "guard leaked preload gitsigns after failure")
		end),
	}
	cases[#cases + 1] = {
		"test_signs_delegated_edits_do_not_refresh",
		s.guard(function()
			local _, buf = s.fixture(false, { use_gitsigns = true })
			s.refresh(buf, true)
			package.loaded.gitsigns = {
				get_hunks = function()
					return {}
				end,
			}
			s.signs.refresh(buf, false)
			local refresh, count = s.signs.refresh, 0
			---@diagnostic disable-next-line: duplicate-set-field
			s.signs.refresh = function(...)
				count = count + 1
				return refresh(...)
			end
			local ok, err = pcall(function()
				for i = 1, 3 do
					s.edit(buf, { "edit " .. i })
					-- The fixture debounce is 5 ms; allow well beyond it after each edit.
					vim.wait(100)
				end
				assert(count == 0, "delegated edits scheduled " .. count .. " native refreshes")
			end)
			s.signs.refresh = refresh
			assert(ok, err)
			package.loaded.gitsigns.get_hunks = function()
				return nil
			end
			s.refresh(buf, true)
			assert(not s.signs.current_state(buf).delegated, "native load retained delegation mark")
		end),
	}
	cases[#cases + 1] = {
		"test_signs_oversized_gitsigns_commands_do_not_create_native_state",
		s.guard(function()
			local _, buf = s.fixture(false, { use_gitsigns = true, signs = { enabled = false, max_file_bytes = 1 } })
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
			for _, cold in ipairs({ true, false }) do
				if cold then
					backends.invalidate()
				end
				for _, operation in ipairs({ "next", "prev", "preview", "revert" }) do
					local n = #calls
					vim.cmd(operation == "preview" and "LazyVCS preview" or "LazyVCS hunk " .. operation)
					s.wait(function()
						return #calls > n
					end, "oversized buffer dropped " .. operation, 15000)
					assert(calls[n + 1] == operation)
					assert(s.signs.current_state(buf) == nil, "oversized delegated command created native state")
				end
			end
			package.loaded.gitsigns.preview_hunk = nil
			vim.cmd("LazyVCS preview")
			local state = s.signs.current_state(buf)
			assert(state and state.skipped and not state.base_generation, "oversized native fallback allocated a base")
		end),
	}
	return cases
end
