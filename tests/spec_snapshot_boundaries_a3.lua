return function(ctx)
	local h = ctx.helpers
	local function write(path, bytes)
		local fd = assert(io.open(path, "wb"))
		assert(fd:write(bytes))
		assert(fd:close())
	end
	local function encode(text, encoding)
		local bytes
		if encoding:find("ucs%-4") then
			bytes = text:gsub(".", function(char)
				assert(char:byte() < 128)
				return char .. "\0\0\0"
			end)
		else
			bytes = assert(vim.iconv(text, "utf-8", "utf-16le"))
		end
		if encoding == "utf-16be" then
			bytes = bytes:gsub("..", function(pair)
				return pair:sub(2, 2) .. pair:sub(1, 1)
			end)
		elseif encoding == "ucs-4be" then
			bytes = bytes:gsub("....", function(unit)
				return unit:reverse()
			end)
		end
		return bytes
	end
	local function staged(encoding, before, after)
		local f = h.make_git_fixture()
		h.exec({ "git", "config", "core.autocrlf", "false" }, f.root)
		write(f.file, before)
		h.exec({ "git", "commit", "-am", "encoded base" }, f.root)
		write(f.file, after)
		h.exec({ "git", "add", "sample.txt" }, f.root)
		vim.cmd("edit ++enc=" .. encoding .. " " .. vim.fn.fnameescape(f.file))
		local value, failure, finished
		require("lazyvcs.backends.git").load_diff_target_async(
			{ vcs = "git", root = f.root, path = f.file, relpath = "sample.txt", section = "staged" },
			function(result, err)
				value, failure, finished = result, err, true
			end
		)
		ctx.wait_for(function()
			return finished
		end, "staged snapshot did not finish", 15000)
		assert(value, failure)
		assert(value.left.bytes == before and value.right.bytes == after, "snapshot raw identity changed")
		return value
	end
	local function visible(value, changed)
		local actions = require("lazyvcs.actions")
		local session = assert(actions.open_target(value), "staged Compare did not open")
		local ok, err = pcall(function()
			assert((#session.hunks > 0) == changed, "raw byte change vanished from staged Compare hunks")
			assert(vim.bo[session.base_bufnr].endofline == value.left.document.eol)
			assert(vim.bo[session.editable_bufnr].endofline == value.right.document.eol)
		end)
		actions.close(session)
		assert(ok, err)
	end
	return {
		{
			"test_core_staged_utf16_eof_uses_decoded_text_boundaries",
			function()
				local text = require("lazyvcs.compare_text")
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				for _, encoding in ipairs({ "utf-16le", "utf-16be" }) do
					for _, line in ipairs({ "same", "same" .. vim.fn.nr2char(0x010A), "same" .. vim.fn.nr2char(0x0A00) }) do
						for _, base_eol in ipairs({ false, true }) do
							for _, index_eol in ipairs({ false, true }) do
								local before = encode(line .. (base_eol and "\n" or ""), encoding)
								local after = encode(line .. (index_eol and "\n" or ""), encoding)
								local value = staged(encoding, before, after)
								assert(
									value.left.document.eol == base_eol and value.right.document.eol == index_eol,
									encoding .. ": raw byte 0x0A was mistaken for an encoded newline"
								)
								assert(
									value.left.lines[1] == line and value.right.lines[1] == line,
									vim.inspect({
										encoding = encoding,
										expected = line,
										left = value.left.lines,
										right = value.right.lines,
										source_encoding = value.left.document.encoding,
										buffer_encoding = vim.bo.fileencoding,
									})
								)
								assert(
									(text.serialize(value.left.document) == text.serialize(value.right.document))
										== (base_eol == index_eol),
									"staged newline-only change disappeared"
								)
								assert(
									encode(text.serialize(value.left.document), encoding) == before,
									"base text did not round trip"
								)
								assert(
									encode(text.serialize(value.right.document), encoding) == after,
									"index text did not round trip"
								)
								visible(value, base_eol ~= index_eol)
							end
						end
					end
				end
			end,
		},
		{
			"test_core_staged_utf8_raw_cr_bom_and_eof_remain_visible",
			function()
				local text = require("lazyvcs.compare_text")
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				for _, before in ipairs({ "same\n", "same\r\n", "\239\187\191same\n", "\239\187\191" }) do
					for _, after in ipairs({ "same", "same\n", "\239\187\191same" }) do
						local value = staged("utf-8", before, after)
						assert(
							text.serialize(value.left.document) == before,
							"UTF-8 base raw CR/BOM/EOF semantics changed"
						)
						assert(
							text.serialize(value.right.document) == after,
							"UTF-8 index raw CR/BOM/EOF semantics changed"
						)
						visible(value, before ~= after)
					end
				end
			end,
		},

		{
			"test_core_staged_wide_bom_only_changes_create_visible_hunks",
			function()
				require("lazyvcs").setup({ use_gitsigns = false, signs = { enabled = false } })
				local text = require("lazyvcs.compare_text")
				for _, format in ipairs({
					{ "utf-16le", "\255\254" },
					{ "utf-16be", "\254\255" },
					{ "ucs-4le", "\255\254\0\0" },
					{ "ucs-4be", "\0\0\254\255" },
				}) do
					for _, content in ipairs({ "same\n", "" }) do
						for _, add_bom in ipairs({ false, true }) do
							local raw = encode(content, format[1])
							local before = (add_bom and "" or format[2]) .. raw
							local after = (add_bom and format[2] or "") .. raw
							local value = staged(format[1], before, after)
							assert(
								text.serialize(value.left.document) ~= text.serialize(value.right.document),
								"encoded BOM-only change disappeared"
							)
							local function roundtrip(document)
								local serialized = text.serialize(document)
								local prefix = ""
								if serialized:sub(1, 3) == "\239\187\191" then
									prefix = format[2]
									serialized = serialized:sub(4)
								end
								return prefix .. encode(serialized, format[1])
							end
							assert(
								roundtrip(value.left.document) == before and roundtrip(value.right.document) == after,
								"BOM text did not round trip to raw source"
							)
							visible(value, true)
						end
					end
				end
			end,
		},
	}
end
