return function(ctx)
	local api, compat = vim.api, require("lazyvcs.compat")
	local function file_buffer(name)
		local path = vim.fs.normalize(vim.fn.tempname()) .. "-" .. name
		ctx.helpers.write_file(path, name .. "\n")
		local buf = vim.fn.bufadd(path)
		vim.fn.bufload(buf)
		return buf
	end
	return {
		{
			"test_core_compat_modified_event_reports_changed_buffer",
			function()
				local group = api.nvim_create_augroup("lazyvcs_test_compat_modified", { clear = true })
				local edited, other = file_buffer("edited"), file_buffer("other")
				local seen, filtered = {}, {}
				compat.on_modified({
					group = group,
					callback = function(args)
						seen[#seen + 1] = args.buf
					end,
				})
				compat.on_modified({
					group = group,
					buffer = edited,
					callback = function(args)
						filtered[#filtered + 1] = args.buf
					end,
				})
				local ok, err = pcall(function()
					-- Every runtime: the helper's event reaches only matching buffer autocmds.
					compat.exec_modified_autocmds(other)
					compat.exec_modified_autocmds(edited)
					assert(
						vim.deep_equal(seen, { other, edited }) and vim.deep_equal(filtered, { edited }),
						"modified events reported " .. vim.inspect({ seen = seen, filtered = filtered })
					)
					if compat.buf_modified_set then
						return
					end
					-- Neovim 0.13+: a real edit of a hidden buffer reports that buffer on the next tick.
					seen, filtered = {}, {}
					local current = api.nvim_get_current_buf()
					assert(current ~= edited and current ~= other)
					api.nvim_buf_set_lines(edited, 0, -1, false, { "changed" })
					ctx.wait_for(function()
						return #filtered > 0
					end, "editing a hidden buffer did not report its 'modified' change", 2000)
					assert(
						vim.deep_equal(seen, { edited }) and vim.deep_equal(filtered, { edited }),
						"real edit reported " .. vim.inspect({ seen = seen, filtered = filtered })
					)
					assert(api.nvim_get_current_buf() == current, "the event changed the current buffer")
				end)
				pcall(api.nvim_del_augroup_by_id, group)
				for _, buf in ipairs({ edited, other }) do
					pcall(api.nvim_buf_delete, buf, { force = true })
				end
				assert(ok, err)
			end,
		},
	}
end
