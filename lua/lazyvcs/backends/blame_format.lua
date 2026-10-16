local M = {}

function M.full_file(opts)
	local profile = opts.profile
	if not profile or not opts.text then
		return false
	end
	local encoding = profile.fileencoding:lower()
	return profile.fileformat == "mac"
		or not vim.tbl_contains({ "utf-8", "utf8", "latin1", "iso-8859-1", "ascii" }, encoding)
end

function M.select(lines, opts)
	if not M.full_file(opts) then
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
	if #records ~= #opts.text.lines then
		return nil, "Unsupported blame line format: Git and the editor use different lines"
	end
	local selected = {}
	for number, item in ipairs(records) do
		if item.number ~= number then
			return nil, "Unsupported blame line format: Git and the editor use different lines"
		end
		if not opts.line_start or (number >= opts.line_start and number <= opts.line_end) then
			vim.list_extend(selected, item.lines)
		end
	end
	return selected
end

return M
