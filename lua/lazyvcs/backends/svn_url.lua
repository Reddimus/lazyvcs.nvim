local M = {}

function M.encode_segment(name)
	return (name:gsub("[^A-Za-z0-9%-%._~]", function(char)
		return string.format("%%%02X", char:byte())
	end))
end

function M.append_path(root_url, relpath)
	relpath = require("lazyvcs.backends.xml").local_path(relpath)
	if relpath == "." or relpath == "" then
		return root_url
	end
	-- Match SVN's URI spelling so XML targets can be checked exactly. SVN keeps
	-- these safe punctuation bytes literal, but escapes ';', '%', '#', and '?'.
	local encoded = relpath:gsub("[^A-Za-z0-9%-%._~/!$&'()*+,=:@]", function(char)
		return string.format("%%%02X", char:byte())
	end)
	return root_url:gsub("/$", "") .. "/" .. encoded
end

return M
