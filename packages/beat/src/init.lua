local env = require("env")
local worker = env.var("BEAT_WORKER")

-- A compiled executable carries the scan workers as modules but no tools directory. The app starts
-- a coordinator by running this same executable with BEAT_WORKER=scan, and that coordinator starts
-- its inspectors the same way with BEAT_WORKER=inspect.
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
