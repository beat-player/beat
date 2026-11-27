# Performance rules

beat redraws at the display's rate while anything moves, on phones as well as desktops. A frame
that allocates, or that LuaJIT cannot compile, shows up as stutter: the collector pauses, the
interpreter runs ten times slower than a trace, and a trace that keeps aborting spends the frame in
the JIT compiler. These rules are what made scrolling smooth. Follow them in beat, beat-ui,
wonderland, hood and texter.

## What counts as hot

Anything that runs every frame or every tick: page and component `view` functions, canvas draw
callbacks, wonderland's layout, walk and render passes, hood's command recording, and every
service's `step`. Code that runs once (startup, a scan, a click) may allocate; code that runs per
frame may not.

## Allocation

- No tables, strings or closures built per frame. Build styles, props, messages, labels and
  formatted strings once and cache them, keyed by the inputs they come from (theme, size, album
  id, state). Reformat a number only when it changes.
- Pass children as varargs (`div():children(a, b, c)`), not through a temporary list.
- Reuse scratch tables and ffi buffers kept at module level or on an instance; clear them in place.
- Never move bulk data through Lua strings. Pixels, PCM and file contents live in C memory
  (`threading_alloc`, `ffi.new` once) and are freed when consumed.
- Styles built from changing values (`sty():h(dynamicHeight)`) intern a new permanent style each
  time a value is new; keep such values few and bounded.

## Writing code LuaJIT can compile

- No function definitions inside hot functions (`FNEW is NYI`). Hoist callbacks, comparators and
  draw functions to module level and pass state as arguments, or create one per cached record.
- No closures over locals declared inside a loop body (`UCLO is NYI`).
- No varargs forwarding in hot calls (`VARG is NYI`): no `fn(...)` pass-through, `select("#", ...)`
  loops or `{...}`. Use fixed arity.
- Numeric `for` loops over arrays; no `pairs`, `ipairs` or `while true ... break` in hot loops.
- No recursion in per-frame tree passes: LuaJIT cannot compile it. Walk trees with an explicit
  stack in one loop.
- Keep hot loops small and flat. A loop that contains another loop aborts as "inner loop in root
  trace": flatten (iterate the inner items with a running outer index) or move the inner loop
  into a function called from the loop.
- Keep few values alive across branches. Move rare cases (edges, errors, first-time setup) into
  separate functions or a second pass after the loop. Clamp with `math.min`/`math.max` instead of
  `if` branches.
- Don't pass long argument lists through hot calls ("register coalescing too complex"). Write the
  values into one reused ffi struct and pass that.
- Don't index ffi struct arrays element by element in interpreted-or-hot code just to read
  fields: keep references in a Lua table and read through those.
- Don't mix array and hash keys in a table that is read every frame (for example ids that are
  positive and negative): key it by the object instead.
- Precompute `ffi.typeof` results; never `ffi.typeof` or `ffi.new` per frame.
- `src/app.lua` sets `jit.opt.start("maxtrace=4000", "maxmcode=8192", "loopunroll=6")`. The lower
  unroll keeps the render loops under the trace length limit; don't remove it.

## C calling back into Lua

LuaJIT panics with `bad callback` when a C function called from compiled code calls back into
Lua. Any C call that can invoke a Lua callback (libcurl's `curl_multi_perform`, anything taking an
`ffi.cast` function) must be made from a function with `jit.off(fn)` applied, so it always runs from
the interpreter.

## Threads

A pointer crosses to another thread as its eight raw bytes in a string, never as a Lua number:
Android tags heap pointers above 2^53 and a double rounds them.

## Starting up

The library cache is read after the first frame: a worker parses the file and pushes its records
in batches, and the app takes a few milliseconds a tick into the library. View rebuilds while it
loads are held to eight a second, and the sort that closes the load runs a slice of a frame a
tick, so the rebuild that shows the final order comes once. A scan's folder walk is a thread of
its own sending entries back a batch at a time, and the cache a finished scan writes is encoded
and written a slice a tick. Tags are written on a thread, so the check a toggle draws does not
wait for the disk. On Linux the folder dialog is shown on a worker too: the portal call blocks
until the person answers, which is not something a frame may do. Hover marks are built from the
boxes the previous solve produced, so a frame where the pointer has not moved is solved once.
Clocks are formatted once per whole second, not once per playhead position.

## In the background

A hidden window draws nothing, so nothing may run at the display's rate while it is hidden:
`App:tick` sleeps a second instead of a frame. A service that has something to do sooner returns how
many seconds away it wants the next tick -- a thirtieth of a second while a track plays, a fifth
of a second between the slide and the fade of a toast -- and a tick that no service asks for is a
second away as well. A toast the pointer rests on needs no tick of its own: its own mouse-move
message pushes its expiry forward, so the ticker wakes only for the animations and the expiry. A
shown window playing a track ticks thirty times a second: the playhead asks for a
frame only when it moves a pixel, and the meter is fed thirty times a second. A hidden window tells
the audio thread, which then wakes every 75 ms instead of every 20 and stops feeding the spectrum. A
paused player releases the device after five seconds, after which the audio thread blocks untimed on
its command channel until the app asks for something; a prefetch reader whose ring is full blocks
until the audio side consumes it. Per-sample work on the audio thread (equalizer, volume, the
spectrum tap) runs for every second of music whether or not the app is shown; keep it in flat
numeric loops over ffi arrays.

Coming back is an edge rather than the next hidden tick: wonderland makes the app's tickers due as
soon as it sees the window shown, so the tick that tells the audio thread it is in the foreground,
resyncs the meter and asks for a frame runs before the loop waits again. Covers survive a short
hide -- a minimize or an app switch -- and only give their textures back after half a minute away,
so the screen that comes back is not a page of placeholders while the decodes run.

To measure a phone playing in the background, read each thread's CPU ticks and context switches
from `/proc/<pid>/task/*/stat` and `status` over `adb shell` twice, 30 seconds apart. Compare runs
with the screen in the same state, because a dozing phone runs its cores slower.

## Measuring

- `tools/bench.lua` drives the app headless. `BEAT_BENCH_MODE=idle|redraw|scroll|playing`,
  `BEAT_BENCH_PAGE=...`, `BEAT_BENCH_FRAMES=...`; it prints KiB allocated per frame and frame
  times. Read its header for the rest.
- `lde run --jit tools/bench.lua` lists trace aborts. Run it at two frame counts (for example 300
  and 3000) and diff: a site whose count grows with frames aborts every frame and must be fixed;
  one that stays flat is a one-off.
- `lde run tools/vmprof.lua` samples VM states per source line and skips startup
  (`VMPROF_SKIP=<cpu seconds>`). Steady-state scrolling should be mostly compiled, with the JIT
  compiler near zero.
- `lde run --memprof tools/bench.lua` shows allocation sites.
- On a device, the debug plugin's overlay shows fps, main-thread CPU per frame, Lua heap and RSS.

## Building for Android

`packages/beat/target` is shared between desktop runs and APK builds. Don't run `lde test` or
`lde run` while an APK compiles: the APK can end up with host (x86-64) libraries and die at start.
