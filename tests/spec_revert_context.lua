return function(ctx)
	local h, api = ctx.helpers, vim.api
	local backends, signs = require("lazyvcs.backends"), require("lazyvcs.signs")
	local function guarded(fn)
		return function()
			local load, versioned = backends.load_base_async, backends.is_versioned_async
			local ok, err = xpcall(fn, debug.traceback)
			backends.load_base_async, backends.is_versioned_async = load, versioned
			pcall(h.cleanup)
			vim.cmd("silent! only!")
			assert(ok, err)
		end
	end
	local function fixture(svn)
		require("lazyvcs").setup({
			use_gitsigns = false,
			signs = { enabled = false },
			source_control = { confirm_mutations = false },
		})
		local f = svn and h.make_svn_transfer_fixture() or h.make_git_transfer_fixture()
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		-- Explicit refresh still uses the native signs state with rendering enabled.
		require("lazyvcs.config").get().signs.enabled = true
		return f, api.nvim_get_current_buf()
	end
	local function pending()
		local requests = {}
		---@diagnostic disable-next-line: duplicate-set-field
		backends.load_base_async = function(path, cb)
			requests[#requests + 1] = { path = path, cb = cb }
			return { kill = function() end }
		end
		return requests
	end
	local function deliver(request, f, base)
		request.cb({
			root = f.root,
			relpath = vim.fn.fnamemodify(request.path, ":t"),
			base_label = "BASE",
			base_lines = base,
		})
	end
	local function wait_requests(requests, n)
		ctx.wait_for(function()
			return #requests >= n
		end, "base request did not start", 15000)
	end
	local function discard(svn)
		local f = fixture(svn)
		local done
		---@diagnostic disable-next-line: duplicate-set-field
		backends.is_versioned_async = function(_, cb)
			done = cb
			return {}
		end
		local owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
		local original = api.nvim_get_current_win()
		vim.cmd.edit(vim.fn.fnameescape(f.file2))
		done(true)
		assert(vim.bo.buftype ~= "nofile", "stale discard opened a confirmation over another file")
		assert(not owner.active, "cancelled discard retained ownership")
		assert(vim.fn.readfile(f.file1)[2] == "changed" and vim.fn.readfile(f.file2)[4] == "amber")
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
		done(true)
		local popup = api.nvim_get_current_win()
		local title = api.nvim_win_get_config(popup).title
		assert(vim.inspect(title):find(f.file1, 1, true), "discard prompt must identify the exact target")
		local accept = vim.fn.maparg("1", "n", false, true).callback
		api.nvim_win_set_buf(original, vim.fn.bufnr(f.file2))
		accept()
		assert(not owner.active, "changed origin was accepted by confirmation")
		assert(vim.fn.readfile(f.file1)[2] == "changed", "confirmation restored a changed origin")
		vim.cmd.edit(vim.fn.fnameescape(f.file1))
		owner = assert(require("lazyvcs.buffer_ops").revert_buffer())
		done(true)
		vim.fn.maparg("1", "n", false, true).callback()
		ctx.wait_for(function()
			return not owner.active
		end, "discard did not finish", 15000)
		assert(vim.fn.readfile(f.file1)[2] == "two", "unchanged origin did not restore")
		assert(vim.fn.readfile(f.file2)[4] == "amber", "discard changed the sibling")
	end
	return {
		{
			"test_sign_pending_revert_preserves_invocation_context",
			guarded(function()
				for _, confirmation in ipairs({ false, true, "suppressed" }) do
					for _, change in ipairs({ "cursor", "window", "buffer", "rename", "edit", "eof", "unchanged" }) do
						local f, buf = fixture(false)
						require("lazyvcs.config").get().source_control.confirm_mutations = confirmation ~= false
						if confirmation == "suppressed" then
							require("lazyvcs.source_control.confirm").mutation({}, function() end)
							vim.fn.maparg("2", "n", false, true).callback()
						end
						api.nvim_buf_set_lines(buf, 0, -1, false, { "FIRST", "two", "three", "four", "LAST" })
						api.nvim_win_set_cursor(0, { 1, 0 })
						local requests = pending()
						signs.revert_hunk()
						wait_requests(requests, 1)
						if change == "cursor" then
							api.nvim_win_set_cursor(0, { 5, 0 })
						elseif change == "window" then
							vim.cmd("split")
						elseif change == "buffer" then
							vim.cmd.enew()
						elseif change == "rename" then
							api.nvim_buf_set_name(buf, f.root .. "/renamed.txt")
						elseif change == "edit" then
							api.nvim_buf_set_lines(buf, 1, 2, false, { "EDIT" })
						elseif change == "eof" then
							vim.bo[buf].endofline = false
						end
						deliver(requests[1], f, f.base1)
						if change == "unchanged" and confirmation == true then
							vim.fn.maparg("1", "n", false, true).callback()
						end
						assert(
							api.nvim_buf_get_lines(buf, 4, 5, false)[1] == "LAST",
							"pending revert followed the later cursor"
						)
						assert(
							api.nvim_buf_get_lines(buf, 0, 1, false)[1] == (change == "unchanged" and "one" or "FIRST"),
							"pending revert accepted changed " .. change
						)
						assert(vim.bo.buftype ~= "nofile", "stale hunk opened a prompt")
						h.cleanup()
						vim.cmd("silent! only!")
					end
				end
			end),
		},
		{
			"test_sign_rename_invalidates_cached_and_pending_base",
			guarded(function()
				for _, loaded in ipairs({ true, false }) do
					local f, buf = fixture(false)
					local requests = pending()
					signs.refresh(buf, true)
					wait_requests(requests, 1)
					if loaded then
						deliver(requests[1], f, f.base1)
					end
					api.nvim_buf_set_name(buf, f.file2)
					api.nvim_buf_set_lines(buf, 0, -1, false, { "EDIT", "blue", "green", "yellow", "orange" })
					signs.revert_hunk()
					wait_requests(requests, 2)
					deliver(requests[2], f, f.base2)
					if not loaded then
						deliver(requests[1], f, f.base1)
					end
					api.nvim_win_set_cursor(0, { 1, 0 })
					signs.revert_hunk()
					assert(
						api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "red",
						"renamed buffer accepted the previous entry's base"
					)
					h.cleanup()
				end
			end),
		},
		{ "test_revert_cancels_after_origin_context_changes", guarded(function()
			discard(false)
		end) },
		{ "test_svn_revert_cancels_after_origin_context_changes", guarded(function()
			discard(true)
		end) },
	}
end
