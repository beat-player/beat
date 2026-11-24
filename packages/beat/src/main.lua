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
end

local ok, err = xpcall(main, debug.traceback)

if not ok then
	pcall(function()
		require("beat.log").write("fatal", err)
	end)
	error(err, 0)
end
