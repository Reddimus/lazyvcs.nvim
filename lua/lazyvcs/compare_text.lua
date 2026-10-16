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
---@field binary boolean
---@field empty boolean

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

local function valid_utf8(bytes)
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
	for _, signature in ipairs(signatures) do
		if bytes:sub(1, #signature[1]) == signature[1] then
			bytes, source, bom = bytes:sub(#signature[1] + 1), signature[2], true
			break
		end
	end
	local conversion_source, conversion_bytes = source:lower(), bytes
	if
		conversion_source == "utf-16"
		or conversion_source == "utf-16be"
		or conversion_source == "ucs-2"
		or conversion_source == "ucs-2be"
	then
		conversion_source, conversion_bytes = "utf-16le", bytes:gsub("(.)(.)", "%2%1")
	elseif conversion_source == "ucs-4" or conversion_source == "ucs-4be" then
		conversion_source, conversion_bytes = "ucs-4le", bytes:gsub("(.)(.)(.)(.)", "%4%3%2%1")
	end
	local utf8 = conversion_source == "utf-8" or conversion_source == "utf8"
	local ok = true
	---@type string?
	local decoded = conversion_bytes
	if not utf8 then
		ok, decoded = pcall(vim.iconv, conversion_bytes, conversion_source, "utf-8")
	end
	if not ok or type(decoded) ~= "string" or not valid_utf8(decoded) then
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
	return { lines = lines, eol = eol, empty = empty, encoding = source, bom = bom, profile_key = profile.key }
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
	local result = {
		lines = lines,
		eol = not empty and (vim.bo[bufnr].endofline or (vim.bo[bufnr].fixendofline and not profile.binary)),
		empty = empty,
		encoding = profile.fileencoding,
		bom = profile.bomb,
		profile_key = profile.key,
	}
	local bytes = M.serialize(result)
	if #bytes > limit_bytes or bytes:find("\0", 1, true) or not valid_utf8(bytes) then
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

return M
