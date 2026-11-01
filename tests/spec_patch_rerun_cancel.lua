return function(ctx)
	local api, h = vim.api, ctx.helpers
	local cases, handles = {}, {}
	local function text(buf)
		return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end
	local function wait(fn)
		ctx.wait_for(fn, "cancel reentry did not settle", 15000)
	end
	local function open(root, untracked)
		local task = require("lazyvcs").patch({ path = root, include_untracked = untracked })
		handles[#handles + 1] = task
		return task
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_rerun_cancel_" .. name,
			function()
				handles = {}
				local notify, errors = vim.notify, {}
				vim.notify = function(message, level)
					if level == vim.log.levels.ERROR then
						errors[#errors + 1] = tostring(message)
					end
				end
				local ok, err = xpcall(function()
					local f = h.make_git_fixture()
					h.write_file(f.root .. "/loose.txt", "untracked request bytes\n")
					vim.cmd.edit(vim.fn.fnameescape(f.file))
					local original = api.nvim_get_current_buf()
					api.nvim_buf_set_lines(original, 0, -1, false, { "unsaved original bytes" })
					fn(f)
					assert(api.nvim_buf_is_valid(original) and vim.bo[original].modified)
					assert(text(original) == "unsaved original bytes")
				end, debug.traceback)
				for _, task in ipairs(handles) do
					task:cancel()
				end
				vim.notify = notify
				assert(ok, err)
				assert(#errors == 0, table.concat(errors, "; "))
			end,
		}
	end
	case("unchanged_callback_reloads", function(f)
		local first, fired = open(f.root, true), 0
		local buf = api.nvim_get_current_buf()
		first:on_cancel(function()
			fired = fired + 1
		end)
		local second = open(f.root, false)
		wait(function()
			return second.done
		end)
		assert(first.cancelled and fired == 1 and not second.cancelled)
		assert(api.nvim_get_current_buf() == buf and not vim.bo[buf].modifiable)
		assert(text(buf):find("+changed", 1, true) and not text(buf):find("untracked request bytes", 1, true))
	end)
	for _, child in ipairs({ false, true }) do
		case(child and "composed_child_keeps_newer_request" or "on_cancel_keeps_newer_request", function(f)
			local first, replacement, fired = open(f.root, true), nil, 0
			local function replace()
				fired = fired + 1
				replacement = open(f.root, false)
			end
			if child then
				first:add({ kill = replace })
			else
				first:on_cancel(replace)
			end
			local outer = open(f.root, true)
			assert(first.cancelled and fired == 1 and replacement)
			assert(outer.cancelled and not outer:is_active(), "outer reload superseded a callback's newer request")
			wait(function()
				return replacement.done
			end)
			assert(not replacement.cancelled and not replacement:is_active())
			assert(text(0):find("+changed", 1, true) and not text(0):find("untracked request bytes", 1, true))
		end)
	end
	case("closed_view_keeps_newer_lifetime", function(f)
		local first, replacement, fired = open(f.root, true), nil, 0
		local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
		first:on_cancel(function()
			fired = fired + 1
			api.nvim_win_close(win, true)
			replacement = open(f.root, false)
		end)
		local outer = open(f.root, true)
		assert(first.cancelled and outer.cancelled and fired == 1 and replacement)
		assert(not api.nvim_buf_is_valid(buf))
		wait(function()
			return replacement.done
		end)
		assert(not replacement.cancelled and not text(0):find("untracked request bytes", 1, true))
	end)
	for _, renamed in ipairs({ false, true }) do
		case(renamed and "renamed_user_data_survives" or "same_uri_user_data_survives", function(f)
			local first, fired = open(f.root, true), 0
			local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
			local name = api.nvim_buf_get_name(buf)
			first:on_cancel(function()
				fired = fired + 1
				vim.bo[buf].modifiable = true
				if renamed then
					name = f.root .. "/retained.txt"
					api.nvim_buf_set_name(buf, name)
				end
				api.nvim_buf_set_lines(buf, 0, -1, false, { "kept user bytes", "second line" })
				vim.wo[win].winbar = "USER OWNED"
			end)
			local outer = open(f.root, true)
			assert(first.cancelled and fired == 1)
			assert(text(buf) == "kept user bytes\nsecond line", "reload overwrote data retained by cancellation")
			assert(outer.cancelled and not outer:is_active())
			assert(api.nvim_buf_get_name(buf) == name and vim.bo[buf].modifiable)
			assert(api.nvim_win_get_buf(win) == buf and vim.wo[win].winbar == "USER OWNED")
			local retry = open(f.root, false)
			if renamed then
				wait(function()
					return retry.done
				end)
				assert(not retry.cancelled and api.nvim_get_current_buf() ~= buf)
			else
				assert(retry.cancelled and api.nvim_get_current_buf() == buf)
			end
			assert(text(buf) == "kept user bytes\nsecond line" and vim.bo[buf].modifiable)
			assert(api.nvim_buf_get_name(buf) == name and vim.wo[win].winbar == "USER OWNED")
		end)
	end
	return cases
end
