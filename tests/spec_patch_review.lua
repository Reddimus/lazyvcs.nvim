-- Regressions for the independent patch review. Exercise delivered bytes and UI actions.
return function(ctx)
	local h, patch = ctx.helpers, require("lazyvcs.patch")
	local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
	local cases = {}
	local function write(path, text)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(text))
		fd:close()
	end
	local function read(path)
		local fd = assert(io.open(path, "rb"))
		local text = fd:read("*a")
		fd:close()
		return text
	end
	local function wait(fn)
		ctx.wait_for(fn, "patch review regression timed out", 20000)
	end
	local function get(path, opts)
		local done, text, err
		patch.open(vim.tbl_extend("force", opts or {}, {
			path = path,
			on_done = function(t, e)
				text, err, done = t, e, true
			end,
		}))
		wait(function()
			return done
		end)
		assert(not err, err)
		return text
	end
	local function ui(path)
		local task = patch.open({ path = path })
		wait(function()
			return task.done
		end)
		return vim.api.nvim_get_current_buf()
	end
	local function keys(text)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end
	local function jump(path, change, line)
		local buf = ui(path)
		local found
		for row, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
			if text == change then
				vim.api.nvim_win_set_cursor(0, { row, 0 })
				found = true
				break
			end
		end
		assert(found, "missing change " .. change)
		keys("gf")
		assert(vim.api.nvim_buf_get_name(0) == path .. "/sample.txt", vim.api.nvim_buf_get_name(0))
		assert(vim.api.nvim_win_get_cursor(0)[1] == line, "wrong new-side line")
	end
	local function case(name, fn)
		cases[#cases + 1] = {
			"test_patch_review_" .. name,
			function()
				local schedule, set_lines = vim.schedule, vim.api.nvim_buf_set_lines
				local ok, err = xpcall(fn, debug.traceback)
				vim.schedule, vim.api.nvim_buf_set_lines = schedule, set_lines
				patch._test_text = nil
				for _, buf in ipairs(vim.api.nvim_list_bufs()) do
					if vim.api.nvim_buf_get_name(buf):match("^lazyvcs://patch/") then
						pcall(vim.api.nvim_buf_delete, buf, { force = true })
					end
				end
				assert(ok, err)
			end,
		}
	end
	case("svn_empty_addition_applies", function()
		local f = h.make_svn_fixture()
		write(f.root .. "/empty", "")
		write(f.root .. "/nonempty", "new\n")
		local text = get(f.root)
		local dir = h.tempdir()
		h.exec({ "svn", "checkout", h.file_url(f.repo), dir .. "/wc" }, dir)
		write(dir .. "/patch.diff", text)
		h.exec({ "svn", "patch", dir .. "/patch.diff" }, dir .. "/wc")
		assert(vim.uv.fs_stat(dir .. "/wc/empty"), "svn patch lost the empty addition")
		assert(read(dir .. "/wc/empty") == "")
		assert(read(dir .. "/wc/nonempty") == "new\n")
	end)
	case("svn_selected_unversioned_file_and_tree", function()
		local f = h.make_svn_fixture()
		write(f.root .. "/loose", "loose\n")
		assert(get(f.root .. "/loose"):find("+loose", 1, true))
		assert(get(f.root .. "/loose", { include_untracked = false }) == "")
		vim.fn.mkdir(f.root .. "/tree")
		write(f.root .. "/tree/child", "child\n")
		assert(get(f.root .. "/tree"):find("+child", 1, true))
	end)
	case("nul_yank_preserves_bytes", function()
		local f = h.make_git_fixture()
		write(f.root .. "/.gitattributes", "sample.txt diff\n")
		write(f.file, "one\nchanged\0byte\nthree\n")
		local text = get(f.root)
		assert(text:find("\0", 1, true), "fixture must produce a textual NUL patch")
		ui(f.root)
		keys('"aY')
		-- getreg's list form preserves line boundaries and represents NUL as newline.
		local rows = vim.fn.getreg("a", 1, true)
		for i, row in ipairs(rows) do
			rows[i] = row:gsub("\n", "\0")
		end
		assert(table.concat(rows, "\n") .. "\n" == text, "Y lost NUL patch bytes")
	end)
	case("git_noprefix_navigation_tracked_and_untracked", function()
		local f = h.make_git_fixture()
		h.exec({ "git", "config", "diff.noprefix", "true" }, f.root)
		jump(f.root, "+changed", 2)
		write(f.root .. "/new", "untracked\n")
		assert(get(f.root):find("+++ b/new", 1, true), "untracked diff lost its destination prefix")
	end)
	case("git_suppressed_blank_context_navigation", function()
		local f = h.make_git_fixture()
		write(f.file, "one\n\nthree\nfour\n")
		h.exec({ "git", "add", "sample.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "blank context" }, f.root)
		h.exec({ "git", "config", "diff.suppressBlankEmpty", "true" }, f.root)
		write(f.file, "one\n\nthree\nchanged\n")
		jump(f.root, "+changed", 4)
	end)
	case("git_selected_symlink_entry", function()
		if vim.fn.has("win32") == 1 then
			error({ lazyvcs_skip = "symlink fixture requires POSIX" })
		end
		local f = h.make_git_fixture()
		local outside = h.tempdir() .. "/target"
		write(outside, "outside\n")
		assert(vim.uv.fs_symlink(outside, f.root .. "/link"))
		local text = get(f.root .. "/link")
		assert(text:find("new file mode 120000", 1, true))
		assert(text:find("+" .. outside, 1, true))
		assert(not text:find("sample.txt", 1, true), "selected entry included another file")
	end)
	case("clean_write_is_empty", function()
		local f = h.make_git_fixture()
		write(f.file, "one\ntwo\nthree\n")
		assert(get(f.root) == "")
		local buf = ui(f.root)
		local out = h.tempdir() .. "/clean.diff"
		vim.cmd("write! " .. vim.fn.fnameescape(out))
		assert(read(out) == "", "clean patch wrote presentation bytes")
		assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "")
		assert(vim.wo.winbar:find("No changes under " .. f.root, 1, true))
	end)
	case("million_lines_responsive", function()
		local root = h.tempdir()
		patch._test_text = "diff --git a/sample.txt b/sample.txt\n--- a/sample.txt\n+++ b/sample.txt\n@@ -0,0 +1,1000000 @@\n"
			.. string.rep("+x\n", 1000000)
		local schedule, set_lines = vim.schedule, vim.api.nvim_buf_set_lines
		local longest, fills = 0, 0
		vim.schedule = function(fn)
			return schedule(function()
				local start = vim.uv.hrtime()
				fn()
				longest = math.max(longest, (vim.uv.hrtime() - start) / 1e6)
			end)
		end
		---@diagnostic disable-next-line: duplicate-set-field
		vim.api.nvim_buf_set_lines = function(buf, first, last, strict, rows)
			if #rows > 1 then
				fills = fills + 1
			end
			return set_lines(buf, first, last, strict, rows)
		end
		local timer = assert(vim.uv.new_timer())
		local last, gap = vim.uv.hrtime(), 0
		timer:start(1, 1, function()
			local now = vim.uv.hrtime()
			gap, last = math.max(gap, (now - last) / 1e6), now
		end)
		local ok, buf = pcall(ui, root)
		gap = math.max(gap, (vim.uv.hrtime() - last) / 1e6)
		timer:stop()
		timer:close()
		assert(ok, buf)
		assert(vim.api.nvim_buf_line_count(buf) == 1000004, "injected patch was not filled")
		assert(fills == 1, "patch must be filled in one API call")
		assert(vim.wo.winbar:find("+1000000 -0", 1, true), "incorrect whole-patch counts")
		print(string.format("patch million-line maximum callback: %.1f ms; event-loop gap: %.1f ms", longest, gap))
		assert(gap < 250, string.format("patch event loop stalled for %.1f ms", gap))
		assert(longest < 250, string.format("patch callback blocked for %.1f ms", longest))
	end)
	case("index_checkpoints_navigation", function()
		local f = h.make_git_fixture()
		local rows = {}
		for i = 1, 1100 do
			rows[i] = tostring(i)
		end
		write(f.file, table.concat(rows, "\n") .. "\n")
		h.exec({ "git", "add", "sample.txt" }, f.root)
		h.exec({ "git", "commit", "-m", "long context" }, f.root)
		h.exec({ "git", "config", "diff.context", "2000" }, f.root)
		table.remove(rows, 500)
		rows[1], rows[899] = "start", "end"
		write(f.file, table.concat(rows, "\n") .. "\n")
		jump(f.root, "+end", 899)
	end)
	case("cancel_during_indexing_and_reload", function()
		local root = h.tempdir()
		patch._test_text = "diff --git a/file b/file\n@@ -0,0 +1,1000000 @@\n" .. string.rep("+x\n", 1000000)
		local first = patch.open({ path = root })
		local buf = vim.api.nvim_get_current_buf()
		vim.wait(10, function()
			return false
		end, 1)
		assert(not first.done, "fixture must still be indexing")
		patch._test_text = "replacement\n"
		local second = patch.open({ path = root })
		wait(function()
			return second.done
		end)
		assert(first.cancelled)
		assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "replacement")
		-- A pending batch from the old generation must also be harmless on wipe.
		patch._test_text = string.rep("+x\n", 1000000)
		local third = patch.open({ path = root })
		vim.wait(10, function()
			return false
		end, 1)
		assert(not third.done, "fixture must still be indexing before wipe")
		vim.api.nvim_buf_delete(buf, { force = true })
		vim.wait(10, function()
			return false
		end, 1)
		assert(third.cancelled and not vim.api.nvim_buf_is_valid(buf))
	end)
	case("changelog_unreleased_added", function()
		local text = read(root .. "/CHANGELOG.md")
		local added = assert(text:match("## %[Unreleased%](.-)\n## %[%d")):match("### Added(.*)")
		assert(added and added:find(":LazyVCS patch [path]", 1, true), "patch missing from Unreleased / Added")
		local released = assert(text:match("## %[0%.12%.0%](.-)\n## %["))
		assert(not released:find(":LazyVCS patch", 1, true), "patch changed released history")
	end)
	return cases
end
