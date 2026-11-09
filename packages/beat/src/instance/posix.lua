-- One beat per config directory on Linux and macOS: an flock on a file says a copy is running,
-- and a datagram on a unix socket next to it is how a second launch asks it to come forward. The
-- kernel drops the lock when the process that took it goes, so a copy that crashed holds nothing;
-- the socket file it leaves behind is removed by whoever takes the lock next.
local ffi = require("ffi")

local isMac = ffi.os == "OSX"

ffi.cdef [[
	int beat_instance_open(const char *path, int flags, ...) __asm__("open");
	int beat_instance_close(int fd) __asm__("close");
	int beat_instance_flock(int fd, int operation) __asm__("flock");
	int beat_instance_fcntl(int fd, int command, ...) __asm__("fcntl");
	int beat_instance_socket(int domain, int type, int protocol) __asm__("socket");
	int beat_instance_bind(int fd, const void *address, unsigned int length) __asm__("bind");
	long beat_instance_recv(int fd, void *buffer, size_t length, int flags) __asm__("recv");
	long beat_instance_sendto(int fd, const void *buffer, size_t length, int flags, const void *address,
		unsigned int addressLength) __asm__("sendto");
	int beat_instance_unlink(const char *path) __asm__("unlink");
	int beat_instance_usleep(unsigned int microseconds) __asm__("usleep");
	char *beat_instance_strerror(int code) __asm__("strerror");

	typedef struct { uint16_t family; char path[108]; } beat_instance_linux_address;
	typedef struct { uint8_t length; uint8_t family; char path[104]; } beat_instance_mac_address;
]]

-- The numbers that differ between the two: macOS keeps BSD's.
local O_RDWR = 0x2
local O_CREAT = isMac and 0x200 or 0x40
local MSG_DONTWAIT = isMac and 0x80 or 0x40
local EWOULDBLOCK = isMac and 35 or 11
local F_SETFD = 2
local FD_CLOEXEC = 1
local LOCK_EX = 2
local LOCK_NB = 4
local AF_UNIX = 1
local SOCK_DGRAM = 2

local ADDRESS = isMac and "beat_instance_mac_address" or "beat_instance_linux_address"

---@param code number?
local function describe(code)
	code = code or ffi.errno()
	return ffi.string(ffi.C.beat_instance_strerror(code))
end

--- Where the lock and the socket live: the session's runtime directory where there is one, which
--- is private to the user and emptied at logout, else the temporary directory.
---@param key string
---@return string lock
---@return string socket
local function places(key)
	local directory = os.getenv("XDG_RUNTIME_DIR") or os.getenv("TMPDIR") or "/tmp"
	directory = directory:gsub("/+$", "")
	return directory .. "/beat-" .. key .. ".lock", directory .. "/beat-" .. key .. ".sock"
end

---@param socketPath string
---@return ffi.cdata*? address
---@return number length
local function address(socketPath)
	local made = ffi.new(ADDRESS) --[[@as { length: number, family: number, path: ffi.cdata* }]]
	if #socketPath >= ffi.sizeof(made.path) then return nil, 0 end
	made.family = AF_UNIX
	if isMac then made.length = ffi.sizeof(made) end
	ffi.copy(made.path, socketPath)
	return made, ffi.sizeof(made)
end

--- Scan workers are this program started again, and a descriptor they inherit keeps the lock
--- taken after the copy that took it has quit.
---@param fd number
local function closeOnExec(fd)
	ffi.C.beat_instance_fcntl(fd, F_SETFD, ffi.new("int", FD_CLOEXEC))
end

---@class beat.instance.PosixClaim: beat.Instance
---@field lock number
---@field socket number
---@field socketPath string
---@field buffer ffi.cdata*
local Claim = {}
Claim.__index = Claim

--- Whether a launch asked for the window since the last time this was asked. Every datagram
--- waiting is taken, so launches made in a burst are one answer.
---@return boolean
function Claim:poll()
	local asked = false
	while ffi.C.beat_instance_recv(self.socket, self.buffer, 16, MSG_DONTWAIT) >= 0 do
		asked = true
	end
	return asked
end

function Claim:release()
	ffi.C.beat_instance_close(self.socket)
	ffi.C.beat_instance_unlink(self.socketPath)
	-- The lock file stays: removing it while another launch has it open would let two copies each
	-- lock a file of the same name.
	ffi.C.beat_instance_close(self.lock)
end

local posix = {}

posix.RUNNING = "running"

---@param key string
---@return beat.Instance? claim
---@return string? err # `posix.RUNNING` when another copy holds it
function posix.claim(key)
	local lockPath, socketPath = places(key)
	local socketAddress, socketLength = address(socketPath)
	if socketAddress == nil then return nil, "the socket path is too long: " .. socketPath end

	local lock = ffi.C.beat_instance_open(lockPath, O_RDWR + O_CREAT, ffi.new("int", tonumber("600", 8)))
	if lock < 0 then return nil, "could not open " .. lockPath .. ": " .. describe() end
	closeOnExec(lock)

	if ffi.C.beat_instance_flock(lock, LOCK_EX + LOCK_NB) ~= 0 then
		local code = ffi.errno()
		ffi.C.beat_instance_close(lock)
		if code == EWOULDBLOCK then return nil, posix.RUNNING end
		return nil, "could not lock " .. lockPath .. ": " .. describe(code)
	end

	-- Holding the lock is what makes the socket file this copy's to replace.
	ffi.C.beat_instance_unlink(socketPath)
	local socket = ffi.C.beat_instance_socket(AF_UNIX, SOCK_DGRAM, 0)
	if socket < 0 then
		ffi.C.beat_instance_close(lock)
		return nil, "could not make the instance socket: " .. describe()
	end
	closeOnExec(socket)

	if ffi.C.beat_instance_bind(socket, socketAddress, socketLength) ~= 0 then
		local code = ffi.errno()
		ffi.C.beat_instance_close(socket)
		ffi.C.beat_instance_close(lock)
		return nil, "could not bind " .. socketPath .. ": " .. describe(code)
	end

	return setmetatable(
		{ lock = lock, socket = socket, socketPath = socketPath, buffer = ffi.new("char[16]") },
		Claim
	)
end

--- Asks the running copy to come forward. False when nothing is listening: the copy that holds
--- the lock is starting, or on its way out.
---@param key string
---@return boolean
function posix.signal(key)
	local _, socketPath = places(key)
	local socketAddress, socketLength = address(socketPath)
	if socketAddress == nil then return false end

	local socket = ffi.C.beat_instance_socket(AF_UNIX, SOCK_DGRAM, 0)
	if socket < 0 then return false end
	local sent = ffi.C.beat_instance_sendto(socket, "show", 4, 0, socketAddress, socketLength) == 4
	ffi.C.beat_instance_close(socket)
	return sent
end

---@param seconds number
function posix.sleep(seconds)
	ffi.C.beat_instance_usleep(math.floor(seconds * 1000000))
end

return posix
