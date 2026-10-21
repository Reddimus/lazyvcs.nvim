-- Used only by the isolated Windows launcher before it starts the command.
-- Unlike libuv's job, this ancestor job forbids silent descendant breakaway.
local ffi = require("ffi")
ffi.cdef([[
  typedef struct {
    int64_t PerProcessUserTimeLimit;
    int64_t PerJobUserTimeLimit;
    uint32_t LimitFlags;
    size_t MinimumWorkingSetSize;
    size_t MaximumWorkingSetSize;
    uint32_t ActiveProcessLimit;
    uintptr_t Affinity;
    uint32_t PriorityClass;
    uint32_t SchedulingClass;
  } lazyvcs_job_basic_limits;
  typedef struct {
    uint64_t ReadOperationCount;
    uint64_t WriteOperationCount;
    uint64_t OtherOperationCount;
    uint64_t ReadTransferCount;
    uint64_t WriteTransferCount;
    uint64_t OtherTransferCount;
  } lazyvcs_job_io_counters;
  typedef struct {
    lazyvcs_job_basic_limits BasicLimitInformation;
    lazyvcs_job_io_counters IoInfo;
    size_t ProcessMemoryLimit;
    size_t JobMemoryLimit;
    size_t PeakProcessMemoryUsed;
    size_t PeakJobMemoryUsed;
  } lazyvcs_job_extended_limits;
  void * __stdcall CreateJobObjectW(void *, const uint16_t *);
  int __stdcall SetInformationJobObject(void *, int, void *, uint32_t);
  int __stdcall AssignProcessToJobObject(void *, void *);
  void * __stdcall GetCurrentProcess(void);
  uint32_t __stdcall GetLastError(void);
  int __stdcall CloseHandle(void *);
]])
local kernel = ffi.load("kernel32")
local job = kernel.CreateJobObjectW(nil, nil)
local function fail(operation)
	local code = tonumber(kernel.GetLastError())
	if job ~= nil then
		kernel.CloseHandle(job)
	end
	error(operation .. " failed (Windows error " .. code .. ")")
end
if job == nil then
	fail("CreateJobObjectW")
end
local limits = ffi.new("lazyvcs_job_extended_limits[1]")
limits[0].BasicLimitInformation.LimitFlags = 0x2000 -- JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
if kernel.SetInformationJobObject(job, 9, limits, ffi.sizeof(limits)) == 0 then
	fail("SetInformationJobObject")
end
if kernel.AssignProcessToJobObject(job, kernel.GetCurrentProcess()) == 0 then
	fail("AssignProcessToJobObject")
end
-- Self-assignment makes closing this handle fatal to the helper too. Do not
-- close it or install a GC finalizer; process exit closes the noninherited handle.
return function()
	-- Normal command completion releases intentional background descendants.
	-- Keep the handle open: closing a self-owned kill-on-close job is fatal.
	limits[0].BasicLimitInformation.LimitFlags = 0
	if kernel.SetInformationJobObject(job, 9, limits, ffi.sizeof(limits)) == 0 then
		error("Could not release completed command job (Windows error " .. tonumber(kernel.GetLastError()) .. ")")
	end
end
