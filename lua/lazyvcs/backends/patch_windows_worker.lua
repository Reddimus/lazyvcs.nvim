-- Executed only in a libuv worker. HANDLE bytes stay opaque outside this module;
-- no CRT descriptor table or libuv path-stat device number participates.
return function(operation, packed)
	local outer_ok, outer_result = pcall(function()
		local args = vim.mpack.decode(packed)
		local ffi = require("ffi")
		local bit = require("bit")
		if not pcall(ffi.typeof, "lazyvcs_patch_id") then
			ffi.cdef([[
    typedef struct { uint32_t low, high; } lazyvcs_patch_filetime;
    typedef struct {
      uint32_t attributes;
      lazyvcs_patch_filetime created, accessed, written;
      uint32_t volume, size_high, size_low, links, index_high, index_low;
    } lazyvcs_patch_info;
    typedef struct { uint64_t volume; uint8_t id[16]; } lazyvcs_patch_id;
    typedef struct { uint32_t attributes, tag; } lazyvcs_patch_tag;
    void * __stdcall CreateFileW(const uint16_t *, uint32_t, uint32_t, void *, uint32_t, uint32_t, void *);
    int __stdcall GetFileInformationByHandle(void *, lazyvcs_patch_info *);
    int __stdcall GetFileInformationByHandleEx(void *, int, void *, uint32_t);
    uint32_t __stdcall GetFileType(void *);
    int __stdcall SetFilePointerEx(void *, int64_t, int64_t *, uint32_t);
    int __stdcall ReadFile(void *, void *, uint32_t, uint32_t *, void *);
    int __stdcall MultiByteToWideChar(uint32_t, uint32_t, const char *, int, uint16_t *, int);
    uint32_t __stdcall GetLastError(void);
    int __stdcall CloseHandle(void *);
  ]])
		end
		local kernel = ffi.load("kernel32")
		local handle, retained
		local function failure(name)
			local code = tonumber(kernel.GetLastError())
			local names = { [2] = "ENOENT", [3] = "ENOENT", [5] = "EACCES", [6] = "EBADF", [32] = "EBUSY" }
			error((names[code] or "EIO") .. ": " .. name .. " (Windows error " .. code .. ")", 0)
		end
		local function hex(bytes)
			return (bytes:gsub(".", function(byte)
				return string.format("%02x", byte:byte())
			end))
		end
		local function info()
			local basic, id = ffi.new("lazyvcs_patch_info[1]"), ffi.new("lazyvcs_patch_id[1]")
			if kernel.GetFileType(handle) ~= 1 then
				error("Patch requires a disk file or directory", 0)
			end
			if kernel.GetFileInformationByHandle(handle, basic) == 0 then
				failure("GetFileInformationByHandle")
			end
			-- FileIdInfo (18) supplies the full volume/file identifier, including ReFS.
			if kernel.GetFileInformationByHandleEx(handle, 18, id, ffi.sizeof(id)) == 0 then
				failure("GetFileInformationByHandleEx(FileIdInfo)")
			end
			local attributes = math.floor(assert(tonumber(basic[0].attributes)))
			local reparse, tag = bit.band(attributes, 0x400) ~= 0, 0
			if reparse then
				local value = ffi.new("lazyvcs_patch_tag[1]")
				if kernel.GetFileInformationByHandleEx(handle, 9, value, ffi.sizeof(value)) == 0 then
					failure("GetFileInformationByHandleEx(FileAttributeTagInfo)")
				end
				tag = math.floor(assert(tonumber(value[0].tag)))
			end
			local kind = bit.band(attributes, 0x10) ~= 0 and "directory" or "file"
			if reparse then
				-- Only recognized file links may reach Git's allow-link route.
				kind = (tag == 0xa000000c or tag == 0xa0000003) and "link" or "unsupported-reparse"
			end
			return {
				identity = "windows-file-id-128",
				dev = hex(ffi.string(id, 8)),
				ino = hex(ffi.string(id[0].id, 16)),
				attributes = attributes,
				reparse_tag = tag,
				directory_reparse = reparse and bit.band(attributes, 0x10) ~= 0,
				type = kind,
			}
		end
		local function open(path, access)
			if type(path) ~= "string" or path:find("\0", 1, true) then
				error("Invalid Patch path", 0)
			end
			path = path:gsub("/", "\\")
			if path:sub(1, 4) ~= "\\\\?\\" then
				if path:sub(1, 2) == "\\\\" then
					path = "\\\\?\\UNC\\" .. path:sub(3)
				elseif path:match("^%a:\\") then
					path = "\\\\?\\" .. path
				else
					error("Patch requires an absolute Windows path", 0)
				end
			end
			local count = kernel.MultiByteToWideChar(65001, 8, path, #path, nil, 0)
			if count == 0 or count >= 32767 then
				error("Cannot encode Windows Patch path", 0)
			end
			local wide = ffi.new("uint16_t[?]", count + 1)
			if kernel.MultiByteToWideChar(65001, 8, path, #path, wide, count) ~= count then
				failure("MultiByteToWideChar")
			end
			-- OPEN_EXISTING, share read/write/delete, OPEN_REPARSE_POINT and BACKUP_SEMANTICS.
			-- A leaf link is inspected itself, never followed to obtain identity or bytes.
			handle = kernel.CreateFileW(wide, access, 7, nil, 3, 0x02200000, nil)
			if handle == ffi.cast("void *", -1) then
				handle = nil
				failure("CreateFileW")
			end
		end
		local ok, result = pcall(function()
			if operation == "lstat" then
				open(args.path, 0x80) -- FILE_READ_ATTRIBUTES, no content access.
				return info()
			elseif operation == "open" then
				open(args.path, 0x80000000) -- GENERIC_READ, no write/create access.
				local pointer = ffi.new("void *[1]", handle)
				retained = true
				return ffi.string(pointer, ffi.sizeof(pointer))
			end
			if type(args.token) ~= "string" or #args.token ~= ffi.sizeof("void *") then
				error("Invalid owned Patch HANDLE", 0)
			end
			local pointer = ffi.new("void *[1]")
			ffi.copy(pointer, args.token, #args.token)
			handle, retained = pointer[0], true
			if operation == "fstat" then
				return info()
			elseif operation == "read" then
				assert(args.size >= 0 and args.size <= 65536 and args.offset >= 0 and args.offset <= 32 * 1024 * 1024)
				if kernel.SetFilePointerEx(handle, args.offset, nil, 0) == 0 then
					failure("SetFilePointerEx")
				end
				local bytes, size = ffi.new("uint8_t[?]", math.max(1, args.size)), ffi.new("uint32_t[1]")
				if kernel.ReadFile(handle, bytes, args.size, size, nil) == 0 then
					failure("ReadFile")
				end
				return ffi.string(bytes, size[0])
			elseif operation == "close" then
				local closing = handle
				handle = nil
				if kernel.CloseHandle(closing) == 0 then
					failure("CloseHandle")
				end
				return true
			end
			error("Invalid Patch I/O operation", 0)
		end)
		if handle ~= nil and not retained then
			if kernel.CloseHandle(handle) == 0 and ok then
				ok, result = false, "Could not close Patch metadata HANDLE"
			end
		end
		return vim.mpack.encode({ ok = ok, value = result })
	end)
	return outer_ok and outer_result or vim.mpack.encode({ ok = false, value = tostring(outer_result) })
end
