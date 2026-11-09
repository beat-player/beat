local env = require("env")
local worker = env.var("BEAT_WORKER")

-- The scan workers are this same program started again: the app starts a coordinator with
-- BEAT_WORKER=scan, and that coordinator starts its inspectors with BEAT_WORKER=inspect. See
-- `beat.workers.process` for how a compiled executable and a source run each start the copy.
local function main()
	if worker == "scan" then
		require("beat.workers.scan")
	elseif worker == "inspect" then
		require("beat.workers.inspect")
	else
		-- A launch while beat is already running brings that copy forward instead of starting a
		-- second one; see `beat.instance`. Workers above are copies the app started itself and
		-- never take part.
		local paths = require("beat.paths")
		local handedOver, claim, claimError = require("beat.instance").start(paths.directory())
		if handedOver then return end
		if claimError ~= nil then
			require("beat.log").write("warn", "running without the single-instance claim: " .. claimError)
		end

		local App = require("beat.app")
		App.instance = claim
		App:run()
	end
end

local ok, err = xpcall(main, debug.traceback)

if not ok then
	pcall(function()
		require("beat.log").write("fatal", err)
	end)
	error(err, 0)
end
