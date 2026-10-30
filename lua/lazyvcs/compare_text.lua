local M = {}

---@class LazyVcsDecodeProfile
---@field fileencoding string
---@field fileformat "unix"|"dos"|"mac"
---@field bomb boolean
---@field binary boolean
---@field key string

---@class LazyVcsText
---@field lines string[]
---@field eol boolean
---@field empty boolean
---@field encoding string
---@field bom boolean
---@field profile_key string

---@class LazyVcsTextIdentity
---@field changedtick integer
---@field profile_key string
---@field endofline boolean
---@field fixendofline boolean
---@field modified boolean
---@field binary boolean
---@field empty boolean

-- Neovim can write a final newline without updating 'endofline'. Keep clean
-- captures faithful to the bytes just written, including when signs are disabled.
function M.setup()
	local group = vim.api.nvim_create_augroup("lazyvcs_text", { clear = true })
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		callback = function(args)
			if not vim.api.nvim_buf_is_valid(args.buf) or vim.v.cmdarg:find("++bin", 1, true) then
				return
			end
			-- Only a write of the buffer's own file adds the newline 'fixendofline' promises.
			local name = vim.api.nvim_buf_get_name(args.buf)
			local function full(path)
				return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"), { expand_env = false })
			end
			if name == "" or full(args.match) ~= full(name) then
				return
			end
			local bo = vim.bo[args.buf]
			if bo.fixendofline and not bo.binary and not bo.endofline then
				bo.endofline = true
			end
		end,
	})
end

local function valid_buffer(bufnr)
	return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

---@param bufnr integer
---@return LazyVcsDecodeProfile? profile, string? err
function M.profile(bufnr)
	if not valid_buffer(bufnr) then
		return nil, "Text buffer is no longer loaded"
	end
	local bo = vim.bo[bufnr]
	local encoding = bo.fileencoding ~= "" and bo.fileencoding or vim.o.encoding
	return {
		fileencoding = encoding,
		fileformat = bo.fileformat,
		bomb = bo.bomb,
		binary = bo.binary,
		key = table.concat({ encoding, bo.fileformat, tostring(bo.bomb), tostring(bo.binary) }, ":"),
	}
end

---@param bytes string
---@return boolean
function M.valid_utf8(bytes)
	local i = 1
	while i <= #bytes do
		local c = bytes:byte(i)
		local n, lower, upper = 0, 128, 191
		if c < 128 then
			n = 0
		elseif c >= 194 and c <= 223 then
			n = 1
		elseif c >= 224 and c <= 239 then
			n = 2
			if c == 224 then
				lower = 160
			end
			if c == 237 then
				upper = 159
			end
		elseif c >= 240 and c <= 244 then
			n = 3
			if c == 240 then
				lower = 144
			end
			if c == 244 then
				upper = 143
			end
		else
			return false
		end
		for offset = 1, n do
			local next_byte = bytes:byte(i + offset)
			if
				not next_byte
				or next_byte < (offset == 1 and lower or 128)
				or next_byte > (offset == 1 and upper or 191)
			then
				return false
			end
		end
		i = i + n + 1
	end
	return true
end

local signatures = {
	{ "\255\254\0\0", "ucs-4le" },
	{ "\0\0\254\255", "ucs-4be" },
	{ "\239\187\191", "utf-8" },
	{ "\255\254", "utf-16le" },
	{ "\254\255", "utf-16be" },
}

local function codec(encoding)
	encoding = encoding:lower()
	if encoding == "utf8" then
		return "utf-8"
	elseif encoding == "utf-16" or encoding == "utf-16be" or encoding == "ucs-2" or encoding == "ucs-2be" then
		return "utf-16le", 2, encoding == "ucs-2" or encoding == "ucs-2be"
	elseif encoding == "ucs-4" or encoding == "ucs-4be" then
		return "ucs-4le", 4
	elseif encoding == "ucs-2le" then
		return "utf-16le", nil, true
	end
	return encoding
end

local function swap(bytes, width)
	if width == 2 then
		return (bytes:gsub("(.)(.)", "%2%1"))
	elseif width == 4 then
		return (bytes:gsub("(.)(.)(.)(.)", "%4%3%2%1"))
	end
	return bytes
end

