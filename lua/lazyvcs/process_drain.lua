-- Standalone -ll helper started at editor exit with a preserved command's
-- output pipe as stdin. Holding the read end keeps the command's writes from
-- failing with EPIPE; the output is discarded until every writer closes it.
local uv = vim.uv
local pipe = assert(uv.new_pipe(false))
assert(pipe:open(0))
pipe:read_start(function(err, data)
	if err or not data then
		pipe:close()
	end
end)
uv.run()
