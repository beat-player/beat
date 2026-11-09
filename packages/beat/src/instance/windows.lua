-- One beat per config directory on Windows: a named mutex says a copy is running, and a named
-- event is how a second launch asks it to come forward. Both are kernel objects of the login
-- session ("Local\"), so they go when the process that made them goes -- a copy that crashed holds
-- nothing -- and another user's beat on the same machine is a different one.
local ffi = require("ffi")

ffi.cdef [[
	void *beat_instance_CreateMutexA(void *attributes, int initialOwner, const char *name)
		__asm__("CreateMutexA");
	void *beat_instance_CreateEventA(void *attributes, int manualReset, int initialState, const char *name)
		__asm__("CreateEventA");
	void *beat_instance_OpenEventA(unsigned long access, int inherit, const char *name) __asm__("OpenEventA");
	int beat_instance_SetEvent(void *event) __asm__("SetEvent");
	unsigned long beat_instance_WaitForSingleObject(void *handle, unsigned long milliseconds)
		__asm__("WaitForSingleObject");
	int beat_instance_CloseHandle(void *handle) __asm__("CloseHandle");
	unsigned long beat_instance_GetLastError(void) __asm__("GetLastError");
	void beat_instance_Sleep(unsigned long milliseconds) __asm__("Sleep");
	int beat_instance_AllowSetForegroundWindow(unsigned long processId) __asm__("AllowSetForegroundWindow");
]]

-- Held for the life of the module: a library handle the collector lets go of unloads the dll, and
-- the functions above would point into nothing.
local kernel32 = ffi.load("kernel32")
local user32 = ffi.load("user32")

local ERROR_ALREADY_EXISTS = 183
local EVENT_MODIFY_STATE = 0x0002
local WAIT_OBJECT_0 = 0
local ASFW_ANY = 0xFFFFFFFF

---@param key string
local function names(key)
	return "Local\\beat-" .. key, "Local\\beat-" .. key .. "-show"
end

---@class beat.instance.WindowsClaim: beat.Instance
---@field mutex ffi.cdata*
---@field event ffi.cdata*
local Claim = {}
Claim.__index = Claim

--- Whether a launch asked for the window since the last time this was asked. The event resets
--- itself as it is seen, so one launch is one answer.
---@return boolean
function Claim:poll()
	return kernel32.beat_instance_WaitForSingleObject(self.event, 0) == WAIT_OBJECT_0
end

function Claim:release()
	kernel32.beat_instance_CloseHandle(self.mutex)
	kernel32.beat_instance_CloseHandle(self.event)
end

local windows = {}

windows.RUNNING = "running"

---@param key string
---@return beat.Instance? claim
---@return string? err # `windows.RUNNING` when another copy holds it
function windows.claim(key)
	local lockName, showName = names(key)

	-- The event is made before the mutex: a launch that finds the mutex always finds the event it
	-- signals, even when the copy that holds them started a moment before it.
	local event = kernel32.beat_instance_CreateEventA(nil, 0, 0, showName)
	if event == nil then
		return nil, "could not make the show event (error " .. tonumber(kernel32.beat_instance_GetLastError()) .. ")"
	end

	local mutex = kernel32.beat_instance_CreateMutexA(nil, 0, lockName)
	local made = tonumber(kernel32.beat_instance_GetLastError())
	if mutex == nil then
		kernel32.beat_instance_CloseHandle(event)
		return nil, "could not make the instance mutex (error " .. made .. ")"
	end

	if made == ERROR_ALREADY_EXISTS then
		kernel32.beat_instance_CloseHandle(mutex)
		kernel32.beat_instance_CloseHandle(event)
		return nil, windows.RUNNING
	end

	return setmetatable({ mutex = mutex, event = event }, Claim)
end

--- Asks the running copy to come forward. False when there is no event to signal: the copy that
--- held the mutex is on its way out.
---@param key string
---@return boolean
function windows.signal(key)
	local _, showName = names(key)
	local event = kernel32.beat_instance_OpenEventA(EVENT_MODIFY_STATE, 0, showName)
	if event == nil then return false end

	-- Windows only lets the program the user is using put a window in front. That is this launch,
	-- not the copy it hands over to, so it passes the right on before it asks.
	user32.beat_instance_AllowSetForegroundWindow(ASFW_ANY)

	local set = kernel32.beat_instance_SetEvent(event) ~= 0
	kernel32.beat_instance_CloseHandle(event)
	return set
end

---@param seconds number
function windows.sleep(seconds)
	kernel32.beat_instance_Sleep(math.floor(seconds * 1000))
end

return windows
