-- Background workers are copies of beat itself: `src/main.lua` reads BEAT_WORKER and runs the
-- worker it names instead of the window.
--
-- A source run is the `lde` runtime with beat's modules linked into a package's `target/`, so the
-- copy is `lde run` of that package -- whatever script started the parent, which in a test or a
-- tool is not beat's entry point, and `arg` is not even set under `lde test`. A compiled executable
-- carries its modules inside it, finds no such file, and is started again as it is.
--
-- Every worker is told which process started it (`BEAT_PARENT_PID`), and kills itself once that
-- process is gone: a window closed or killed while a scan runs must not leave a coordinator and
-- four inspectors walking a music folder for a reader that no longer exists. See
-- `beat.workers.parent`.
local env = require("env")
local ffi = require("ffi")

local workerProcess = {}

local isWindows = jit.os == "Windows"

---@type fun(): number|ffi.cdata
local getPid
---@type fun(milliseconds: number)
local sleep

if isWindows then
	ffi.cdef[[
		uint32_t GetCurrentProcessId(void);
		void     Sleep(unsigned int);
	]]
	local kernel32 = ffi.load("kernel32")
	getPid = function() return kernel32.GetCurrentProcessId() end
	---@param milliseconds number
	sleep = function(milliseconds) kernel32.Sleep(ffi.cast("unsigned int", math.floor(milliseconds))) end
else
	ffi.cdef[[
		int  getpid(void);
		int  usleep(unsigned int);
	]]
	getPid = function() return ffi.C.getpid() end
	---@param milliseconds number
	sleep = function(milliseconds) ffi.C.usleep(math.floor(milliseconds * 1000)) end
end

--- The id of this process, which is what a worker it starts watches.
---@return number
function workerProcess.pid()
	return tonumber(getPid())
end

--- Waits for `milliseconds` without spending the wait: used for the short polls a cancel and a
--- worker's own loop make, where a busy spin would cost a core for no sooner an answer.
---@param milliseconds number
function workerProcess.sleep(milliseconds)
	sleep(milliseconds)
end

--- The arguments that start beat again: `run -C <package>` from source, nothing for an executable.
---@return string[]
local function selfArgs()
	local entry = package.searchpath("beat", package.path)
	local root = entry and entry:match("^(.*)[/\\]target[/\\]beat[/\\]init%.lua$")
	if root == nil then return {} end
	return { "run", "-C", root }
end

--- Starts a worker with `vars` (BEAT_WORKER and its paths) in its environment.
---@param vars table<string, string>
---@return process.Child? child
---@return string? err
function workerProcess.spawn(vars)
	-- Required here rather than at the top: `process` declares `struct pollfd` in the C namespace,
	-- and winit-x11's wait declares it too without checking first. Loading both in the same
	-- process is fine when winit goes first (process's second declaration is identical), but
	-- when process goes first winit's `ffi.cdef` fails with "attempt to redefine 'pollfd'". A
	-- module that only starts a worker should not pull in a declaration that can collide with a
	-- window's, so it waits until a worker is actually started -- by then the window's winit is
	-- already loaded.
	local process = require("process")
	vars.BEAT_PARENT_PID = tostring(workerProcess.pid())
	return process.spawn(assert(env.execPath()), selfArgs(), { env = vars, stdout = "null", stderr = "null" })
end

return workerProcess
