-- Background workers are copies of beat itself: `src/main.lua` reads BEAT_WORKER and runs the
-- worker it names instead of the window.
--
-- A source run is the `lde` runtime with beat's modules linked into a package's `target/`, so the
-- copy is `lde run` of that package -- whatever script started the parent, which in a test or a
-- tool is not beat's entry point, and `arg` is not even set under `lde test`. A compiled executable
-- carries its modules inside it, finds no such file, and is started again as it is.
local env = require("env")
local process = require("process")

local workerProcess = {}

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
	return process.spawn(assert(env.execPath()), selfArgs(), { env = vars, stdout = "null", stderr = "null" })
end

return workerProcess
