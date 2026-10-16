return function(ctx)
	local h, api = ctx.helpers, vim.api
	local actions, signs = require("lazyvcs.actions"), require("lazyvcs.signs")
	local cases = {}
	local function write(path, value)
		local f = assert(io.open(path, "wb"))
		f:write(value)
		f:close()
	end
	local function fixture(svn, value)
		require("lazyvcs").setup({ use_gitsigns = false, debounce_ms = 0, signs = { enabled = false, debounce_ms = 0 } })
		local f = svn and h.make_svn_fixture() or h.make_git_fixture()
		write(f.file, value)
		if svn then
			h.exec({ "svn", "commit", "-m", "base", f.file }, f.root)
		else
			h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
			h.exec({ "git", "add", "." }, f.root)
			h.exec({ "git", "commit", "--allow-empty", "-m", "base" }, f.root)
		end
		vim.cmd.edit(vim.fn.fnameescape(f.file))
		return f, api.nvim_get_current_buf()
	end
	local function open()
		local task = actions.open({ silent = true })
		ctx.wait_for(function()
			return task.done
		end, "live open")
		return assert(require("lazyvcs.state").current())
	end
	local function sign_refresh(buf, reload)
		local done, result, err
		signs.refresh(buf, reload, function(s, e)
			result, err, done = s, e, true
		end)
		ctx.wait_for(function()
			return done
		end, "sign refresh")
		return assert(result, err)
	end
	for _, svn in ipairs({ false, true }) do
		cases[#cases + 1] = {
			(svn and "test_svn_" or "test_") .. "sign_and_live_clean_no_final_newline",
			function()
				local _, buf = fixture(svn, "alpha")
				local text = require("lazyvcs.compare_text")
				assert(not vim.bo[buf].modified and not vim.bo[buf].endofline and vim.bo[buf].fixendofline)
				require("lazyvcs.config").get().signs.enabled = true
				local sg = sign_refresh(buf, true)
				local marks = api.nvim_buf_get_extmarks(buf, signs._test_state().namespace, 0, -1, {})
				local live = open()
				print(
					"clean: signs="
						.. #sg.hunks
						.. " extmarks="
						.. #marks
						.. " live="
						.. #live.hunks
						.. " capture="
						.. vim.inspect(text.serialize(assert(text.capture(buf, 1024))))
				)
				assert(
					#sg.hunks == 0 and #marks == 0 and #live.hunks == 0,
					"clean no-final-newline file received hunks/signs"
				)
				assert(
					not vim.bo[buf].modified and not vim.bo[buf].endofline and vim.bo[buf].fixendofline,
					"comparison changed clean options"
				)
			end,
		}
		cases[#cases + 1] = {
			(svn and "test_svn_" or "test_git_") .. "blame_crlf_annotations",
			function()
				local f, buf = fixture(svn, "a\r\nb\r\n")
				local backend = require(svn and "lazyvcs.backends.svn" or "lazyvcs.backends.git")
				local all_committed = true
				for _, contents in ipairs({ false, true }) do
					local done, rows, err
					backend.blame_lines_async(f.file, function(value, why)
						rows, err, done = value, why, true
					end, {
						fileformat = vim.bo[buf].fileformat,
						contents = contents and table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
							or nil,
					})
					ctx.wait_for(function()
						return done
					end, "CRLF blame")
					assert(rows, err)
					local entries = backend.parse_blame_entries(rows)
					local revisions = {}
					for _, e in ipairs(entries) do
						revisions[#revisions + 1] = e.revision
					end
					print("CRLF blame contents=" .. tostring(contents) .. " revisions=" .. vim.inspect(revisions))
					all_committed = all_committed
						and #entries == 2
						and not entries[1].uncommitted
						and not entries[2].uncommitted
				end
				assert(all_committed, "CRLF lines lost committed blame")
				local done, edited, failure
				backend.blame_lines_async(f.file, function(rows, err)
					edited, failure, done = rows and backend.parse_blame_entries(rows), err, true
				end, { contents = "x\nb\n", fileformat = vim.bo[buf].fileformat })
				ctx.wait_for(function()
					return done
				end, "edited CRLF blame")
				assert(edited, failure)
				assert(edited[1].uncommitted and not edited[2].uncommitted, "CRLF blame lost the edited line boundary")
				local blame = require("lazyvcs.blame")
				assert(blame.blame_split())
				ctx.wait_for(function()
					local view = blame._test_blame_views()[buf]
					return view and view.bufnr
				end, "CRLF blame split")
				local view = blame._test_blame_views()[buf]
				local displayed = api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
				assert(
					#displayed == 2
						and not table.concat(displayed, "\n"):find("Not Committed", 1, true)
						and not table.concat(displayed, "\n"):find("- - -", 1, true),
					vim.inspect(displayed)
				)
				blame.blame_clear()
				assert(blame.blame())
				ctx.wait_for(function()
					local inline = blame._test_inline_state().views[buf]
					return inline and inline.entries
				end, "CRLF inline blame")
				for _, entry in ipairs(blame._test_inline_state().views[buf].entries) do
					assert(not entry.uncommitted, "CRLF inline blame marked a committed line as uncommitted")
				end
				blame.blame_clear()
				api.nvim_win_set_cursor(0, { 1, 0 })
				assert(blame.line_log())
				ctx.wait_for(function()
					local log = blame._test_line_log_views()[buf]
					return log and log.winid
				end, "CRLF line history")
				local log_win = blame._test_line_log_views()[buf].winid
				if not svn then
					local head = vim.trim(h.exec({ "git", "rev-parse", "HEAD" }, f.root))
					assert(
						vim.inspect(api.nvim_win_get_config(log_win).title):find(head, 1, true),
						"CRLF line history chose the wrong revision"
					)
				end
				api.nvim_win_close(log_win, true)
				local report = assert(require("lazyvcs.blame_selection").open(1, 2))
				ctx.wait_for(function()
					return report.entries
				end, "CRLF selection blame")
				assert(
					#report.entries == 2 and not report.entries[1].uncommitted and not report.entries[2].uncommitted,
					"CRLF selection blame marked a committed line as uncommitted"
				)
				api.nvim_win_close(report.win, true)
			end,
		}
	end
	cases[#cases + 1] = {
		"test_git_blame_fileformat_change_drops_crlf_attribution",
		function()
			local _, buf = fixture(false, "a\r\nb\r\n")
			local blame, context = require("lazyvcs.blame"), require("lazyvcs.blame_context")
			local captured = assert(context.capture(buf, api.nvim_get_current_win()))
			vim.bo[buf].fileformat = "unix"
			assert(not context.valid(captured), "a fileformat change kept the blame context valid")
			vim.bo[buf].fileformat = "dos"
			local function committed(entries)
				return entries and #entries == 2 and not entries[1].uncommitted and not entries[2].uncommitted
			end
			assert(blame.blame_split())
			ctx.wait_for(function()
				local view = blame._test_blame_views()[buf]
				return view and view.bufnr and not view.loading
			end, "CRLF blame split")
			local split = blame._test_blame_views()[buf].bufnr
			local before = table.concat(api.nvim_buf_get_lines(split, 0, -1, false), "\n")
			vim.bo[buf].fileformat = "unix"
			ctx.wait_for(function()
				local view = blame._test_blame_views()[buf]
				return view and table.concat(api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n") ~= before
			end, "blame split did not reload after a fileformat change")
			blame.blame_split()
			vim.bo[buf].fileformat = "dos"
			assert(blame.blame())
			ctx.wait_for(function()
				local inline = blame._test_inline_state().views[buf]
				return inline and committed(inline.entries)
			end, "CRLF inline blame")
			vim.bo[buf].fileformat = "unix"
			ctx.wait_for(function()
				local inline = blame._test_inline_state().views[buf]
				return inline and inline.entries and inline.entries[1].uncommitted
			end, "inline blame kept CRLF attribution after a fileformat change")
			blame.blame_clear()
			vim.bo[buf].fileformat = "dos"
			local report = assert(require("lazyvcs.blame_selection").open(1, 2))
			vim.bo[buf].fileformat = "unix"
			ctx.wait_for(function()
				return report.handle == nil
					and table
						.concat(api.nvim_buf_get_lines(report.buf, 0, -1, false), "\n")
						:find("Source changed", 1, true)
			end, "selection blame used CRLF attribution after a fileformat change")
			api.nvim_win_close(report.win, true)
		end,
	}
	cases[#cases + 1] = {
		"test_capture_write_syncs_endofline_without_modified",
		function()
			local f, buf = fixture(false, "alpha")
			api.nvim_buf_set_lines(buf, 0, -1, false, { "beta" })
			assert(require("lazyvcs.compare_text").capture(buf, 1024).eol, "modified fixeol capture lost newline")
			vim.cmd.write()
			local file = assert(io.open(f.file, "rb"))
			local disk = file:read("*a")
			file:close()
			print(
				"after write: eol="
					.. tostring(vim.bo[buf].endofline)
					.. " modified="
					.. tostring(vim.bo[buf].modified)
					.. " disk="
					.. vim.inspect(disk)
			)
			assert(
				disk == "beta\n" and vim.bo[buf].endofline and not vim.bo[buf].modified,
				"write did not synchronize EOF without modification"
			)
			assert(
				require("lazyvcs.compare_text").serialize(assert(require("lazyvcs.compare_text").capture(buf, 1024)))
					== disk
			)
		end,
	}
	cases[#cases + 1] = {
		"test_live_diff_reload_failure_backoff_and_dedup",
		function()
			local f, buf = fixture(false, "alpha\n")
			local s = open()
			local backend, util = require("lazyvcs.backends"), require("lazyvcs.util")
			local load, notify, now = backend.load_base_async, util.notify, vim.uv.now
			local requests, messages, clock = {}, {}, now()
			---@diagnostic disable-next-line: duplicate-set-field
			backend.load_base_async = function(_, cb)
				requests[#requests + 1] = cb
				return { kill = function() end }
			end
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function(msg)
				messages[#messages + 1] = msg
			end
			vim.uv.now = function()
				return clock
			end
			local ok, err = xpcall(function()
				actions.refresh_current()
				requests[1](nil, "persistent failure")
				for i = 1, 3 do
					api.nvim_buf_set_lines(buf, 0, -1, false, { "edit " .. i })
					vim.wait(30, function()
						return false
					end, 5)
				end
				print("failed reload: requests=" .. #requests .. " warnings=" .. #messages)
				assert(#requests == 1 and #messages == 1, "edits retried within backoff")
				clock = clock + 4000
				api.nvim_buf_set_lines(buf, 0, -1, false, { "retry" })
				ctx.wait_for(function()
					return #requests == 2
				end, "backoff retry")
				requests[2](nil, "persistent failure")
				assert(#messages == 1, "same failure warned again")
				actions.refresh_current()
				assert(#requests == 3, "explicit refresh was delayed")
				requests[3](nil, "different failure")
				assert(#messages == 2, "changed failure did not warn")
				actions.refresh_current()
				requests[4]({ root = f.root, relpath = "sample.txt", base_label = "INDEX", base_bytes = "alpha\n" })
				assert(not s.base_invalid and not s.refresh_job, "success did not recover")
				actions.refresh_current()
				requests[5](nil, "different failure")
				assert(#messages == 3, "success did not clear last error")
			end, debug.traceback)
			backend.load_base_async, util.notify, vim.uv.now = load, notify, now
			assert(ok, err)
		end,
	}
	cases[#cases + 1] = {
		"test_svn_property_patch_normalizes_crlf_headers",
		function()
			local system = vim.system
			vim.system = function(_, opts, cb)
				opts.stdout(nil, "Index: sample.txt\r\n====\r\nProperty changes on: sample.txt\r\n")
				cb({ code = 0 })
				return { kill = function() end }
			end
			local ok, err = xpcall(function()
				local done, result, failure
				require("lazyvcs.backends.svn").load_diff_target_async({
					root = vim.fn.getcwd(),
					property_only = true,
					left = { source = { kind = "empty" } },
					right = { source = { kind = "svn_property_patch", path = "sample.txt" } },
				}, function(v, e)
					result, failure, done = v, e, true
				end)
				ctx.wait_for(function()
					return done
				end, "property patch")
				assert(result, failure)
				print("property lines=" .. vim.inspect(result.right.lines))
				assert(
					vim.deep_equal(
						result.right.lines,
						{ "Index: sample.txt", "====", "Property changes on: sample.txt" }
					),
					"property headers retained CR"
				)
			end, debug.traceback)
			vim.system = system
			assert(ok, err)
		end,
	}
	cases[#cases + 1] = {
		"test_git_check_attr_inherits_load_timeout",
		function()
			local f = fixture(false, "alpha\n")
			local process = require("lazyvcs.backends.process")
			local bytes = process.bytes
			local timeouts = {}
			---@diagnostic disable-next-line: duplicate-set-field
			process.bytes = function(args, opts, cb)
				if args[2] == "check-attr" then
					timeouts[#timeouts + 1] = opts.timeout or opts.timeout_ms or -1
				end
				return bytes(args, opts, cb)
			end
			local ok, err = xpcall(function()
				for _, method in ipairs({ "load_async", "load_base_async" }) do
					local done, result, failure
					require("lazyvcs.backends.git")[method](f.file, function(v, e)
						result, failure, done = v, e, true
					end, { timeout_ms = 1234 })
					ctx.wait_for(function()
						return done
					end, "timeout load")
					assert(result, failure)
				end
				print("check-attr timeouts=" .. vim.inspect(timeouts))
				assert(vim.deep_equal(timeouts, { 1234, 1234 }), "check-attr ignored caller timeout")
			end, debug.traceback)
			process.bytes = bytes
			assert(ok, err)
		end,
	}
	cases[#cases + 1] = {
		"test_live_diff_reload_failure_notifies_only_on_change",
		function()
			fixture(false, "alpha\n")
			open()
			local backend, util = require("lazyvcs.backends"), require("lazyvcs.util")
			local load, notify = backend.load_base_async, util.notify
			local deliver, warnings = nil, 0
			---@diagnostic disable-next-line: duplicate-set-field
			backend.load_base_async = function(_, cb)
				deliver = cb
				return { kill = function() end }
			end
			---@diagnostic disable-next-line: duplicate-set-field
			util.notify = function()
				warnings = warnings + 1
			end
			local ok, err = xpcall(function()
				for _ = 1, 3 do
					actions.refresh_current()
					assert(deliver)(nil, "persistent failure")
				end
				print("repeated backend error warnings=" .. warnings)
				assert(warnings == 1, "unchanged reload error warned repeatedly")
				actions.refresh_current()
				assert(deliver)(nil, "different failure")
				assert(warnings == 2, "a changed reload error did not warn")
			end, debug.traceback)
			backend.load_base_async, util.notify = load, notify
			assert(ok, err)
		end,
	}
	cases[#cases + 1] = {
		"test_live_diff_eof_only_revert_with_fixendofline_needs_a_write",
		function()
			-- Committed with a final newline; the worktree file lacks it and the buffer is clean.
			local f, buf = fixture(false, "alpha\n")
			write(f.file, "alpha")
			vim.cmd("edit!")
			assert(not vim.bo[buf].endofline and vim.bo[buf].fixendofline and not vim.bo[buf].modified)
			local live = open()
			assert(#live.hunks == 1, "EOF-only change did not produce a hunk")
			local hunk = live.hunks[1]
			require("lazyvcs.diff").reset_text_hunk(buf, live.base_text, live.current_text, hunk)
			assert(vim.bo[buf].endofline, "revert did not restore the final newline")
			assert(vim.bo[buf].modified, "EOF-only revert left the buffer unmodified, so :update would skip it")
			vim.cmd("update")
			local fd = assert(io.open(f.file, "rb"))
			local bytes = fd:read("*a")
			fd:close()
			assert(bytes == "alpha\n", "update did not write the restored newline: " .. vim.inspect(bytes))
		end,
	}
	cases[#cases + 1] = {
		"test_capture_write_to_other_file_keeps_endofline",
		function()
			local _, buf = fixture(false, "alpha")
			assert(not vim.bo[buf].endofline and vim.bo[buf].fixendofline)
			local copy = vim.fs.normalize(vim.fn.tempname())
			vim.cmd("silent write " .. vim.fn.fnameescape(copy))
			assert(not vim.bo[buf].endofline, "writing a copy changed this buffer's endofline")
			vim.cmd("silent write! ++bin " .. vim.fn.fnameescape(copy))
			assert(not vim.bo[buf].endofline, "a ++bin write changed this buffer's endofline")
			vim.bo[buf].modified = true
			vim.cmd("silent write! ++bin")
			assert(not vim.bo[buf].endofline, "a ++bin write of the buffer's own file changed its endofline")
			local text = require("lazyvcs.compare_text")
			assert(text.serialize(assert(text.capture(buf, 1024))) == "alpha", "clean capture gained a newline")
		end,
	}
	return cases
end
