return function(ctx)
	local api, h = vim.api, ctx.helpers
	local cases, handles, group, warnings = {}, {}, nil, {}
	local function read(buf)
		return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local function wait(fn)
		ctx.wait_for(fn, "patch setup lifetime did not settle", 15000)
	end
	local function open(opts)
		local task = require("lazyvcs").patch(opts)
		handles[#handles + 1] = task
		return task
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_setup_lifetime_" .. name,
			function()
				group = api.nvim_create_augroup("LazyVCSPatchSetupLifetime", { clear = true })
				handles = {}
				local notify, errors = vim.notify, {}
				warnings = {}
				vim.notify = function(message, level)
					if level == vim.log.levels.ERROR then
						errors[#errors + 1] = tostring(message)
					elseif level == vim.log.levels.WARN then
						warnings[#warnings + 1] = tostring(message)
					end
				end
				local ok, err = xpcall(fn, debug.traceback)
				api.nvim_del_augroup_by_id(group)
				for _, task in ipairs(handles) do
					task:cancel()
				end
				for _, buf in ipairs(api.nvim_list_bufs()) do
					if api.nvim_buf_get_name(buf):match("^lazyvcs://patch/") then
						pcall(api.nvim_buf_delete, buf, { force = true })
					end
				end
				vim.notify = notify
				assert(ok, err)
				assert(#errors == 0, table.concat(errors, "; "))
			end,
		}
	end
	local function fixture()
		local f = h.make_git_fixture()
		h.write_file(f.root .. "/loose", "old untracked request\n")
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		f.editor, f.original = api.nvim_get_current_win(), api.nvim_get_current_buf()
		api.nvim_buf_set_lines(f.original, 0, -1, false, { "unsaved original bytes" })
		return f
	end
	local function preserved(f)
		assert(
			api.nvim_buf_is_valid(f.original)
				and vim.bo[f.original].modified
				and read(f.original) == "unsaved original bytes",
			"setup changed the original editor"
		)
	end
	local function hook(event, option, fn)
		api.nvim_create_autocmd(event, {
			group = group,
			pattern = option,
			nested = true,
			callback = function()
				if api.nvim_buf_get_name(0):match("^lazyvcs://patch/") then
					fn()
				end
			end,
		})
	end
	for _, option in ipairs({ "buftype", "bufhidden", "swapfile", "buflisted", "undolevels", "name" }) do
		for _, close in ipairs({ false, true }) do
			case("constructor_" .. option .. (close and "_close" or "_noop"), function()
				local f, fired, buf = fixture(), 0, nil
				hook(option == "name" and "BufFilePost" or "OptionSet", option == "name" and "*" or option, function()
					if fired > 0 then
						return
					end
					fired, buf = fired + 1, api.nvim_get_current_buf()
					if close then
						api.nvim_win_close(0, true)
					end
				end)
				local task = open({ path = f.root })
				assert(fired == 1, "native constructor callback did not run once")
				---@cast buf integer
				if close then
					assert(
						task.cancelled and not task:is_active(),
						"retired constructor did not return a canceled handle"
					)
					assert(not api.nvim_buf_is_valid(buf), "retired pristine constructor left a hidden scratch buffer")
				else
					wait(function()
						return task.done
					end)
					assert(not task.cancelled and not vim.bo[buf].modifiable and vim.bo[buf].buftype == "nofile")
					assert(read(buf):find("+changed", 1, true), "normal constructor did not render")
				end
				preserved(f)
			end)
		end
	end
	case("constructor_renamed_modified_buffer_survives", function()
		local f, fired, kept = fixture(), false, nil
		hook("BufFilePost", "*", function()
			if fired then
				return
			end
			fired = true
			kept = api.nvim_get_current_buf()
			api.nvim_buf_set_name(kept, f.root .. "/kept-user.txt")
			api.nvim_buf_set_lines(kept, 0, -1, false, { "new user-owned bytes" })
			api.nvim_win_close(0, true)
		end)
		local task = open({ path = f.root })
		assert(fired and task.cancelled)
		---@cast kept integer
		assert(api.nvim_buf_is_valid(kept) and vim.bo[kept].modified and vim.bo[kept].buftype == "")
		assert(api.nvim_buf_get_name(kept) == f.root .. "/kept-user.txt" and read(kept) == "new user-owned bytes")
		local next_task = open({ path = f.root })
		wait(function()
			return next_task.done
		end)
		assert(api.nvim_buf_is_valid(kept) and read(kept) == "new user-owned bytes")
		preserved(f)
	end)
	for _, event in ipairs({ "name", "buftype" }) do
		case("constructor_newer_owner_" .. event, function()
			local f, fired, replacement = fixture(), false, nil
			local next_repo = h.make_git_fixture()
			h.write_file(next_repo.root .. "/loose", "new untracked request\n")
			hook(event == "name" and "BufFilePost" or "OptionSet", event == "name" and "*" or event, function()
				if fired then
					return
				end
				fired = true
				api.nvim_win_close(0, true)
				replacement = open({ path = next_repo.root, include_untracked = false })
			end)
			local old = open({ path = f.root })
			assert(fired and old.cancelled and replacement and not replacement.cancelled)
			wait(function()
				return replacement.done
			end)
			assert(not vim.bo.modifiable and read(0):find("+changed", 1, true))
			assert(not read(0):find("old untracked request", 1, true), "retired constructor replaced newer options")
			preserved(f)
		end)
	end
	for _, mode in ipairs({ "noop", "cancel", "newer_render", "newer_view", "rebind", "user_modified", "user_renamed" }) do
		case("final_fill_" .. mode, function()
			local f, task, fired, replacement, kept = fixture(), nil, 0, nil, nil
			hook("OptionSet", "modifiable", function()
				if not task or fired > 0 or not vim.bo.modifiable then
					return
				end
				fired = fired + 1
				if mode == "cancel" then
					task:cancel()
				elseif mode == "newer_render" then
					task:cancel()
					replacement = open({ path = f.root, include_untracked = false })
				elseif mode == "newer_view" then
					task:cancel()
					api.nvim_win_close(0, true)
					replacement = open({ path = f.root, include_untracked = false })
				elseif mode == "user_modified" or mode == "user_renamed" then
					task:cancel()
					kept = api.nvim_get_current_buf()
					if mode == "user_renamed" then
						api.nvim_buf_set_name(kept, f.root .. "/kept-render.txt")
					end
					api.nvim_buf_set_lines(kept, 0, -1, false, { "new user render bytes" })
					vim.wo.winbar = "USER OWNED"
				elseif mode == "rebind" then
					task:cancel()
					kept = api.nvim_create_buf(false, true)
					api.nvim_buf_set_lines(kept, 0, -1, false, { "replacement user buffer" })
					api.nvim_win_set_buf(0, kept)
					vim.bo[kept].modifiable = true
				end
			end)
			task = open({ path = f.root })
			local buf = api.nvim_get_current_buf()
			wait(function()
				return fired == 1 and not task:is_active()
			end)
			if mode == "noop" then
				assert(task.done and not task.cancelled and not vim.bo[buf].modifiable)
			elseif mode == "cancel" then
				assert(task.cancelled and api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0)
				assert(not vim.bo[buf].modifiable, "canceled render left the patch buffer writable")
				assert(
					vim.wo.winbar:find("CANCELLED", 1, true)
						and vim.wo.winbar:find("R reload", 1, true)
						and not vim.wo.winbar:find("LOADING", 1, true),
					"canceled view still reports pending work"
				)
				vim.fn.setreg("a", "register sentinel", "v")
				api.nvim_feedkeys(api.nvim_replace_termcodes('"aY', true, false, true), "xt", false)
				assert(vim.fn.getreg("a") == "register sentinel", "canceled render published unrendered patch bytes")
				local retry = open({ path = f.root })
				wait(function()
					return retry.done
				end)
				assert(
					not vim.bo[buf].modifiable and read(buf):find("+changed", 1, true),
					"same-path retry did not recover"
				)
			elseif mode == "user_modified" or mode == "user_renamed" then
				assert(
					kept and api.nvim_buf_is_valid(kept) and vim.bo[kept].modifiable,
					vim.inspect({
						valid = kept and api.nvim_buf_is_valid(kept),
						modifiable = kept and vim.bo[kept].modifiable,
						modified = kept and vim.bo[kept].modified,
						lines = kept and read(kept),
						winbar = vim.wo.winbar,
					})
				)
				assert(
					read(kept) == "new user render bytes" and vim.wo.winbar == "USER OWNED",
					"cancel cleanup changed user data or presentation"
				)
			elseif mode == "rebind" then
				assert(
					api.nvim_get_current_buf() == kept
						and vim.bo[kept].modifiable
						and read(kept) == "replacement user buffer"
				)
			else
				assert(task.cancelled and replacement and not replacement.cancelled)
				wait(function()
					return replacement.done
				end)
				assert(not vim.bo.modifiable and read(0):find("+changed", 1, true))
				assert(not read(0):find("old untracked request", 1, true), "old render replaced newer data")
			end
			preserved(f)
		end)
	end
	for _, option in ipairs({ "fileformat", "fileencoding", "bomb", "endofline", "fixendofline", "modified" }) do
		case("final_cancel_" .. option, function()
			local f, task, fired, before = fixture(), nil, 0, nil
			hook("OptionSet", option, function()
				if task and fired == 0 then
					fired, before = 1, read(0)
					task:cancel()
				end
			end)
			task = open({ path = f.root })
			wait(function()
				return fired == 1 and task.cancelled
			end)
			assert(not vim.bo.modifiable and read(0) == before, "cancel cleanup changed rendered bytes")
			assert(vim.wo.winbar:find("CANCELLED", 1, true) and vim.wo.winbar:find("R reload", 1, true))
			preserved(f)
		end)
	end

	for _, boundary in ipairs({ "readonly", "title" }) do
		case("cancel_cleanup_newer_render_" .. boundary, function()
			local f, task, phase, replacement = fixture(), nil, 0, nil
			hook("OptionSet", "modifiable", function()
				if not task then
					return
				end
				if phase == 0 and vim.bo.modifiable then
					phase = 1
					task:cancel()
				elseif boundary == "readonly" and phase == 1 and not vim.bo.modifiable then
					phase = 2
					replacement = open({ path = f.root, include_untracked = false })
				end
			end)
			hook("OptionSet", "winbar", function()
				if boundary == "title" and phase == 1 and vim.wo.winbar:find("CANCELLED", 1, true) then
					phase = 2
					replacement = open({ path = f.root, include_untracked = false })
				end
			end)
			task = open({ path = f.root })
			wait(function()
				return phase == 2 and replacement and replacement.done
			end)
			---@cast replacement {cancelled: boolean, done: boolean}
			assert(task.cancelled and not replacement.cancelled and not vim.bo.modifiable)
			assert(read(0):find("+changed", 1, true) and not read(0):find("old untracked request", 1, true))
			assert(
				not vim.wo.winbar:find("CANCELLED", 1, true) and not vim.wo.winbar:find("LOADING", 1, true),
				"old cancel settlement replaced the new title"
			)
			preserved(f)
		end)
	end

	case("locked_same_path_name_event_refuses_then_retries", function()
		local f, fired, nested, partial = fixture(), false, nil, nil
		hook("BufFilePost", "*", function()
			if fired then
				return
			end
			fired, partial = true, api.nvim_get_current_buf()
			api.nvim_win_close(0, true)
			nested = open({ path = f.root, include_untracked = false })
		end)
		local outer = open({ path = f.root })
		assert(fired and nested and nested.cancelled and outer.cancelled, "locked same-path constructor was admitted")
		assert(partial and not api.nvim_buf_is_valid(partial), "retired locked buffer survived event settlement")
		preserved(f)
		local retry = open({ path = f.root, include_untracked = false })
		wait(function()
			return retry.done
		end)
		assert(not retry.cancelled and not vim.bo.modifiable and read(0):find("+changed", 1, true))
		assert(not read(0):find("old untracked request", 1, true))
		wait(function()
			return #warnings > 0
		end)
		assert(
			table.concat(warnings, " "):lower():find("retry", 1, true),
			"locked constructor did not explain recovery"
		)
		preserved(f)
	end)

	return cases
end
