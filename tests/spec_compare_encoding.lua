return function(ctx)
	local h, api = ctx.helpers, vim.api
	local compare, common = require("lazyvcs.compare"), require("lazyvcs.backends.comparison")
	local function write(path, bytes)
		local file = assert(io.open(path, "wb"))
		file:write(bytes)
		file:close()
	end
	local function bytes(path)
		local file = assert(io.open(path, "rb"))
		local value = file:read("*a")
		file:close()
		return value
	end
	local function await(start)
		local done, value, failure
		start(function(result, err)
			done, value, failure = true, result, err
		end)
		ctx.wait_for(function()
			return done
		end, "decoded preview", 15000)
		return value, failure
	end
	local function keys(value)
		api.nvim_feedkeys(api.nvim_replace_termcodes(value, true, false, true), "xt", false)
	end
	local function preview(vcs, snapshot, path)
		return await(function(done)
			require("lazyvcs.backends.compare_" .. vcs).preview(snapshot, { relpath = path, status = "M" }, done)
		end)
	end
	local function guarded(fn)
		return function()
			local fencs, ffs = vim.o.fileencodings, vim.o.fileformats
			local start = require("lazyvcs.util").system_start
			local ok, err = xpcall(fn, debug.traceback)
			pcall(compare.close)
			vim.o.fileencodings, vim.o.fileformats = fencs, ffs
			require("lazyvcs.util").system_start = start
			assert(ok, err)
		end
	end
	return {
		{
			"test_core_compare_decodes_worktree_encoding_per_source",
			guarded(function()
				vim.o.fileencodings, vim.o.fileformats = "ucs-bom,utf-8,latin1", "unix,dos"
				local f = h.make_git_fixture()
				local path = "latin.txt"
				write(f.root .. "/.gitattributes", "*.txt working-tree-encoding=ISO-8859-1\n")
				write(f.root .. "/" .. path, "caf\233\nold\n")
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "encoded base" }, f.root)
				vim.cmd.edit(vim.fn.fnameescape(f.root .. "/" .. path))
				assert(vim.bo.fileencoding == "latin1")
				api.nvim_buf_set_lines(0, 1, 2, false, { "new" })
				vim.cmd.write()
				local raw = "caf\233\nnew\n"
				assert(bytes(f.root .. "/" .. path) == raw)
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ctx.wait_for(function()
					return s.preview_result
				end, "Compare encoding", 15000)
				assert(s.shown_item.relpath == path)
				assert(
					s.preview_result.left[1] == "café" and s.preview_result.right[1] == "café",
					"preview did not decode each source as café"
				)
				assert(
					api.nvim_buf_get_lines(s.left, 0, 1, false)[1] == "café"
						and api.nvim_buf_get_lines(s.right, 0, 1, false)[1] == "café"
				)
				assert(
					s.preview_result.right_bytes == raw and s.preview_result.left_bytes == "café\nold\n",
					"raw bytes changed"
				)
				local hunks = s.navigation.saved
				assert(
					#hunks == 1
						and hunks[1].current_start == 2
						and hunks[1].current_count == 1
						and hunks[1].base_count == 1,
					vim.inspect(hunks)
				)
				keys("]v")
				assert(api.nvim_get_current_win() == s.rightwin and api.nvim_win_get_cursor(s.rightwin)[1] == 2)
				assert(compare.blame_target(s.right).bytes == raw)
				local util = require("lazyvcs.util")
				local start, fallback = util.system_start, false
				---@diagnostic disable-next-line: duplicate-set-field
				util.system_start = function(args, opts, done)
					return start(args, opts, function(raw)
						for _, arg in ipairs(args) do
							if arg:match("^%-%-source=") then
								raw.code, raw.stderr, fallback = 129, "error: unknown option 'source'", true
							end
						end
						done(raw)
					end)
				end
				local native = assert(preview("git", s.snapshot, path))
				util.system_start = start
				assert(
					fallback and native.left[1] == "café" and native.right[1] == "café",
					"older Git attribute fallback decoded a blob as worktree bytes"
				)
				compare.close(s)
				-- A normalized blob remains UTF-8 when the working file is absent.
				vim.fn.mkdir(f.root .. "/excluded", "p")
				vim.fn.mkdir(f.root .. "/visible", "p")
				write(f.root .. "/excluded/latin.txt", "caf\233\nold\n")
				write(f.root .. "/visible/file", "visible\n")
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "sparse base" }, f.root)
				write(f.root .. "/excluded/latin.txt", raw)
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "sparse change" }, f.root)
				h.exec({ "git", "sparse-checkout", "init", "--cone" }, f.root)
				h.exec({ "git", "sparse-checkout", "set", "visible" }, f.root)
				local provider = require("lazyvcs.backends.compare_git")
				local snapshot = assert(await(function(done)
					provider.resolve({ root = f.root }, "HEAD^", done)
				end))
				local result = assert(preview("git", snapshot, "excluded/latin.txt"))
				assert(
					result.right_source.kind == "index"
						and result.right[1] == "café"
						and result.right_bytes == "café\nnew\n"
				)
				assert(not vim.uv.fs_lstat(f.root .. "/excluded/latin.txt"))
			end),
		},
		{
			"test_core_compare_preview_detects_native_sources_and_profiles",
			guarded(function()
				vim.o.fileencodings, vim.o.fileformats = "ucs-bom,utf-8,latin1", "unix,dos,mac"
				local f = h.make_git_fixture()
				local provider = require("lazyvcs.backends.compare_git")
				local snapshot = assert(await(function(done)
					provider.resolve({ root = f.root }, "HEAD", done)
				end))
				local fixtures = {
					{ "latin", "caf\233\r\nold", "caf\233\r\nnew", "café" },
					{ "bom", "\239\187\191café\nold\n", "\239\187\191café\nnew\n", "café" },
					{
						"utf16",
						"\255\254c\0a\0f\0\233\0\n\0o\0l\0d\0\n\0",
						"\255\254c\0a\0f\0\233\0\n\0n\0e\0w\0\n\0",
						"café",
					},
					{ "transcode", "café\nold\n", "caf\233\nnew\n", "café" },
					{ "reverse", "caf\233\nold\n", "café\nnew\n", "café" },
					{ "empty", "", "", nil },
				}
				for _, row in ipairs(fixtures) do
					write(f.root .. "/" .. row[1], row[2])
				end
				h.exec({ "git", "add", "." }, f.root)
				h.exec({ "git", "commit", "-m", "native sources" }, f.root)
				snapshot = assert(await(function(done)
					provider.resolve({ root = f.root }, "HEAD", done)
				end))
				for _, row in ipairs(fixtures) do
					write(f.root .. "/" .. row[1], row[3])
					if row[1] == "transcode" or row[1] == "reverse" then
						vim.cmd.edit(vim.fn.fnameescape(f.root .. "/" .. row[1]))
					end
					local result, err = preview("git", snapshot, row[1])
					assert(result, err)
					assert(result.left[1] == row[4] and result.right[1] == row[4], row[1] .. " was not decoded")
					assert(result.left_bytes == row[2] and result.right_bytes == row[3])
					assert(result.left_document and result.right_document, "missing decoded documents")
					if row[1] == "latin" then
						assert(not result.right_document.eol)
					end
					if row[1] == "empty" then
						assert(result.right_document.empty)
					end
				end
				local text = require("lazyvcs.compare_text")
				local function decode(data, options, limit)
					return text.decode_preview(data, options, limit or common.max_file_bytes)
				end
				assert(
					decode("\239\187\191a\n", { encoding = "latin1" }).lines[1] == "ï»¿a",
					"explicit encoding lost BOM-shaped bytes"
				)
				assert(not decode("\255", { encoding = "utf-8" }), "invalid UTF-8 accepted")
				assert(not decode("abc", { encoding = "not-an-encoding" }), "unsupported encoding accepted")
				assert(not decode("\233\233", { encoding = "latin1" }, 3), "decoded expansion bypassed limit")
				assert(not decode("\255", { fileencodings = "ucs-bom" }), "indeterminate source accepted")
				local a = decode("abc\n", { encoding = "latin1" })
				local b = decode("abc\n", { encoding = "utf-8" })
				assert(a.profile_key ~= b.profile_key, "encoding profiles collided")
				local s = assert(compare.open({ path = f.root, base = "HEAD" }))
				ctx.wait_for(function()
					return s.preview_result
				end, "profile UI", 15000)
				local item = s.shown_item
				local old, generation = s.buffer_cache.pairs[item.relpath], s.generation
				s.navigation.reviewed = true
				require("lazyvcs.compare_navigation").remember(s)
				vim.o.fileencodings = "latin1"
				compare.refresh(s)
				ctx.wait_for(function()
					return s.generation > generation and s.preview_result
				end, "profile refresh", 15000)
				assert(s.buffer_cache.pairs[item.relpath] ~= old, "snapshot reused a different source profile")
				assert(
					not s.navigation.reviewed and not s.file_views[item.relpath],
					"review history reused a different source profile"
				)
			end),
		},
		{
			"test_svn_compare_decodes_preview_sources",
			guarded(function()
				vim.o.fileencodings = "ucs-bom,utf-8,latin1"
				local f = h.make_svn_fixture()
				write(f.file, "caf\233\nold\n")
				h.exec({ "svn", "commit", "-m", "legacy encoding" }, f.root)
				write(f.file, "caf\233\nnew\n")
				local result, err =
					preview("svn", { root = f.root, url = h.file_url(f.repo), revision = "2" }, "sample.txt")
				assert(result, err)
				assert(
					result.left[1] == "café" and result.right[1] == "café",
					"SVN preview did not decode legacy bytes"
				)
				assert(result.left_bytes == "caf\233\nold\n" and result.right_bytes == "caf\233\nnew\n")
				assert(result.left_document and result.right_document)
				local hunks = require("lazyvcs.diff").compute_hunks(result.left, result.right)
				assert(#hunks == 1 and hunks[1].current_start == 2)
				write(f.file, "café\nold\n")
				h.exec({ "svn", "commit", "-m", "UTF-8 revision" }, f.root)
				write(f.file, "caf\233\nnew\n")
				vim.cmd.edit(vim.fn.fnameescape(f.file))
				result =
					assert(preview("svn", { root = f.root, url = h.file_url(f.repo), revision = "3" }, "sample.txt"))
				assert(
					result.left[1] == "café" and result.right[1] == "café",
					"worktree hint leaked into SVN history"
				)
				write(f.file, "caf\233\nold\n")
				h.exec({ "svn", "commit", "-m", "Latin-1 revision" }, f.root)
				write(f.file, "café\nnew\n")
				vim.cmd("edit!")
				result =
					assert(preview("svn", { root = f.root, url = h.file_url(f.repo), revision = "4" }, "sample.txt"))
				assert(
					result.left[1] == "café" and result.right[1] == "café",
					"worktree hint rejected SVN legacy history"
				)
			end),
		},
	}
end
