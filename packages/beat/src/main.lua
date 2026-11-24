local platform = require("beat.platform")

local function main()
	-- A launch while beat is already running brings that copy forward instead of starting a
	-- second one; see `beat.instance`.
	local paths = require("beat.paths")
	local handedOver, claim, claimError = require("beat.instance").start(paths.directory())
	if handedOver then return end
	if claimError ~= nil then
		require("beat.log").write("warn", "running without the single-instance claim: " .. claimError)
	end

	local App = require("beat.app")
	App.instance = claim
	-- The hardware volume keys are the player's while it is in front, and a player's keys are the
	-- media stream's.
	platform.useMediaVolumeKeys()
	platform.followUserRotation()
	App:run()

	-- The window is gone. Write what the services were holding, tell the audio and scan threads to
	-- stop without waiting for a read that may take seconds, and leave. `os.exit` with a false
	-- second argument skips the Lua finalizers: the threads are still alive, and giving back their
	-- channels or rings from here is what used to freeze or crash the close.
	App:flush()
	App:releaseThreads()
	os.exit(0, false)
end

local ok, err = xpcall(main, debug.traceback)

if not ok then
	pcall(function()
		require("beat.log").write("fatal", err)
	end)
	-- The same reason the close path skips finalizers: a fatal error must not wait on a thread.
	io.stderr:write(tostring(err) .. "\n")
	os.exit(1, false)
end
