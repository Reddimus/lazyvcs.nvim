return function(ctx)
	local t = require("blame_helpers").new(ctx)
	local api, text = t.api, require("lazyvcs.compare_text")
	local function rejected(bytes, err, label)
		assert(
			not bytes and err and err:find("UCS-2 cannot represent characters above U+FFFF", 1, true),
			label .. " accepted unrepresentable UCS-2 text: " .. tostring(err)
		)
	end
	return t.cases({
		{
			"test_blame_ucs2_capture_rejects_supplementary_characters",
			function()
				local buf = api.nvim_create_buf(false, true)
				t.cleanups[#t.cleanups + 1] = function()
					if api.nvim_buf_is_valid(buf) then
						api.nvim_buf_delete(buf, { force = true })
					end
				end
				vim.bo[buf].fileformat = "unix"
				for _, encoding in ipairs({
					"ucs-2",
					"ucs-2be",
					"ucs-2le",
					"UCS-2",
					"UCS-2BE",
					"UCS-2LE",
					"ucs2",
					"ucs2be",
					"ucs2le",
					"unicode",
				}) do
					for _, bom in ipairs({ false, true }) do
						vim.bo[buf].fileencoding, vim.bo[buf].bomb = encoding, bom
						local profile = assert(text.profile(buf))
						for _, line in ipairs({ "a😀z", "a𐀀z" }) do
							api.nvim_buf_set_lines(buf, 0, -1, false, { line })
							local doc = assert(text.capture(buf, 1024))
							local bytes, err = text.encode_file(doc, profile, 1024)
							rejected(bytes, err, encoding .. " encode")
							local capture
							capture, err = text.capture_file(buf, 1024)
							rejected(capture, err, encoding .. " capture")
						end
						api.nvim_buf_set_lines(buf, 0, -1, false, { "a￿z" })
						local little = profile.fileencoding == "ucs-2le"
						local expected = (bom and (little and "\255\254" or "\254\255") or "")
							.. (little and "a\0\255\255z\0\n\0" or "\0a\255\255\0z\0\n")
						assert(assert(text.capture_file(buf, 1024)).bytes == expected, encoding .. " changed BMP bytes")
						-- Direct callers may retain canonical names with upper-case letters.
						if encoding:lower():match("^ucs%-2") then
							profile.fileencoding = encoding
							local doc = assert(text.capture(buf, 1024))
							assert(text.encode_file(doc, profile, 1024) == expected, "direct BMP encoding changed")
							doc.lines = { "a😀z" }
							local bytes, err = text.encode_file(doc, profile, 1024)
							rejected(bytes, err, encoding .. " direct")
						end
					end
				end
				for _, encoding in ipairs({ "utf-16", "utf-16be", "utf-16le" }) do
					for _, bom in ipairs({ false, true }) do
						vim.bo[buf].fileencoding, vim.bo[buf].bomb = encoding, bom
						api.nvim_buf_set_lines(buf, 0, -1, false, { "a😀z" })
						local little = encoding == "utf-16le"
						local expected = (bom and (little and "\255\254" or "\254\255") or "")
							.. (little and "a\0\061\216\0\222z\0\n\0" or "\0a\216\061\222\0\0z\0\n")
						assert(
							assert(text.capture_file(buf, 1024)).bytes == expected,
							"UTF-16 lost supplementary support"
						)
					end
				end
			end,
		},
		{
			"test_blame_ucs2_rejection_prevents_backend_submission",
			function()
				local f, buf = t.open(false)
				t.h.write_file(f.root .. "/.gitattributes", "sample.txt working-tree-encoding=UTF-16\n")
				local file = assert(io.open(f.file, "wb"))
				file:write("\255\254" .. vim.iconv("a😀z\n", "utf-8", "utf-16le"))
				file:close()
				t.h.exec({ "git", "add", "sample.txt", ".gitattributes" }, f.root)
				t.h.exec({ "git", "commit", "-m", "UTF-16" }, f.root)
				vim.cmd("edit! ++enc=utf-16le")
				vim.bo[buf].fileencoding = "ucs-2le"
				local process, submitted = require("lazyvcs.backends.process"), 0
				local run = process.lines
				t.patch(process, "lines", function(args, opts, callback)
					if args[2] == "blame" then
						submitted = submitted + 1
					end
					return run(args, opts, callback)
				end)
				local blame = require("lazyvcs.blame")
				assert(blame.blame_split())
				t.wait(function()
					return #t.notices > 0 or blame._test_blame_views()[buf] and blame._test_blame_views()[buf].winid
				end, "split did not settle", 15000)
				assert(submitted == 0 and not blame._test_blame_views()[buf], "UCS-2 split submitted blame commands")
				assert(t.notices[#t.notices]:find("UCS-2 cannot represent", 1, true), "split capture error missing")
				assert(not require("lazyvcs.blame_selection").open(1, 1), "UCS-2 selection opened a report")
				assert(
					submitted == 0 and not require("lazyvcs.blame_selection")._test_requests()[buf],
					"UCS-2 selection submitted blame commands"
				)
				assert(t.notices[#t.notices]:find("UCS-2 cannot represent", 1, true), "selection capture error missing")
			end,
		},
	})
end
