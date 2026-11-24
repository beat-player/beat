# Using lde

This project is built using lde. Read https://lde.sh/llms.txt for everything you need
to know about building, running, handling dependencies and running tests.

# Using lye

Use `lye` for type checking and formatting.

# Performance

Code that runs every frame or tick must not allocate and must compile under LuaJIT: no closures,
varargs or recursion in hot paths, no per-frame tables or strings, no C calls that call back into
Lua from compiled code. Read `docs/performance.md` before changing views, components, services'
`step` functions or rendering code, and measure with `tools/bench.lua` and `tools/vmprof.lua`.
