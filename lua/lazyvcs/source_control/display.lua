local M = {}

---Escape display text without changing raw action paths.
function M.label(raw)
	return (
		tostring(raw or ""):gsub("[%z\1-\31\127]", function(char)
			local escapes = { ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
			return escapes[char] or string.format("\\x%02x", char:byte())
		end)
	)
end

return M
