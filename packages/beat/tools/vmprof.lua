-- Where the time of a `tools/bench.lua` run goes, by VM state and source line: compiled traces,
-- the interpreter, C code, the collector and the JIT compiler. The interpreted and compiler lines
-- are the ones to fix; see docs/performance.md.
--
--   lde run tools/vmprof.lua                                    # the bench's default suite
--   VMPROF_SKIP=3 BEAT_BENCH_MODE=scroll BEAT_BENCH_FRAMES=20000 lde run tools/vmprof.lua
--
-- VMPROF_SKIP ignores the first seconds of CPU time, so startup -- device creation, first
-- compiles -- does not hide what a steady frame costs. VMPROF_LINES sets how many lines to list.
local profile = require("jit.profile")

local STATE_NAMES = { N = "compiled", I = "interpreted", C = "C code", G = "GC", J = "JIT compiler" }

---@type table<string, number>
local counts = {}
---@type table<string, number>
local totals = {}
local skipUntil = os.clock() + (tonumber(os.getenv("VMPROF_SKIP")) or 0)
local lines = tonumber(os.getenv("VMPROF_LINES")) or 60

---@param thread thread
---@param samples number
---@param vmstate string
local function sample(thread, samples, vmstate)
	if os.clock() < skipUntil then return end
	totals[vmstate] = (totals[vmstate] or 0) + samples
	if vmstate ~= "N" then
		local key = vmstate .. " " .. profile.dumpstack(thread, "pl", 1)
		counts[key] = (counts[key] or 0) + samples
	end
end

---@param a { key: string, count: number }
---@param b { key: string, count: number }
local function bySamples(a, b) return a.count > b.count end

profile.start("li1", sample)
dofile("tools/bench.lua")
profile.stop()

local all = 0
for _, count in pairs(totals) do all = all + count end
if all == 0 then
	io.stderr:write("no samples: the run was shorter than VMPROF_SKIP\n")
	return
end

for state, count in pairs(totals) do
	io.stderr:write(string.format("%-14s %5.1f%%\n", STATE_NAMES[state] or state, 100 * count / all))
end

---@type { key: string, count: number }[]
local list = {}
for key, count in pairs(counts) do list[#list + 1] = { key = key, count = count } end
table.sort(list, bySamples)
for at = 1, math.min(lines, #list) do
	local item = list[at]
	io.stderr:write(string.format("%6d %5.1f%%  %s\n", item.count, 100 * item.count / all, item.key))
end
