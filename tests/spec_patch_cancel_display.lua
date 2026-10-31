return function(ctx)
	local api, h = vim.api, ctx.helpers
	local cases = {}
	local function text(buf)
		return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local function wait(fn)
		ctx.wait_for(fn, "patch cancellation display did not settle", 15000)
	end
	for _, mode in ipairs({
		"collect",
		"index",
		"completed",
		"reload",
		"newer",
		"modified",
		"renamed",
		"title",
		"setter_close",
		"setter_newer",
		"setter_bytes",
		"setter_title",
	}) do
		cases[#cases + 1] = {
			"test_patch_cancel_display_" .. mode,
			function()
				local backend = require("lazyvcs.backends")
				local original, defer, notify = backend.patch_repository_async, vim.defer_fn, vim.notify
				local held, group, callbacks, handles, messages = nil, nil, {}, {}, {}
				local holding = mode ~= "completed" and mode ~= "index"
				local function open(path)
					local request = require("lazyvcs").patch({ path = path })
					handles[#handles + 1] = request
					return request
				end
				vim.notify = function(message, level)
					messages[#messages + 1] = { tostring(message), level }
				end
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
				if mode == "index" then
					vim.defer_fn = function(fn, ms)
						if ms == 1 then
							callbacks[#callbacks + 1] = fn
							return nil
						end
						return defer(fn, ms)
					end
				end
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local editor = api.nvim_get_current_buf()
					api.nvim_buf_set_lines(editor, 0, -1, false, { "unsaved original editor" })
					local request = open(f.root)
					local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
					if mode == "completed" then
						wait(function()
							return request.done
						end)
						local body, title, tick = text(buf), vim.wo[win].winbar, api.nvim_buf_get_changedtick(buf)
						assert(not request:cancel(), "finished handle accepted cancellation")
						vim.wait(30, function()
							return false
						end, 5)
						assert(
							text(buf) == body
								and vim.wo[win].winbar == title
								and api.nvim_buf_get_changedtick(buf) == tick
						)
						return
					end
					wait(function()
						return mode == "index" and #callbacks > 0 or held ~= nil
					end)
					assert(request:is_active() and not vim.bo[buf].modifiable)
					assert(text(buf):find("Loading patch", 1, true) and vim.wo[win].winbar:find("LOADING", 1, true))
					local newer
					if mode == "newer" then
						request:on_cancel(function()
							holding = false
							newer = open(f.root)
						end)
					elseif mode == "modified" or mode == "renamed" then
						request:on_cancel(function()
							vim.bo[buf].modifiable = true
							if mode == "renamed" then
								api.nvim_buf_set_name(buf, f.root .. "/retained-user.txt")
							end
							api.nvim_buf_set_lines(buf, 0, -1, false, { "retained user bytes" })
							vim.wo[win].winbar = "USER TITLE"
						end)
					elseif mode == "title" then
						vim.wo[win].winbar = "USER TITLE"
					end
					local fired = 0
					if mode:match("^setter_") then
						group = api.nvim_create_augroup("LazyVCSPatchCancelDisplay", { clear = true })
						api.nvim_create_autocmd("OptionSet", {
							group = group,
							pattern = { "modifiable", "winbar" },
							nested = true,
							callback = function(event)
								if
									request.cancelled
									and fired == 0
									and api.nvim_get_current_buf() == buf
									and (
										mode == "setter_title"
											and event.match == "winbar"
											and vim.wo[win].winbar:find("CANCELLED", 1, true)
										or mode ~= "setter_title"
											and event.match == "modifiable"
											and vim.bo[buf].modifiable
									)
								then
									fired = fired + 1
									if mode == "setter_close" then
										api.nvim_win_close(win, true)
									elseif mode == "setter_newer" then
										holding = false
										newer = open(f.root)
									else
										if mode == "setter_title" then
											vim.bo[buf].modifiable = true
											api.nvim_buf_set_name(buf, f.root .. "/setter-retained.txt")
										end
										api.nvim_buf_set_lines(buf, 0, -1, false, { "setter user bytes" })
										vim.wo[win].winbar = "SETTER TITLE"
									end
								end
							end,
						})
					end
					if mode == "reload" then
						holding = false
						api.nvim_feedkeys("R", "xt", false)
					else
						assert(request:cancel())
					end
					assert(request.cancelled)
					vim.defer_fn = defer
					if held then
						held()
					end
					for _, callback in ipairs(callbacks) do
						callback()
					end
					if mode:match("^setter_") then
						wait(function()
							return fired == 1
						end)
						if mode == "setter_close" then
							assert(not api.nvim_buf_is_valid(buf) and not api.nvim_win_is_valid(win))
						elseif mode == "setter_newer" then
							wait(function()
								return newer and newer.done
							end)
							assert(text(buf):find("+changed", 1, true) and not vim.bo[buf].modifiable)
							assert(not vim.wo[win].winbar:find("CANCELLED", 1, true))
						else
							assert(
								text(buf) == "setter user bytes"
									and vim.bo[buf].modifiable
									and vim.wo[win].winbar == "SETTER TITLE"
							)
							holding = false
							local retry = open(f.root)
							if mode == "setter_title" then
								wait(function()
									return retry.done
								end)
								assert(api.nvim_get_current_buf() ~= buf)
								assert(vim.bo[buf].modifiable and vim.wo[win].winbar == "SETTER TITLE")
							else
								assert(retry.cancelled)
							end
							assert(text(buf) == "setter user bytes")
						end
					elseif mode == "newer" or mode == "reload" then
						wait(function()
							return text(buf):find("+changed", 1, true) ~= nil and not vim.bo[buf].modifiable
						end)
						assert(not vim.wo[win].winbar:find("CANCELLED", 1, true))
						assert(mode == "reload" or newer.done)
					elseif mode == "modified" or mode == "renamed" then
						vim.wait(30, function()
							return false
						end, 5)
						assert(
							text(buf) == "retained user bytes"
								and vim.bo[buf].modifiable
								and vim.wo[win].winbar == "USER TITLE"
						)
						holding = false
						local retry = open(f.root)
						if mode == "modified" then
							assert(retry.cancelled and api.nvim_get_current_buf() == buf)
						else
							wait(function()
								return retry.done
							end)
							assert(api.nvim_get_current_buf() ~= buf and text(buf) == "retained user bytes")
						end
					else
						wait(function()
							return not text(buf):find("Loading patch", 1, true)
						end)
						assert(text(buf):find("cancelled", 1, true) and not vim.bo[buf].modifiable)
						assert(vim.wo[win].winbar:find(mode == "title" and "USER TITLE" or "CANCELLED", 1, true))
						holding = false
						api.nvim_feedkeys("R", "xt", false)
						wait(function()
							return text(buf):find("+changed", 1, true) ~= nil and not vim.bo[buf].modifiable
						end)
					end
					for _, message in ipairs(messages) do
						assert(
							(mode == "modified" or mode == "setter_bytes") and message[2] == vim.log.levels.WARN,
							message[1]
						)
					end
					assert(
						api.nvim_buf_is_valid(editor)
							and vim.bo[editor].modified
							and text(editor) == "unsaved original editor"
					)
				end, debug.traceback)
				backend.patch_repository_async, vim.defer_fn = original, defer
				if group then
					api.nvim_del_augroup_by_id(group)
				end
				for _, handle in ipairs(handles) do
					handle:cancel()
				end
				vim.notify = notify
				assert(ok, err)
			end,
		}
	end
	return cases
end
