-- Standalone helper started at editor exit with a preserved command's output
-- pipe as stdin. Holding the read end keeps the command's writes from failing
-- with EPIPE; the output is discarded until every writer closes it.
local uv = vim.uv
local pipe = assert(uv.new_pipe(false))
assert(pipe:open(0))
local done = false
pipe:read_start(function(err, data)
	if err or not data then
		pipe:close()
		done = true
	end
end)
if vim.wait then
	-- Under -l (Neovim 0.13 has no -ll), uv.run() would also wait on the editor's own handles.
	while not done do
		vim.wait(0x7fffffff, function()
			return done
		end)
	end
else
	uv.run()
end
