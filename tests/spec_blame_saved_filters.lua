return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api = t.api
	return t.cases({
		{
			"test_blame_saved_legacy_identity_filter_preserves_significant_whitespace",
			function()
				local process = require("lazyvcs.backends.process")
				local run = process.lines
				-- The detected legacy Git is cached per executable; keep it out of later cases.
				local backend = require("lazyvcs.backends.blame_selection")
				backend._test_reset_legacy_git()
				t.cleanups[#t.cleanups + 1] = backend._test_reset_legacy_git
				local explicit, validation = 0, 0
				t.patch(process, "lines", function(args, opts, callback)
					if args[2] == "blame" and vim.tbl_contains(args, "--contents") then
						local dash = vim.fn.index(args, "--") + 1
						if args[dash - 1] ~= "-" then
							explicit = explicit + 1
							vim.schedule(function()
								callback(nil, "cannot use --contents with final commit object name")
							end)
							return { kill = function() end }
						end
						validation = validation + 1
					end
					return run(args, opts, callback)
				end)
				for _, mode in ipairs({ "identity", "strip", "ident" }) do
					for _, suffix in ipairs({ " ", "\t" }) do
						local f = t.open(false)
						local script = f.root .. "/filter.lua"
						t.h.write_file(
							script,
							'local s=io.read("*a"); io.write('
								.. (mode == "identity" and "s" or '(s:gsub("[ \t]+\\n", "\\n"))')
								.. '); vim.cmd("qa!")'
						)
						local function quote(value)
							return vim.fn.has("win32") == 1 and ('"' .. value:gsub('"', '\\"') .. '"')
								or ("'" .. value:gsub("'", "'\\''") .. "'")
						end
						t.h.exec({
							"git",
							"config",
							"filter.saved.clean",
							quote(vim.v.progpath) .. " --headless -u NONE -l " .. quote(script),
						}, f.root)
						t.h.write_file(
							f.root .. "/.gitattributes",
							"sample.txt filter=saved" .. (mode == "ident" and " ident" or "") .. "\n"
						)
						local second = mode == "ident" and "$Id: expanded $" or "filtered two"
						t.h.write_file(f.file, "one\n" .. second .. "\n")
						t.h.exec({ "git", "add", "sample.txt", ".gitattributes" }, f.root)
						t.h.exec({ "git", "commit", "-m", "filtered base" }, f.root)
						local pinned = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
						t.h.write_file(f.file, "ONE\n" .. second .. suffix .. "\n")
						local compare = require("lazyvcs.compare")
						local session = assert(compare.open({ path = f.root, base = "HEAD" }))
						t.cleanups[#t.cleanups + 1] = function()
							compare.close(session)
						end
						t.wait(function()
							return session.preview_result
						end, "Compare did not load", 15000)
						api.nvim_win_set_cursor(session.sidewin, { session.row_by_path["sample.txt"], 0 })
						api.nvim_set_current_win(session.sidewin)
						api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
						t.wait(function()
							return session.preview_result
								and api.nvim_buf_line_count(api.nvim_win_get_buf(session.rightwin)) == 2
						end, "sample preview did not load", 15000)
						-- Attribution must stay pinned even if HEAD advances after the preview.
						t.h.write_file(f.file, "one\nHEAD changed\n")
						t.h.exec({ "git", "commit", "-am", "later HEAD" }, f.root)
						api.nvim_set_current_win(session.rightwin)
						local request = assert(require("lazyvcs.blame_selection").open(2, 2))
						t.wait(function()
							return not request.handle
						end, "saved blame did not finish", 15000)
						local entry = request.entries and request.entries[2]
						assert(entry, vim.inspect(api.nvim_buf_get_lines(request.buf, 0, -1, false)))
						if mode == "identity" then
							assert(
								entry.uncommitted and not entry.author and not entry.revision,
								"identity filter attributed significant trailing whitespace"
							)
						else
							assert(
								not entry.uncommitted and entry.full_revision == pinned,
								"cleaned row lost pinned attribution"
							)
						end
						api.nvim_win_close(request.win, true)
						api.nvim_set_current_win(session.leftwin)
						request = assert(require("lazyvcs.blame_selection").open(2, 2))
						t.wait(function()
							return not request.handle
						end, "base blame did not finish", 15000)
						assert(
							request.entries
								and request.entries[2].full_revision == pinned
								and not request.entries[2].uncommitted,
							"base pane lost pinned attribution: "
								.. vim.inspect({
									request.entries,
									pinned,
									api.nvim_buf_get_lines(request.buf, 0, -1, false),
								})
						)
						api.nvim_win_close(request.win, true)
						compare.close(session)
					end
				end
				assert(explicit == 1 and validation == 6, "legacy validation path was not exercised")
			end,
		},
	})
end
