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
