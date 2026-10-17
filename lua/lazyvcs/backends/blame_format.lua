local M = {}

function M.decode_limit()
	return math.max(1024 * 1024, require("lazyvcs.config").get().signs.max_file_bytes)
end

function M.full_file(opts)
	local profile = opts.profile
	if not profile or not opts.text then
		return false
	end
	local encoding = profile.fileencoding:lower()
	return profile.fileformat == "mac" or encoding:match("^utf%-16") ~= nil or encoding:match("^ucs%-[24]") ~= nil
end

function M.git_policy(opts, attributes)
	local filter = attributes.filter
	local encoding = attributes["working-tree-encoding"]
	return {
		validate = filter ~= nil and filter ~= "unspecified" and filter ~= "unset",
		ident = attributes.ident == "set",
		profile = {
			fileencoding = encoding and encoding ~= "unspecified" and encoding ~= "unset" and "utf-8"
				or opts.profile and opts.profile.fileencoding
				or "utf-8",
			fileformat = "dos",
		},
	}
end

function M.normalize(line, policy)
	if policy and policy.ident then
		line = line:gsub("%$Id:[^$\r\n]*%$", "$Id$")
	end
	return (line:gsub("[ \t]+$", ""))
end

---@return string[]? selected, string? err, string[]? validated_source_lines
function M.select(lines, opts, policy)
	if not M.full_file(opts) and not (policy and policy.validate) then
		return lines
	end
	local records, record = {}, nil
	for _, line in ipairs(lines) do
		local oid, number = line:match("^(%x+)%s+%d+%s+(%d+)")
		if oid and (#oid == 40 or #oid == 64) then
			record = { number = tonumber(number), lines = {} }
			records[#records + 1] = record
		end
		if record then
			record.lines[#record.lines + 1] = line
		end
	end
	if not opts.text or #records ~= #opts.text.lines then
		return nil, "Unsupported blame line format: Git and the editor use different lines"
	end
	local validated_source_lines
	if policy and policy.validate then
		local source = {}
		for _, item in ipairs(records) do
			for _, line in ipairs(item.lines) do
				if line:sub(1, 1) == "\t" then
					source[#source + 1] = line:sub(2)
				end
			end
		end
		local decoded, decode_err = require("lazyvcs.compare_text").decode(
			table.concat(source, "\n") .. (#source > 0 and "\n" or ""),
			policy.profile,
			M.decode_limit()
		)
		if not decoded then
			return nil, decode_err
		end
		if #decoded.lines ~= #records then
			return nil, "Unsupported blame line format: Git and the editor use different lines"
		end
		validated_source_lines = decoded.lines
		for number, line in ipairs(decoded.lines) do
			if M.normalize(line, policy) ~= M.normalize(opts.text.lines[number], policy) then
				return nil, "Unsupported blame line format: Git and the editor use different lines"
			end
		end
	end
	local selected = {}
	for number, item in ipairs(records) do
		if item.number ~= number then
			return nil, "Unsupported blame line format: Git and the editor use different lines"
		end
		if not (opts.line_start and opts.line_end) or (number >= opts.line_start and number <= opts.line_end) then
			vim.list_extend(selected, item.lines)
		end
	end
	return selected, nil, validated_source_lines
end

function M.svn_base(bytes, profile, records, limit)
	local decoded, err = require("lazyvcs.compare_text").decode(bytes, profile, limit)
	if not decoded then
		return nil, err
	end
	local effective = { fileencoding = decoded.encoding, fileformat = profile.fileformat }
	if M.full_file({ profile = effective, text = decoded }) or #decoded.lines ~= #records then
		return nil, "Unsupported blame line format: SVN and the editor use different lines"
	end
	return decoded
end

return M
