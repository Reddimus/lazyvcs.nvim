return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local function default_format(svn)
		local _, buf, _, backend = t.open(svn)
		assert(require("lazyvcs.blame").blame())
		local mark, view = t.loaded(buf)
		local text = mark[4].virt_text[1][1]
		local revision = (svn and "r" or "") .. view.entries[1].revision
		assert(
			text:find(revision, 1, true) and not text:find("{revision_label}", 1, true),
			"default format left revision_label literal: " .. text
		)
		assert(view.entries[1].backend == backend.name)
	end
	local function await(start)
		local done, result, failure = false, nil, nil
		start(function(value, err)
			done, result, failure = true, value, err
		end)
		t.wait(function()
			return done
		end, "blame metadata request did not finish", 15000)
		return assert(result, failure)
	end
	local function svn_authors()
		local f, buf, win, backend = t.open(true)
		local blame = require("lazyvcs.blame")
		for index, author in ipairs({ "Alice Smith", "José García", "Alice  2025-01-02 Smith", "solo" }) do
			t.h.write_file(f.file, "author " .. index .. "\ntwo\nthree\n")
			t.h.exec({ "svn", "commit", "--username", author, "-m", "author", f.file }, f.root)
			vim.cmd("edit!")
			local raw = assert(backend.blame_lines(f.file))
			local entry = backend.parse_blame_entries(raw)[1]
			local date = assert(raw[1]:match("(%d%d%d%d%-%d%d%-%d%d)%s+%d%d:%d%d:%d%d%s+[+-]%d%d%d%d"))
			assert(entry.author == author, "SVN author was truncated: " .. entry.author)
			assert(
				entry.date == date and entry.revision == tostring(index + 1),
				"SVN timestamp or revision was corrupted"
			)
			local async = await(function(done)
				backend.blame_lines_async(
					f.file,
					done,
					{ contents = require("lazyvcs.util").join_lines(t.api.nvim_buf_get_lines(buf, 0, -1, false)) }
				)
			end)
			assert(backend.parse_blame_entries(async)[1].author == author, "async SVN author was truncated")
			assert(blame.blame())
			local mark = t.loaded(buf)
			assert(mark[4].virt_text[1][1]:find(author, 1, true), "inline SVN author was truncated")
			blame.blame_clear()
			assert(blame.blame_split())
			t.wait(function()
				return (blame._test_blame_views()[buf] or {}).winid
			end, "SVN split absent", 15000)
			local split = blame._test_blame_views()[buf]
			local text = t.api.nvim_buf_get_lines(split.bufnr, 0, 1, false)[1]
			assert(text:find(author, 1, true) and text:find(date, 1, true), "split SVN metadata was corrupted")
			blame.blame_split()
			t.api.nvim_set_current_win(win)
			local report = assert(require("lazyvcs.blame_selection").open(1, 1))
			t.wait(function()
				return report.entries
			end, "SVN selection absent", 15000)
			assert(
				report.entries[1].author == author and report.entries[1].date == date,
				"selection SVN metadata was corrupted"
			)
			t.api.nvim_win_close(report.win, true)
			t.api.nvim_set_current_win(win)
		end
		local uncommitted = backend.parse_blame_entries({ "     -          -          - local text" })[1]
		assert(uncommitted.uncommitted and uncommitted.author == "-" and uncommitted.date == "-")
		local localized = backend.parse_blame_entries({
			"  9 Alice Smith 2026-04-01 12:34:56 -0700 (mer., 01 avr. 2026) source 2025-01-01",
		})[1]
		assert(
			localized.author == "Alice Smith" and localized.date == "2026-04-01",
			"localized SVN timestamp boundary failed"
		)
	end
	local function git_encoding()
		local f, buf, _, backend = t.open(false, { blame = { format = "{author} | {summary}" } })
		t.h.exec({ "git", "config", "user.name", "José García" }, f.root)
		t.h.write_file(f.file, "accented\ntwo\nthree\n")
		t.h.exec({ "git", "commit", "-am", "café résumé" }, f.root)
		t.h.exec({ "git", "config", "i18n.logOutputEncoding", "ISO-8859-1" }, f.root)
		vim.cmd("edit!")
		local function check(entry)
			assert(
				entry.author == "José García" and entry.summary == "café résumé",
				"Git blame metadata is not UTF-8: " .. vim.inspect(entry)
			)
		end
		check(backend.parse_blame_entries(assert(backend.blame_lines(f.file)))[1])
		local raw = await(function(done)
			backend.blame_lines_async(f.file, done)
		end)
		check(backend.parse_blame_entries(raw)[1])
		assert(require("lazyvcs.blame").blame())
		local mark = t.loaded(buf)
		assert(
			mark[4].virt_text[1][1]:find("José García | café résumé", 1, true),
			"inline Git metadata is not UTF-8"
		)
		t.patch(package.loaded, "lazyvcs.backends.blame_selection", nil)
		local loader = require("lazyvcs.backends.blame_selection")
		local contents = "accented\ntwo\nthree\n"
		local target = { path = f.file, first = 1, last = 1 }
		check(await(function(done)
			loader.load(target, contents, done)
		end)[1])
		local revision = vim.trim(t.h.exec({ "git", "rev-parse", "HEAD" }, f.root))
		target.snapshot = { vcs = "git", root = f.root, revision = revision, head = revision }
		target.item = { relpath = "sample.txt" }
		target.side = "base"
		check(await(function(done)
			loader.load(target, contents, done)
		end)[1])
		target.side = "worktree"
		local process = require("lazyvcs.backends.process")
		local lines, direct, historical = process.lines, false, false
		t.patch(process, "lines", function(args, opts, done)
			if args[2] == "blame" then
				local joined = table.concat(args, " ")
				if joined:find("--contents", 1, true) then
					direct = true
					vim.schedule(function()
						done(nil, "fatal: cannot use --contents with final commit object name")
					end)
					return { kill = function() end }
				end
				historical = true
			end
			return lines(args, opts, done)
		end)
		check(await(function(done)
			loader.load(target, contents, done)
		end)[1])
		assert(direct and historical, "historical Git fallback was not exercised")
	end
	return t.cases({
		{ "test_svn_blame_preserves_spaced_authors", svn_authors },
		{ "test_blame_git_metadata_is_utf8", git_encoding },
		{
			"test_blame_default_format_expands_revision_label",
			function()
				default_format(false)
			end,
		},
		{
			"test_svn_blame_default_format_expands_revision_label",
			function()
				default_format(true)
			end,
		},
	})
end
