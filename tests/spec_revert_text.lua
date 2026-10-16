return function(ctx)
	local h, api = ctx.helpers, vim.api
	local signs, actions = require("lazyvcs.signs"), require("lazyvcs.actions")
	local function bytes(path)
		local f = assert(io.open(path, "rb"))
		local value = f:read("*a")
		f:close()
		return value
	end
	local function write(path, value)
		local f = assert(io.open(path, "wb"))
		f:write(value)
		f:close()
	end
	local function options(buf)
		local result = {}
		for _, name in ipairs({ "fileencoding", "fileformat", "bomb", "binary", "endofline", "fixendofline" }) do
			result[name] = vim.bo[buf][name]
		end
		return result
	end
	local function fixture(svn, value, encoding)
		require("lazyvcs").setup({ use_gitsigns = false, debounce_ms = 0, signs = { enabled = false, debounce_ms = 0 } })
		local f = svn and h.make_svn_fixture() or h.make_git_fixture()
		write(f.file, value)
		if svn then
			h.exec({ "svn", "commit", "-m", "text base", f.file }, f.root)
		else
			h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
			h.exec({ "git", "add", "sample.txt" }, f.root)
			h.exec({ "git", "commit", "--allow-empty", "-m", "text base" }, f.root)
		end
		vim.cmd("edit " .. (encoding and "++enc=" .. encoding .. " " or "") .. vim.fn.fnameescape(f.file))
		require("lazyvcs.config").get().signs.enabled = true
		return f, api.nvim_get_current_buf()
	end
	local function loaded(buf, live, existing)
		if live then
			if existing then
				actions.next_hunk()
				return assert(require("lazyvcs.state").get(buf))
			end
			return ctx.open_diff()
		end
		local done, state, err
		signs.refresh(buf, not existing, function(value, why)
			state, err, done = value, why, true
		end)
		ctx.wait_for(function()
			return done
		end, "text signs did not load", 15000)
		return assert(state, err)
	end
	local function revert(live)
		local target = live and actions or signs
		return target.revert_hunk()
	end
	local function confirm_revert(live, buf, expected)
		revert(live)
		assert(vim.bo.buftype == "nofile", "hunk confirmation did not open")
		vim.fn.maparg("1", "n", false, true).callback()
		ctx.wait_for(function()
			return vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), expected)
		end, "confirmed hunk did not restore decoded text", 15000)
	end
	local function roundtrip(svn, live, encodings)
		local inputs = encodings
				and {
					{ "\239\187\191alpha\nbeta\n" },
					{ "caf\233\nbeta\n", "latin1" },
					{ "\255\254a\0l\0p\0h\0a\0\n\0b\0e\0t\0a\0\n\0" },
				}
			or {
				{ "alpha\r\nbeta\r\n" },
				{ "alpha\nbeta\n" },
				{ "alpha\r\nbeta\n" },
				{ "al\rpha\nbeta\n" },
			}
		for _, input in ipairs(inputs) do
			local f, buf = fixture(svn, input[1], input[2])
			local before = api.nvim_buf_get_lines(buf, 0, -1, false)
			local opts = options(buf)
			local state = loaded(buf, live)
			assert(#state.hunks == 0, "clean decoded file received a false hunk")
			assert(vim.deep_equal(state.base_lines, before), "base was not decoded to buffer text")
			api.nvim_buf_set_lines(buf, 0, 1, false, { "EDIT" })
			api.nvim_win_set_cursor(0, { 1, 0 })
			loaded(buf, live, true)
			confirm_revert(live, buf, before)
			assert(vim.deep_equal(opts, options(buf)), "text revert changed serialization options")
			vim.cmd.write()
			assert(bytes(f.file) == input[1], "confirmed revert changed encoded disk bytes")
			local status = h.exec(svn and { "svn", "status", f.file } or { "git", "status", "--porcelain" }, f.root)
			assert(status == "", "reverted text is not clean in VCS")
			h.cleanup()
		end
	end
	local function eof(svn, live)
		for _, base_eol in ipairs({ true, false }) do
			local original = "alpha" .. (base_eol and "\n" or "")
			local f, buf = fixture(svn, original)
			loaded(buf, live)
			local tick = api.nvim_buf_get_changedtick(buf)
			vim.bo[buf].fixendofline, vim.bo[buf].endofline = false, not base_eol
			assert(tick == api.nvim_buf_get_changedtick(buf), "EOF probe must leave changedtick unchanged")
			local state = loaded(buf, live, true)
			assert(#state.hunks == 1, "EOF-only change has no selectable hunk")
			if not live then
				signs.preview_diff()
				assert(
					table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("No newline", 1, true),
					"preview lost EOF state"
				)
				vim.fn.maparg("q", "n", false, true).callback()
			end
			revert(live)
			local accept = vim.fn.maparg("1", "n", false, true).callback
			vim.bo[buf].fixendofline = true
			accept()
			assert(vim.bo[buf].endofline ~= base_eol, "EOF option change did not invalidate confirmation")
			revert(live)
			vim.fn.maparg("1", "n", false, true).callback()
			ctx.wait_for(function()
				return vim.bo[buf].endofline == base_eol
			end, "EOF revert did not restore option", 15000)
			if not base_eol then
				assert(not vim.bo[buf].fixendofline, "missing newline restoration must disable fixendofline")
			end
			vim.cmd.write()
			assert(bytes(f.file) == original, "EOF revert wrote different bytes")
			h.cleanup()
		end
		local _, buf = fixture(svn, "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight")
		loaded(buf, live)
		api.nvim_buf_set_lines(buf, 0, 1, false, { "EDIT" })
		vim.bo[buf].endofline, vim.bo[buf].fixendofline = true, true
		loaded(buf, live, true)
		api.nvim_win_set_cursor(0, { 1, 0 })
		confirm_revert(live, buf, { "one", "two", "three", "four", "five", "six", "seven", "eight" })
		assert(vim.bo[buf].endofline and vim.bo[buf].fixendofline, "nonterminal revert changed EOF options")
		vim.cmd("silent undo")
		assert(api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "EDIT", "hunk text replacement was not undoable")
	end
	local function empty(svn, live)
		local f, buf = fixture(svn, "")
		local state = loaded(buf, live)
		assert(#state.hunks == 0, "zero-byte file received a false addition hunk")
		api.nvim_buf_set_lines(buf, 0, -1, false, { "typed" })
		assert(#loaded(buf, live, true).hunks == 1)
		api.nvim_buf_set_lines(buf, 0, -1, false, {})
		assert(#loaded(buf, live, true).hunks == 0, "deleting all text left a false hunk")
		vim.cmd.write()
		assert(bytes(f.file) == "")
		if live then
			actions.close(buf)
		end
		write(f.file, "\n")
		vim.cmd("edit!")
		state = loaded(buf, live)
		assert(#state.hunks == 1, "real blank line was collapsed to empty content")
		confirm_revert(live, buf, { "" })
		ctx.wait_for(function()
			return #loaded(buf, live, true).hunks == 0
		end, "blank line did not revert to empty", 15000)
		vim.cmd.write()
		assert(bytes(f.file) == "", "blank-line revert did not restore zero bytes")
		h.cleanup()
		f, buf = fixture(svn, "\n")
		loaded(buf, live)
		api.nvim_buf_set_lines(buf, 0, -1, false, {})
		assert(#loaded(buf, live, true).hunks == 1, "empty content hid a removed blank line")
		confirm_revert(live, buf, { "" })
		ctx.wait_for(function()
			return api.nvim_buf_call(buf, function()
				return vim.fn.wordcount().chars == 1
			end)
		end, "blank-line restoration did not restore EOF", 15000)
		vim.cmd.write()
		assert(bytes(f.file) == "\n", "empty-to-blank revert wrote different bytes")
	end
	local function deletion(svn, live)
		for _, deleted in ipairs({ 3, 5, 1 }) do
			local _, buf = fixture(svn, "one\ntwo\nthree\nfour\nfive\n")
			local before = api.nvim_buf_get_lines(buf, 0, -1, false)
			api.nvim_buf_set_lines(buf, deleted - 1, deleted, false, {})
			local state = loaded(buf, live)
			local anchor = require("lazyvcs.diff").hunk_anchor(state.hunks[1])
			if anchor > 1 then
				api.nvim_win_set_cursor(0, { anchor - 1, 0 })
				revert(live)
				assert(vim.bo.buftype ~= "nofile", "unmarked preceding line selected a deletion hunk")
				assert(api.nvim_buf_line_count(buf) == 4, "preceding line restored a neighboring deletion")
			end
			api.nvim_win_set_cursor(0, { anchor, 0 })
			confirm_revert(live, buf, before)
			h.cleanup()
		end
	end
	local function typed_refresh_transfer(svn)
		local f, buf = fixture(svn, "alpha\r\nbeta\r\n")
		local second = f.root .. "/second.txt"
		write(second, "\239\187\191other\nbase\n")
		if svn then
			h.exec({ "svn", "add", second }, f.root)
			h.exec({ "svn", "commit", "-m", "second", second }, f.root)
		else
			h.exec({ "git", "add", "second.txt" }, f.root)
			h.exec({ "git", "commit", "-m", "second" }, f.root)
		end
		local comparison, failure, done
		require("lazyvcs.backends").load_diff_target_async(
			{ root = f.root, path = f.file, relpath = "sample.txt", vcs = svn and "svn" or "git", section = "changes" },
			function(value, err)
				comparison, failure, done = value, err, true
			end
		)
		ctx.wait_for(function()
			return done
		end, "typed text did not load", 15000)
		assert(comparison, failure)
		local session = assert(actions.open_target(comparison))
		assert(#session.hunks == 0, "typed comparison did not decode its immutable side")
		assert(session.base_text and not session.comparison.left.bytes, "typed session retained raw base bytes")
		actions.refresh_current()
		ctx.wait_for(function()
			return not session.refresh_job
		end, "typed refresh did not finish", 15000)
		assert(#session.hunks == 0 and session.base_lines[1] == "alpha", "typed refresh lost decoded text")
		-- A profile change must reload instead of retaining the DOS-normalized base.
		vim.bo[buf].fileformat = "unix"
		actions.next_hunk()
		ctx.wait_for(function()
			return session.base_text.profile_key == require("lazyvcs.compare_text").profile(buf).key
		end, "profile change did not reload", 15000)
		assert(session.base_lines[1] == "alpha\r", "profile change reused incompatible decoded lines")
		vim.bo[buf].fileformat = "dos"
		actions.refresh_current()
		ctx.wait_for(function()
			return not session.refresh_job
		end, "DOS refresh did not finish", 15000)
		vim.cmd.edit(vim.fn.fnameescape(second))
		local next_buf = api.nvim_get_current_buf()
		ctx.wait_for(function()
			return require("lazyvcs.state").get(next_buf) ~= nil
		end, "decoded transfer did not finish", 15000)
		local next_session = assert(require("lazyvcs.state").get(next_buf))
		assert(
			next_session.base_lines[1] == "other" and #next_session.hunks == 0,
			"transfer lost the BOM decoding profile"
		)
		assert(next_session.base_text.bom and not next_session.base_bytes)
	end
	local cases = {}
	for _, mode in ipairs({
		{ "test_sign_", false, false },
		{ "test_live_diff_", false, true },
		{ "test_svn_sign_", true, false },
	}) do
		for _, spec in ipairs({
			{
				"crlf_revert_preserves_bytes",
				function()
					roundtrip(mode[2], mode[3], false)
				end,
			},
			{
				"decodes_base_before_revert",
				function()
					roundtrip(mode[2], mode[3], true)
				end,
			},
			{
				"eof_only_changes_are_revertible",
				function()
					eof(mode[2], mode[3])
				end,
			},
			{
				"empty_file_differs_from_blank_line",
				function()
					empty(mode[2], mode[3])
				end,
			},
			{
				"delete_hunk_matches_only_rendered_anchor",
				function()
					deletion(mode[2], mode[3])
				end,
			},
		}) do
			cases[#cases + 1] = { mode[1] .. spec[1], spec[2] }
		end
	end
	cases[#cases + 1] = {
		"test_svn_live_diff_decodes_base_before_revert",
		function()
			roundtrip(true, true, true)
		end,
	}
	cases[#cases + 1] = {
		"test_live_diff_decoded_documents_survive_typed_refresh_and_transfer",
		function()
			typed_refresh_transfer(false)
		end,
	}
	cases[#cases + 1] = {
		"test_svn_live_diff_decoded_documents_survive_typed_refresh_and_transfer",
		function()
			typed_refresh_transfer(true)
		end,
	}
	return cases
end
