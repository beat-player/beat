local env = require("env")
local worker = env.var("BEAT_WORKER")

-- The scan workers are this same program started again: the app starts a coordinator with
-- BEAT_WORKER=scan, and that coordinator starts its inspectors with BEAT_WORKER=inspect. See
-- `beat.app.worker_process` for how a compiled executable and a source run each start the copy.
local function main()
	if worker == "scan" then
		require("beat.app.scan_worker")
	elseif worker == "inspect" then
		require("beat.app.scan_inspect_worker")
	else
		require("beat.app"):run()
	end
end

local ok, err = xpcall(main, debug.traceback)

if not ok then
	pcall(function()
		require("beat.app.log").write("fatal", err)
	end)
	error(err, 0)
end
