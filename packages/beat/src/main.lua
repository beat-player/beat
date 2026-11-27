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

	-- The window is gone, and was taken off the screen before the rest of this. Write what the
	-- services were holding and tell the threads to stop without waiting for a read that may take
	-- seconds; then let this function return. The process ends after it does, which is what
	-- reclaims the threads, their rings and their channels -- nothing here joins a thread or gives
	-- back what one may still be using, because that is what used to freeze or crash the close.
	--
	-- Returning rather than exiting is also what lets the runtime print what it measured: `lde run
	-- --profile` and `--memprof` write their reports after the program's main returns, and
	-- `os.exit` skipped them. That is a desktop's deal: there the process ends when main returns.
	App:flush()
	App:releaseThreads()

	-- A phone's process does not. The native activity thread returning from android_main leaves
	-- the activity finished and the process cached, kept up by the detached threads this close
	-- deliberately did not join -- the audio player, prefetch readers, cover decoders -- so a
	-- player the person closed stays in the background doing nothing but existing. Ending it here
	-- is what main returning already means on a desktop; the session and its notification were
	-- dropped first, so Android has nothing to restart. `lde run --profile` is not a phone's tool.
	if platform.android then os.exit(0, false) end
end

local ok, err = xpcall(main, debug.traceback)

if not ok then
	pcall(function()
		require("beat.log").write("fatal", err)
	end)
	-- Raise it rather than exiting: the runtime prints the error and the report it measured, and
	-- ends the process with a failure code.
	error(err, 0)
end
