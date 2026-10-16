local M = {}

function M.compile(pattern)
	local tokens, cursor, closes, escaped = {}, 1, {}, false
	for index = 1, #pattern do
		local char = pattern:sub(index, index)
		if escaped then
			escaped = false
		elseif char == "\\" then
			escaped = true
		elseif char == "]" then
			closes[index] = index
		end
	end
	local next_close
	for index = #pattern, 1, -1 do
		next_close = closes[index] or next_close
		closes[index] = next_close
	end
	while cursor <= #pattern do
		local char = pattern:sub(cursor, cursor)
		local token = { literal = char }
		cursor = cursor + 1
		if char == "*" or char == "?" then
			token = { kind = char }
		elseif char == "\\" and cursor <= #pattern then
			token.literal = pattern:sub(cursor, cursor)
			cursor = cursor + 1
		elseif char == "[" then
			local start, ranges = cursor, {}
			local negate = pattern:sub(cursor, cursor) == "!" or pattern:sub(cursor, cursor) == "^"
			if negate then
				cursor = cursor + 1
			end
			local function byte()
				if pattern:sub(cursor, cursor) == "\\" and cursor < #pattern then
					cursor = cursor + 1
				end
				local value = pattern:byte(cursor)
				cursor = cursor + 1
				return value
			end
			local closing = closes[cursor + 1]
			while closing and cursor < closing do
				local first = byte()
				local last = first
				if
					pattern:sub(cursor, cursor) == "-"
					and cursor < #pattern
					and pattern:sub(cursor + 1, cursor + 1) ~= "]"
				then
					cursor = cursor + 1
					last = byte()
				end
				ranges[#ranges + 1] = { first, last }
			end
			if closing and cursor == closing and #ranges > 0 then
				token = { kind = "class", ranges = ranges, negate = negate }
				cursor = cursor + 1
			else
				cursor = start
			end
		end
		tokens[#tokens + 1] = token
	end
	return tokens
end

function M.matches(tokens, name)
	local previous = { [0] = true }
	for _, token in ipairs(tokens) do
		local row = {}
		if token.kind == "*" then
			row[0] = previous[0]
		end
		for index = 1, #name do
			if token.kind == "*" then
				row[index] = previous[index] or row[index - 1]
			elseif previous[index - 1] then
				local matches = token.kind == "?" or token.literal == name:sub(index, index)
				if token.kind == "class" then
					matches = false
					local value = name:byte(index)
					for _, range in ipairs(token.ranges) do
						if value >= range[1] and value <= range[2] then
							matches = true
							break
						end
					end
					if token.negate then
						matches = not matches
					end
				end
				row[index] = matches
			end
		end
		previous = row
	end
	return previous[#name] == true
end

return M