---@param bytes string
---@param profile LazyVcsDecodeProfile
---@param limit_bytes integer
---@return LazyVcsText? text, string? err
function M.decode(bytes, profile, limit_bytes)
	if #bytes > limit_bytes then
		return nil, "Raw text exceeds the editable content limit"
	end
	if profile.binary then
		return nil, "Binary buffers do not support editable hunks"
	end
	local source, bom = profile.fileencoding, false
	local effective_codec, effective_width = codec(source)
	for _, signature in ipairs(signatures) do
		local signature_codec, signature_width = codec(signature[2])
		if
			effective_codec == signature_codec
			and effective_width == signature_width
			and bytes:sub(1, #signature[1]) == signature[1]
		then
			bytes, source, bom = bytes:sub(#signature[1] + 1), signature[2], true
			break
		end
	end
	local conversion_source, width = codec(source)
	local conversion_bytes = swap(bytes, width)
	if conversion_source == "ucs-4le" then
		if #conversion_bytes % 4 ~= 0 then
			return nil, "Invalid UCS-4 base"
		end
		for i = 1, #conversion_bytes, 4 do
			local a, b, c, d = conversion_bytes:byte(i, i + 3)
			local value = a + b * 256 + c * 65536 + d * 16777216
			if value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF) then
				return nil, "Invalid UCS-4 base"
			end
		end
	end
	local utf8 = conversion_source == "utf-8" or conversion_source == "utf8"
	local ok = true
	---@type string?
	local decoded = conversion_bytes
	if not utf8 then
		ok, decoded = pcall(vim.iconv, conversion_bytes, conversion_source, "utf-8")
	end
	if not ok or type(decoded) ~= "string" or not M.valid_utf8(decoded) then
		return nil, "Unable to decode the VCS base as valid UTF-8"
	end
	local roundtrip_ok = true
	---@type string?
	local roundtrip = decoded
	if not utf8 then
		roundtrip_ok, roundtrip = pcall(vim.iconv, decoded, "utf-8", conversion_source)
	end
	if not roundtrip_ok or roundtrip ~= conversion_bytes then
		return nil, "VCS base encoding cannot be converted without loss"
	end
	if #decoded > limit_bytes then
		return nil, "Decoded text exceeds the editable content limit"
	end
	if decoded:find("\0", 1, true) then
		return nil, "Binary VCS bases do not support editable hunks"
	end
	local separator = profile.fileformat == "mac" and "\r" or "\n"
	if profile.fileformat == "dos" then
		decoded = decoded:gsub("\r\n", "\n")
	end
	local empty, eol = decoded == "", decoded:sub(-1) == separator
	local lines = empty and {} or vim.split(decoded, separator, { plain = true })
	if eol then
		table.remove(lines)
	end
	if profile.fileformat == "mac" then
		for i, line in ipairs(lines) do
			lines[i] = line:gsub("\n", "\r")
		end
	end
	return { lines = lines, eol = eol, empty = empty, encoding = source, bom = bom, profile_key = profile.key }
end

---@param bytes string
---@param opts table
---@param limit_bytes integer
---@return LazyVcsText? document, string? err
function M.decode_preview(bytes, opts, limit_bytes)
	if #bytes > limit_bytes then
		return nil, "File exceeds the 1 MiB preview limit"
	end
	local encodings = {}
	if opts.encoding then
		local encoding = opts.encoding:lower():gsub("^(utf%-16[lb]e)%-bom$", "%1")
		if encoding == "utf-16" and bytes:sub(1, 2) == "\255\254" then
			encoding = "utf-16le"
		end
		encodings = { encoding }
	else
		if opts.hint then
			encodings[#encodings + 1] = opts.hint.fileencoding
		end
		for encoding in (opts.fileencodings or "ucs-bom,utf-8,default,latin1"):gmatch("[^,]+") do
			if encoding == "ucs-bom" then
				for _, signature in ipairs(signatures) do
					if bytes:sub(1, #signature[1]) == signature[1] then
						encodings[#encodings + 1] = signature[2]
						break
					end
				end
			else
				encodings[#encodings + 1] = encoding == "default" and "utf-8" or encoding
			end
		end
		if opts.fileencodings == "" then
			encodings[#encodings + 1] = "utf-8"
		end
	end
	local failure = "Source encoding could not be determined"
	for index, encoding in ipairs(encodings) do
		local profile = {
			fileencoding = encoding,
			-- Preview always normalizes CRLF, independent of editor read/write options.
			fileformat = "dos",
			bomb = false,
			binary = false,
			key = encoding .. ":preview-lf",
		}
		local document, err = M.decode(bytes, profile, limit_bytes)
		if document then
			document.profile_key = profile.key .. ":" .. tostring(document.bom)
			return document
		end
		failure = err or failure
		local failed_hint = not opts.encoding and opts.hint and index == 1
		if not failed_hint and (failure:find("Binary", 1, true) or failure:find("Decoded text exceeds", 1, true)) then
			break
		end
	end
	if failure:find("Binary", 1, true) then
		return nil, "Binary file; text preview unavailable"
	elseif failure:find("exceeds", 1, true) then
		return nil, "Decoded text exceeds the 1 MiB preview limit"
	end
	failure = failure
		:gsub("the VCS base", "preview text")
		:gsub("VCS base encoding", "Preview encoding")
		:gsub("Invalid UCS%-4 base", "Invalid UCS-4 preview text")
	return nil, failure
end

local function is_empty(bufnr, lines)
	return #lines == 1
		and lines[1] == ""
		and vim.api.nvim_buf_call(bufnr, function()
			return vim.fn.wordcount().chars == 0
		end)
end

---@param bufnr integer
---@param limit_bytes integer
---@return LazyVcsText? text, string? err
function M.capture(bufnr, limit_bytes)
	local profile, err = M.profile(bufnr)
	if not profile then
		return nil, err
	end
	if profile.binary then
		return nil, "Binary buffers do not support editable hunks"
	end
	if vim.api.nvim_buf_get_offset(bufnr, vim.api.nvim_buf_line_count(bufnr)) > limit_bytes + 1 then
		return nil, "Buffer exceeds the editable content limit"
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for _, line in ipairs(lines) do
		if line:find("\n", 1, true) then
			return nil, "Buffer contains binary text"
		end
	end
	local empty = is_empty(bufnr, lines)
	if empty then
		lines = {}
	end
	local bo = vim.bo[bufnr]
	local write_eol = bo.modified and bo.fixendofline and not profile.binary
	local result = {
		lines = lines,
		eol = not empty and (bo.endofline or write_eol),
		empty = empty,
		encoding = profile.fileencoding,
		bom = profile.bomb,
		profile_key = profile.key,
	}
	local bytes = M.serialize(result)
	if #bytes > limit_bytes or bytes:find("\0", 1, true) or not M.valid_utf8(bytes) then
		return nil, "Buffer is oversized or contains unsupported text"
	end
	return result
end

---@param bufnr integer
---@return LazyVcsTextIdentity? identity, string? err
function M.identity(bufnr)
	local profile, err = M.profile(bufnr)
	if not profile then
		return nil, err
	end
	local candidate = vim.api.nvim_buf_line_count(bufnr) == 1
			and vim.api.nvim_buf_get_offset(bufnr, 1) <= 1
			and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)
		or {}
	return {
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
		profile_key = profile.key,
		endofline = vim.bo[bufnr].endofline,
		fixendofline = vim.bo[bufnr].fixendofline,
		modified = vim.bo[bufnr].modified,
		binary = profile.binary,
		empty = is_empty(bufnr, candidate),
	}
end

---@param text LazyVcsText
---@return string
function M.serialize(text)
	if text.empty then
		return ""
	end
	return table.concat(text.lines, "\n") .. (text.eol and "\n" or "")
end

---@class LazyVcsBufferCapture
---@field text LazyVcsText
---@field profile LazyVcsDecodeProfile
---@field identity LazyVcsTextIdentity
---@field bytes string

---@param text LazyVcsText
---@param profile LazyVcsDecodeProfile
---@param limit_bytes integer
---@return string? bytes, string? err
function M.encode_file(text, profile, limit_bytes)
	if profile.binary then
		return nil, "Binary buffers do not support file-byte capture"
	end
	local separator = profile.fileformat == "dos" and "\r\n" or profile.fileformat == "mac" and "\r" or "\n"
	local lines = text.lines
	if profile.fileformat == "mac" then
		lines = {}
		for i, line in ipairs(text.lines) do
			lines[i] = line:gsub("\r", "\n")
		end
	end
	local decoded = text.empty and "" or table.concat(lines, separator) .. (text.eol and separator or "")
	if not M.valid_utf8(decoded) or decoded:find("\0", 1, true) then
		return nil, "Buffer contains unsupported text"
	end
	local encoding, width, ucs2 = codec(profile.fileencoding)
	if ucs2 and decoded:find("[\240-\244]") then
		return nil, "UCS-2 cannot represent characters above U+FFFF"
	end
	local bytes = decoded
	if encoding ~= "utf-8" then
		local input = decoded == "" and "a" or decoded
		local ok, converted = pcall(vim.iconv, input, "utf-8", encoding)
		local reverse_ok, reversed = false, nil
		if ok and type(converted) == "string" then
			reverse_ok, reversed = pcall(vim.iconv, converted, encoding, "utf-8")
		end
		if not reverse_ok or reversed ~= input then
			return nil, "Buffer encoding cannot be converted without loss"
		end
		bytes = decoded == "" and "" or swap(converted, width)
	end
	if profile.bomb then
		local signature
		for _, candidate in ipairs(signatures) do
			local candidate_codec, candidate_width = codec(candidate[2])
			if candidate_codec == encoding and candidate_width == width then
				signature = candidate[1]
				break
			end
		end
		-- Like Neovim's writer, ignore 'bomb' for encodings without a BOM.
		bytes = (signature or "") .. bytes
	end
	if #bytes > limit_bytes then
		return nil, "Encoded text exceeds the file size limit"
	end
	return bytes
end

---@param bufnr integer
---@param limit_bytes integer
---@return LazyVcsBufferCapture? capture, string? err
function M.capture_file(bufnr, limit_bytes)
	local identity, err = M.identity(bufnr)
	if not identity then
		return nil, err
	end
	local profile, profile_err = M.profile(bufnr)
	if not profile then
		return nil, profile_err
	end
	local text, capture_err = M.capture(bufnr, limit_bytes)
	if not text then
		return nil, capture_err
	end
	local bytes, encode_err = M.encode_file(text, profile, limit_bytes)
	if not bytes then
		return nil, encode_err
	end
	if not vim.deep_equal(identity, M.identity(bufnr)) then
		return nil, "Buffer changed while capturing file bytes"
	end
	return { text = text, profile = profile, identity = identity, bytes = bytes }
end

return M
