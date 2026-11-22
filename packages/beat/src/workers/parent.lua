-- Whether the process that started a worker is still there.
--
-- A scan's processes are not tied to the window in any way the operating system keeps: the
-- coordinator is started by the app, the inspectors by the coordinator, and each of them writes to
-- a temporary file rather than to a pipe whose other end would hear the close. Closing the window,
-- or killing the app, would otherwise leave them walking the music folder with nobody to read
-- what they find. `beat.workers.process` puts the starter's id in `BEAT_PARENT_PID`, and every
-- worker asks here, once around each file it reads and each short wait between reads.
--
-- The check is the platform's own: on the unixes a child is re-parented the moment its parent
-- exits, so the id `getppid` reports changing is the answer; on Windows a handle to the parent,
-- opened for synchronisation, is signalled when that parent ends.
local ffi = require("ffi")

local parent = {}

local expected = tonumber(os.getenv("BEAT_PARENT_PID") or "")

---@type (fun(): boolean)?
local gone

if expected == nil then
	-- A module loaded on its own -- a test, a tool -- has no worker parent to watch.
elseif jit.os == "Windows" then
	-- `process.raw.windows` declares these in a process that has spawned something; a worker that
	-- only checks on its parent has not. The declarations are the same after typedefs, so the
	-- repeated ones are already in place rather than a second, different signature.
	pcall(ffi.cdef, [[void*    OpenProcess(uint32_t access, int inherit, uint32_t pid);]])
	pcall(ffi.cdef, [[uint32_t WaitForSingleObject(void* handle, uint32_t milliseconds);]])
	pcall(ffi.cdef, [[int      CloseHandle(void* handle);]])
	local kernel32 = ffi.load("kernel32")
	local SYNCHRONIZE = 0x00100000
	local WAIT_OBJECT_0 = 0

	gone = function()
		local handle = kernel32.OpenProcess(SYNCHRONIZE, 0, expected)
		-- A process that cannot be opened is one that has ended: nothing keeps a live process's
		-- handle away from a child it started itself.
		if handle == nil then return true end
		local state = kernel32.WaitForSingleObject(handle, 0)
		kernel32.CloseHandle(handle)
		return state == WAIT_OBJECT_0
	end
else
	pcall(ffi.cdef, [[int getppid(void);]])
	gone = function() return ffi.C.getppid() ~= expected end
end

--- Whether the process that started this one has gone. Always false where no parent id was given.
---@return boolean
function parent.gone()
	if gone == nil then return false end
	return gone()
end

return parent
