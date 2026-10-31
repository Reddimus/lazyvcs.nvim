return function(ctx)
	local api, h = vim.api, ctx.helpers
	local cases = {}
	local function ids(values)
		local result = {}
		for _, value in ipairs(values) do
			result[value] = true
		end
		return result
	end
	local function snapshot(buf)
		return {
			name = api.nvim_buf_get_name(buf),
			lines = api.nvim_buf_get_lines(buf, 0, -1, false),
			tick = api.nvim_buf_get_changedtick(buf),
			buftype = vim.bo[buf].buftype,
			modified = vim.bo[buf].modified,
			bufhidden = vim.bo[buf].bufhidden,
			buflisted = vim.bo[buf].buflisted,
			undolevels = vim.bo[buf].undolevels,
		}
	end
	local function wait(fn)
		ctx.wait_for(fn, "patch constructor claim did not settle", 15000)
	end
	local function add(event, mode)
		cases[#cases + 1] = {
			"test_patch_constructor_claim_" .. event .. "_" .. mode,
			function()
				local oldwins, oldbufs = ids(api.nvim_list_wins()), ids(api.nvim_list_bufs())
				local handles, errors, notify, group = {}, {}, vim.notify, nil
				vim.notify = function(message, level)
					if level == vim.log.levels.ERROR then
						errors[#errors + 1] = tostring(message)
					end
				end
				local function open(path)
					local task = require("lazyvcs").patch({ path = path })
					handles[#handles + 1] = task
					return task
				end
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					if mode ~= "empty_editor" then
						vim.cmd.edit(vim.fn.fnameescape(f.file))
						api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved original bytes", "second retained line" })
					else
						vim.cmd.enew()
					end
					local original, editor = api.nvim_get_current_buf(), api.nvim_get_current_win()
					local original_before = snapshot(original)
					local beforewins, beforebufs = ids(api.nvim_list_wins()), ids(api.nvim_list_bufs())
					local fired, touched, touched_before, newer, newerbuf, newerpath = 0, nil, nil, nil, nil, nil
					group = api.nvim_create_augroup("LazyVCSPatchConstructorClaim", { clear = true })
					api.nvim_create_autocmd(event, {
						group = group,
						nested = true,
						callback = function(data)
							if fired > 0 then
								return
							end
							local win, buf = api.nvim_get_current_win(), data.buf
							if event == "WinNew" then
								for _, candidate in ipairs(api.nvim_list_wins()) do
									if not beforewins[candidate] then
										win = candidate
										break
									end
								end
								if beforewins[win] then
									return
								end
							elseif beforebufs[buf] or api.nvim_buf_get_name(buf) ~= "" then
								return
							end
							fired = fired + 1
							if mode == "redirect" then
								api.nvim_set_current_win(editor)
							elseif mode == "rebind" then
								api.nvim_win_set_buf(win, original)
							elseif mode == "close" then
								api.nvim_win_close(win, true)
							elseif mode == "populated" or mode == "renamed" or mode == "replace" then
								touched = buf
								if mode == "replace" then
									touched = api.nvim_create_buf(true, false)
									api.nvim_win_set_buf(win, touched)
								end
								if mode ~= "populated" then
									api.nvim_buf_set_name(touched, f.root .. "/retained-template.txt")
								end
								if mode ~= "renamed" then
									api.nvim_buf_set_lines(touched, 0, -1, false, { "autocmd owned bytes" })
								end
								touched_before = snapshot(touched)
							elseif mode == "floating" then
								touched = api.nvim_create_buf(false, true)
								api.nvim_buf_set_lines(touched, 0, -1, false, { "autocmd float bytes" })
								api.nvim_open_win(
									touched,
									false,
									{ relative = "editor", row = 1, col = 1, width = 20, height = 2, style = "minimal" }
								)
								touched_before = snapshot(touched)
							elseif mode == "newer_same" or mode == "newer_other" then
								newerpath = mode == "newer_same" and f.root or h.make_git_fixture().root
								newer = open(newerpath)
								newerbuf = api.nvim_get_current_buf()
							end
						end,
					})
					local opened, task = pcall(open, f.root)
					assert(fired == 1, "native construction hook did not run exactly once")
					assert(opened, task)
					assert(
						api.nvim_buf_is_valid(original) and vim.deep_equal(snapshot(original), original_before),
						"constructor claimed an existing user buffer"
					)
					if touched then
						assert(
							api.nvim_buf_is_valid(touched) and vim.deep_equal(snapshot(touched), touched_before),
							"constructor claimed callback-owned bytes or name"
						)
					end
					if newer then
						assert(task.cancelled and not task:is_active(), "outer constructor replaced a newer request")
						wait(function()
							return newer.done
						end)
						---@cast newerbuf integer
						assert(not newer.cancelled and api.nvim_buf_is_valid(newerbuf))
						assert(
							api.nvim_buf_get_name(newerbuf) == "lazyvcs://patch/" .. newerpath,
							"outer constructor renamed a newer Patch"
						)
						assert(
							not vim.bo[newerbuf].modifiable
								and table
									.concat(api.nvim_buf_get_lines(newerbuf, 0, -1, false), "\n")
									:find("+changed", 1, true)
						)
					elseif task.cancelled then
						assert(
							mode ~= "noop" and mode ~= "empty_editor" and mode ~= "floating",
							"ordinary constructor was refused"
						)
						assert(not task:is_active())
					else
						assert(
							mode == "noop"
								or mode == "empty_editor"
								or mode == "floating"
								or event == "WinNew" and mode == "redirect",
							"unsafe initial buffer was adopted"
						)
						local buf = api.nvim_get_current_buf()
						wait(function()
							return task.done
						end)
						assert(not vim.bo[buf].modifiable and vim.bo[buf].buftype == "nofile")
						assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("+changed", 1, true))
					end
				end, debug.traceback)
				if group then
					api.nvim_del_augroup_by_id(group)
				end
				for _, task in ipairs(handles) do
					task:cancel()
				end
				for _, win in ipairs(api.nvim_list_wins()) do
					if not oldwins[win] then
						pcall(api.nvim_win_close, win, true)
					end
				end
				for _, buf in ipairs(api.nvim_list_bufs()) do
					if not oldbufs[buf] then
						pcall(api.nvim_buf_delete, buf, { force = true })
					end
				end
				vim.notify = notify
				assert(ok, err)
				assert(#errors == 0, table.concat(errors, "; "))
			end,
		}
	end
	for _, mode in ipairs({
		"noop",
		"redirect",
		"rebind",
		"close",
		"populated",
		"renamed",
		"replace",
		"newer_same",
		"newer_other",
		"empty_editor",
		"floating",
	}) do
		add("BufEnter", mode)
	end
	for _, mode in ipairs({ "noop", "redirect", "close" }) do
		add("WinNew", mode)
	end
	return cases
end
