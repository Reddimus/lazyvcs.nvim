return function(ctx)
	local h, api = ctx.helpers, vim.api
	local cases = {}
	local function title(win)
		return api.nvim_get_option_value("winbar", { win = win, scope = "local" })
	end
	for _, mode in ipairs({
		"loading",
		"custom_title",
		"origin_closed",
		"inline_modifiable",
		"inline_winbar",
		"other_buffer",
	}) do
		cases[#cases + 1] = {
			"test_patch_clone_cancel_" .. mode,
			function()
				local backend = require("lazyvcs.backends")
				local original, held, holding, group = backend.patch_repository_async, nil, true, nil
				---@diagnostic disable-next-line: duplicate-set-field
				backend.patch_repository_async = function(repo, path, opts, done)
					return original(repo, path, opts, function(...)
						if holding then
							local args = { ... }
							held = function()
								done(unpack(args))
							end
						else
							done(...)
						end
					end)
				end
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local editor = api.nvim_get_current_buf()
					api.nvim_buf_set_lines(editor, 0, -1, false, { "UNSAVED ORIGINAL EDITOR" })
					local request = require("lazyvcs").patch({ path = f.root })
					ctx.wait_for(function()
						return held ~= nil
					end, "real collection did not complete", 15000)
					local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
					local clone, extra
					local function split()
						vim.cmd.vsplit()
						clone = api.nvim_get_current_win()
						assert(clone ~= origin and api.nvim_win_get_buf(clone) == buf)
						assert(title(clone):find("LOADING", 1, true), "copy did not inherit loading title")
					end
					local fired = 0
					if mode == "inline_modifiable" then
						group = api.nvim_create_augroup("LazyVCSPatchCloneCancel", { clear = true })
						api.nvim_create_autocmd("OptionSet", {
							group = group,
							pattern = "modifiable",
							nested = true,
							callback = function()
								if fired == 0 and api.nvim_get_current_buf() == buf and vim.bo[buf].modifiable then
									fired = fired + 1
									split()
									request:cancel()
								end
							end,
						})
					else
						split()
						if mode == "custom_title" then
							api.nvim_set_option_value("winbar", "USER CUSTOM TITLE", { win = clone, scope = "local" })
						end
						if mode == "origin_closed" then
							api.nvim_win_close(origin, true)
							vim.wait(30, function()
								return false
							end, 5)
						end
						if mode == "other_buffer" then
							api.nvim_win_set_buf(clone, editor)
							api.nvim_set_option_value(
								"winbar",
								"FOREIGN EDITOR TITLE",
								{ win = clone, scope = "local" }
							)
						end
						if mode == "inline_winbar" then
							extra = clone
							split()
							group = api.nvim_create_augroup("LazyVCSPatchCloneCancel", { clear = true })
							api.nvim_create_autocmd("OptionSet", {
								group = group,
								pattern = "winbar",
								nested = true,
								callback = function()
									if fired == 0 and tostring(vim.v.option_new):find(" files ", 1, true) then
										fired = fired + 1
										request:cancel()
									end
								end,
							})
						else
							request:cancel()
						end
					end
					assert(held)()
					ctx.wait_for(function()
						return request.cancelled and not vim.bo[buf].modifiable
					end, "cancel did not become readonly", 5000)
					vim.wait(30, function()
						return false
					end, 5)
					if group then
						api.nvim_del_augroup_by_id(group)
						group = nil
					end
					if mode:match("^inline") then
						assert(fired == 1, "native cancellation setter did not run")
					end
					assert(
						api.nvim_buf_get_lines(editor, 0, 1, false)[1] == "UNSAVED ORIGINAL EDITOR"
							and vim.bo[editor].modified
					)
					if mode == "custom_title" then
						assert(title(clone) == "USER CUSTOM TITLE", "custom clone title replaced")
					elseif mode == "other_buffer" then
						assert(title(clone) == "FOREIGN EDITOR TITLE" and api.nvim_win_get_buf(clone) == editor)
					else
						assert(
							title(clone):find("CANCELLED", 1, true),
							"native clone retains non-terminal title: " .. title(clone)
						)
					end
					if extra then
						assert(
							title(extra):find("CANCELLED", 1, true),
							"additional native clone title not terminal: " .. title(extra)
						)
					end
					if api.nvim_win_is_valid(origin) then
						assert(title(origin):find("CANCELLED", 1, true), "origin title not terminal")
					end
					if mode == "loading" then
						assert(api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "Patch request cancelled.")
						holding = false
						api.nvim_set_current_win(clone)
						api.nvim_feedkeys("R", "xt", false)
						ctx.wait_for(function()
							return title(clone):find(" files ", 1, true) and not vim.bo[buf].modifiable
						end, "native R did not recover", 15000)
						assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("+changed", 1, true))
					end
				end, debug.traceback)
				if group then
					api.nvim_del_augroup_by_id(group)
				end
				backend.patch_repository_async = original
				h.cleanup()
				assert(ok, err)
			end,
		}
	end
	return cases
end
