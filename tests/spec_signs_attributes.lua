return function(ctx)
	local s = require("signs_helpers")(ctx)
	local function fixture(encoded)
		local f = s.fixture(false)
		local attrs = "sample.txt ident" .. (encoded and " working-tree-encoding=UTF-16LE-BOM" or "") .. "\n"
		s.h.write_file(f.root .. "/.gitattributes", attrs)
		local raw = "$Id$\ncafé\n"
		if encoded then
			raw = "\255\254" .. vim.iconv(raw, "utf-8", "utf-16le")
		end
		local file = assert(io.open(f.file, "wb"))
		file:write(raw)
		file:close()
		s.h.exec({ "git", "add", ".gitattributes", "sample.txt" }, f.root)
		s.h.exec({ "git", "commit", "-m", "ident" }, f.root)
		assert(os.remove(f.file))
		s.h.exec({ "git", "checkout-index", "--force", "--", "sample.txt" }, f.root)
		vim.cmd("edit! " .. (encoded and "++enc=utf-16le " or "") .. vim.fn.fnameescape(f.file))
		return f, s.api.nvim_get_current_buf()
	end
	local cases = {}
	for _, encoded in ipairs({ false, true }) do
		cases[#cases + 1] = {
			encoded and "test_signs_ident_encoding_is_decoded_once"
				or "test_signs_ident_checkout_form_avoids_external_filters",
			s.guard(function()
				local f, buf = fixture(encoded)
				local state, err = s.refresh(buf, true)
				assert(state, err)
				assert(#state.hunks == 0, "clean ident checkout produced a false hunk")
				local git, diff = require("lazyvcs.backends.git"), require("lazyvcs.diff")
				for _, load in ipairs({ git.load, git.load_base }) do
					local payload = assert(load(f.file))
					local base = assert(diff.decode_base(buf, payload, 1048576))
					assert(
						#diff.compute_text_hunks(
								base,
								assert(require("lazyvcs.compare_text").capture(buf, 1048576))
							) == 0,
						"sync ident base differs from checkout"
					)
				end
				local before = s.api.nvim_buf_get_lines(buf, 0, -1, false)
				vim.cmd("LazyVCS hunk revert")
				assert(vim.deep_equal(before, s.api.nvim_buf_get_lines(buf, 0, -1, false)))
				local historical
				git.load_diff_target_async(
					{ root = f.root, path = f.file, relpath = "sample.txt", section = "staged", status = "M " },
					function(value)
						historical = value
					end
				)
				s.wait(function()
					return historical ~= nil
				end, "historical load did not complete", 15000)
				assert(historical.right.lines[1] == "$Id$", "historical index content was expanded")
				if not encoded then
					s.h.write_file(f.root .. "/.gitattributes", "sample.txt ident filter=blocked\n")
					s.h.exec({ "git", "config", "filter.blocked.smudge", "lazyvcs-filter-must-never-run" }, f.root)
					s.h.exec({ "git", "config", "filter.blocked.required", "true" }, f.root)
					state, err = s.refresh(buf, true)
					assert(state, "background loader ran external smudge: " .. tostring(err))
					assert(state.base_lines[1] == "$Id$", "filtered index must retain raw bytes")
					assert(assert(git.load_base(f.file)).base_bytes:match("^%$Id%$"))
				end
			end),
		}
	end
	return cases
end
