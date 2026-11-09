-- One beat per config directory. Two copies would both write settings.json, session.json and the
-- library, the last writer winning, and the second could not take the media keys. So a launch
-- that finds a copy running asks it to come forward -- out of the tray, up from the taskbar --
-- and ends there.
--
-- It is per config directory rather than per machine because the directory is what two copies
-- would fight over: a run pointed at another one (a test, a throwaway config) is its own beat.
local ffi = require("ffi")
local md5 = require("beat.music.md5")

local backend = ffi.os == "Windows" and require("beat.instance.windows") or require("beat.instance.posix")

--- What the running copy holds while it runs.
---@class beat.Instance
---@field poll fun(self: beat.Instance): boolean # Whether another launch asked for the window since the last time this was asked
---@field release fun(self: beat.Instance) # Lets the next launch be the one that runs; the process ending does too

-- How long a launch keeps trying a copy that holds the claim but cannot be reached -- one starting
-- up, or one quitting -- before it gives up on it.
local ATTEMPTS = 20
local PAUSE = 0.05

local instance = {}

--- The name a config directory is known by: short, and the same however the path is spelled on a
--- system whose paths ignore case.
---@param directory string
---@return string
function instance.key(directory)
	if ffi.os == "Windows" then directory = directory:lower() end
	return md5.sumhexa(directory):sub(1, 16)
end

---@param directory string
---@return beat.Instance? claim
---@return string? err # "running" when another copy holds it
function instance.claim(directory)
	return backend.claim(instance.key(directory))
end

--- Asks the copy running for `directory` to come forward.
---@param directory string
---@return boolean
function instance.signal(directory)
	return backend.signal(instance.key(directory))
end

--- What a launch does first: run, or hand over to the copy already running.
---
--- A copy that holds the claim and cannot be told is starting or quitting, so the launch waits a
--- moment and tries both again rather than ending with nothing on the screen. A claim that cannot
--- be made at all is reported and the launch runs anyway: keeping one copy is a protection, not
--- something beat needs in order to play.
---@param directory string
---@return boolean handedOver # Another copy is running and was asked to come forward: this launch ends
---@return beat.Instance? claim # What this launch holds while it runs
---@return string? err # Why it runs without a claim
function instance.start(directory)
	local key = instance.key(directory)
	local err
	for attempt = 1, ATTEMPTS do
		local claim, why = backend.claim(key)
		if claim ~= nil then return false, claim end
		if why ~= backend.RUNNING then return false, nil, why end
		if backend.signal(key) then return true end
		err = "another copy holds the config directory and does not answer"
		if attempt < ATTEMPTS then backend.sleep(PAUSE) end
	end
	return false, nil, err
end

return instance
