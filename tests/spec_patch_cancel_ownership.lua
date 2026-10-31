return function(ctx)
	local api, h = vim.api, ctx.helpers
	local cases, group, handles = {}, nil, {}
	local function text(buf)
		return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local function wait(fn)
		ctx.wait_for(fn, "cancelled patch ownership did not settle", 15000)
	end
	local function open(opts)
		local task = require("lazyvcs").patch(opts)
		handles[#handles + 1] = task
		return task
	end
	local function keys(value)
		api.nvim_feedkeys(api.nvim_replace_termcodes(value, true, false, true), "xt", false)
	end
	for _, scenario in ipairs({
		{ "owned", "modifiable" },
		{ "user_modified", "modifiable" },
		{ "user_renamed", "modifiable" },
		{ "user_modified", "winbar" },
		{ "user_renamed", "winbar" },
	}) do
		local mode, boundary = scenario[1], scenario[2]
		cases[#cases + 1] = {
			"test_patch_cancel_ownership_post_event_retry_" .. mode .. "_" .. boundary,
			function()
				local errors, warnings, notify = {}, {}, vim.notify
				vim.notify = function(message, level)
					if level == vim.log.levels.ERROR then
						errors[#errors + 1] = tostring(message)
					elseif level == vim.log.levels.WARN then
						warnings[#warnings + 1] = tostring(message)
					end
				end
				handles = {}
				group = api.nvim_create_augroup("LazyVCSPatchCancelOwnership", { clear = true })
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					h.write_file(f.root .. "/loose", "untracked old request\n")
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local original = api.nvim_get_current_buf()
					api.nvim_buf_set_lines(original, 0, -1, false, { "unsaved original editor" })
					local request, fired, user_changed = nil, 0, false
					local function take_user_buffer()
						user_changed = true
						vim.bo.modifiable = true
						if mode == "user_renamed" then
							api.nvim_buf_set_name(0, f.root .. "/retained-user.txt")
						end
						api.nvim_buf_set_lines(0, 0, -1, false, { "retained user bytes", "keep this second line" })
						vim.wo.winbar = "USER OWNED"
					end
					api.nvim_create_autocmd("OptionSet", {
						group = group,
						pattern = "modifiable",
						nested = true,
						callback = function()
							if
								request
								and fired == 0
								and api.nvim_buf_get_name(0):match("^lazyvcs://patch/")
								and vim.bo.modifiable
							then
								fired = fired + 1
								request:cancel()
								if mode ~= "owned" and boundary == "modifiable" then
									take_user_buffer()
								end
							end
						end,
					})
					api.nvim_create_autocmd("OptionSet", {
						group = group,
						pattern = "winbar",
						nested = true,
						callback = function()
							if
								boundary == "winbar"
								and fired == 1
								and not user_changed
								and vim.wo.winbar:find("CANCELLED", 1, true)
							then
								take_user_buffer()
							end
						end,
					})
					request = open({ path = f.root })
					local kept, kept_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
					wait(function()
						return fired == 1 and request.cancelled and (mode == "owned" or user_changed)
					end)
					local kept_name, kept_undo = api.nvim_buf_get_name(kept), vim.bo[kept].undolevels
					if mode ~= "owned" then
						assert(text(kept) == "retained user bytes\nkeep this second line" and vim.bo[kept].modifiable)
					end
					-- Retry only after the native callback has returned, matching the public API route.
					local count = #api.nvim_list_wins()
					local retry = open({ path = f.root, include_untracked = false })
					local fresh = api.nvim_get_current_buf()
					if mode ~= "owned" then
						assert(
							text(kept) == "retained user bytes\nkeep this second line",
							"public same-path retry overwrote retained user bytes"
						)
					end
					if mode == "user_modified" then
						assert(retry.cancelled and not retry:is_active(), "same-URI user buffer was silently reused")
						assert(fresh == kept and #api.nvim_list_wins() == count)
						wait(function()
							return #warnings > 0
						end)
					else
						wait(function()
							return retry.done
						end)
						assert(
							not retry.cancelled
								and not vim.bo[fresh].modifiable
								and text(fresh):find("+changed", 1, true)
						)
						assert(not text(fresh):find("untracked old request", 1, true))
						assert((fresh == kept) == (mode == "owned"), "retry used the wrong buffer lifetime")
					end
					if mode ~= "owned" then
						assert(api.nvim_buf_is_valid(kept) and api.nvim_win_get_buf(kept_win) == kept)
						assert(api.nvim_buf_get_name(kept) == kept_name and vim.bo[kept].undolevels == kept_undo)
						assert(
							text(kept) == "retained user bytes\nkeep this second line" and vim.bo[kept].modifiable,
							"public retry overwrote retained user bytes"
						)
						assert(require("lazyvcs.util").get_win_option(kept_win, "winbar") == "USER OWNED")
						api.nvim_set_current_win(kept_win)
						vim.fn.setreg("a", "register sentinel", "v")
						keys('"aY')
						keys("R")
						vim.wait(30, function()
							return false
						end, 5)
						assert(vim.fn.getreg("a") == "register sentinel", "retired Y copied stale patch data")
						assert(
							text(kept) == "retained user bytes\nkeep this second line" and vim.bo[kept].modifiable,
							"retired R changed user data"
						)
						if mode == "user_renamed" then
							assert(text(fresh):find("+changed", 1, true), "retired R altered the replacement view")
						end
					end
					assert(
						api.nvim_buf_is_valid(original)
							and vim.bo[original].modified
							and text(original) == "unsaved original editor"
					)
				end, debug.traceback)
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
	return cases
end
