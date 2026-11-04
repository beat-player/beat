# Beat — full implementation plan

A local-first desktop music player for LuaJIT/lde, built on wonderland. Spotify's information
architecture and density, beat's own identity: near-black surfaces, acid-lime signal colour,
editorial cover art, restrained motion.

This document is the build plan, not the implementation. It records what exists, what is missing,
what will be built, in what order, and how it will be judged.

## Implementation status — 2026-11-02

The v1 build is implemented: two-pass scan with header inspection, in-memory library and search,
embedded/folder/generated art with downscaling and dominant colour, three themes and six accents, the full
shell and pages, keyboard shortcuts, playback queue with shuffle/repeat/seek/volume and a 120 ms
fade-in on manual starts, now-playing expansion with a windowed queue and volume, page fades,
animated toasts, a resizable sidebar, Ionicons vector glyphs, a native folder dialog,
incremental background scanning with a scan island, path-keyed tags with automatic and mixed
smart/manual playlists, playlist pages and listening metrics, tag-filtered search, and the headless
screenshot harness.

The reviewed screenshots are in `docs/screens/`; their matrix and known visual limits are in
`docs/visual-qa.md`. The matrix covers 1200×720, 1440×900, 960×640 and phone sizes
(390×844 portrait and 844×390 landscape), including onboarding, scanning, toasts, idle search,
no results, and expanded now playing. `tools/layout-debug.lua` saves
devtools box captures and a text table of calculated text boxes for breakpoint auditing.
`README.md` has the run, test and benchmark commands.

Known limits, kept honest:

- Library grids, the artist album grid, album track tables, and the search see-all pages are
  windowed; home shelves are capped. The search result page previews two album rows, 10 artists,
  and 100 tracks and links to the full category.
- Manual starts fade in over 120 ms. Automatic treble gapless transitions do not fade, and there is
  no crossfade between tracks (v2 by design).
- The sidebar is resizable by its right edge, can be collapsed from the brand or Settings, and is
  remembered across launches; below 1040 px it becomes the icon rail automatically. Below 760
  theme-px the shell becomes a phone layout with bottom tabs and a mini player; `docs/mobile.md`
  records the responsive contract and the winit blockers for real touch backends.
- Icons are Ionicons glyphs from a font generated from the bundled SVGs; the old canvas icon path
  has been removed.
- The primary folder action opens a native dialog in another process. Linux uses zenity/kdialog
  and macOS uses osascript; Windows falls back to the in-app browser.
- The visual matrix now includes toasts, scanning, no results, 960×640 and phone portrait/landscape;
  motion frames are not
  captured, only the settled screens.
- The scan benchmark is local-filesystem fast: 1,001 WAV files enumerated and inspected in 8 ms.
  The same run against the 4,054-file rclone Google Drive mount was bound by FUSE range-request
  latency and did not finish inside a 300 s cap. It now runs in the background: the UI stays
  responsive and already-scanned tracks appear, while a single blocking inspect can delay cancel
  by one file. A worker process is used rather than a thread.

---

## 0. Decisions

| Decision | Choice |
|---|---|
| Repo | lde monorepo: root app package `beat`, `packages/beat-core`, `packages/beat-ui` |
| Folder chooser | Native desktop dialog in its own window; in-app browser as fallback |
| Icons | Ionicons font generated from SVG sources, anti-aliased vector glyphs |
| Library | One root folder at a time, selected in-app; drag-and-drop also accepted |
| Persistence | User settings, a local library metadata cache and one downscaled JPEG per album. No database, search index or remote artwork reads in the window. |
| Scanning | Two-pass: fast directory enumeration, then a directory-balanced pool of header-only inspector processes |
| Audio | `treble` `Player`; beat owns queue/shuffle/repeat/previous/fades |
| Artwork | `treble` tags for embedded pictures, `image` for probe/decode, beat downscales and uploads |
| UI | Immediate-mode wonderland views; Spotify-derived shell; theme tokens; app-level motion |
| Motion | App-level animator (no built-in transitions in wonderland) |
| Default theme | Night + lime. Light and AMOLED themes, six accents |
| Quality gate | Headless screenshot matrix reviewed visually before a screen is called done |

### Why caches

A remote or FUSE mount makes every file read a round trip. Reading artwork from that folder while a
page is searching would block the frame, so the scan worker writes the library metadata and one
downscaled cover per album into the platform cache directories. The window reads only those local
files; the music folder is never opened by the UI process for artwork.

Written to disk: root folder, theme, accent, volume, mute, sort order, sidebar width and collapsed
state, UI scale, reduce-motion, Last.fm session, the local library cache and the per-root cover
cache. None of it is a database or a search index.

Settings file:

- Linux: `$XDG_CONFIG_HOME/beat/settings.json`, or `~/.config/beat/settings.json`.
- Windows: `%APPDATA%\beat\settings.json`.
- macOS: `~/Library/Application Support/beat/settings.json`.

No other file is written. A test asserts that a scan creates nothing.

---

## 1. Scope

### v1

- Choose a music folder; scan it recursively.
- Browse albums, artists, tracks.
- Instant search across artists, albums and track titles.
- Play/pause, previous/next, seek, volume/mute, shuffle, repeat off/all/one.
- Gapless track transitions where `treble` can stage the next track.
- Now-playing bar and expanded now-playing view with queue.
- Embedded cover art, folder cover art, generated placeholders.
- Theme switching: night, day, AMOLED; six accent colours.
- Page transitions, fades, now-playing expansion, progress motion, scan motion, toast motion.
- Responsive layout down to 960×640 desktop and 390×844 phone widths; real touch input needs a
  winit mobile backend.
- Keyboard shortcuts.
- Optional Last.fm desktop authentication, now-playing updates and scrobbles.
- No streaming, accounts beyond the optional Last.fm session, or telemetry.

### Explicitly later

- Playlists (M3U import/export) and favourites.
- Multiple library roots.
- Lyrics.
- Audio visualiser (treble does not expose a spectrum).
- ReplayGain / normalisation.
- Crossfade between tracks (needs two players; architectural room is left).
- Filesystem watching for automatic incremental updates.
- Native folder chooser per platform beyond Linux and macOS; the in-app browser remains the
  Windows fallback.
- Media keys / OS integration beyond window title and clipboard.

### Current repo state

`/home/once/Projects/Personal/beat` contains a scratch screen (`src/init.lua`, `src/ui/init.lua`)
written against the old generic `wonderland.App<...>` API. It is not a foundation. Milestone 0
deletes it and starts from the layout below.

---

## 2. Capability audit

### wonderland: what is usable

| Need | Available | Notes |
|---|---|---|
| App shell | `wonderland.app()`, `App:init/view/update/event`, plugins, `App:run` | `view(window, assets)` is rebuilt each frame; window width/height available |
| Layout | row/column flex, fixed/relative/auto sizes, gap, align, justify, padding/margin, border, z-index, visibility | Immediate mode; no media queries, so responsive rules are Lua math |
| Positioning | `:offset(x, y)` sets `position: relative`; such a child is out of flow at the parent origin | Verified in `layout.lua`; this is absolute-like overlay behaviour |
| Visual surface | background, foreground, bright multiplier, radius, shadow, blur, alpha colours | No gradient/transform/global opacity primitives |
| Text | system font registry, family/weight/italic, size scale, ellipsis | Font family/weight/size inherit; custom TTF paths supported |
| Images | textures, UVs, uploaded decoded images, gif/stream animations, surfaces | `Assets:upload(image)` exists; no release API (gap) |
| Shapes | `:canvas` with rect, line, circle, polygon; clipping by scroll parent | Enough for icons, gauges, placeholder art, decorative rules |
| Scroll | vertical `:scroll(offset)`, wheel/bar callbacks, clipping, themed bar | No horizontal scroll primitive; workaround in §9 |
| Input | click, double click, down/up, move, wheel, context menu, text input, slider, thumb, resize handle, file drop | No built-in focus traversal or disabled state |
| Global input | `App:event` receives unclaimed `keyPress`, mouse, `fileDrop`; `winit` key names | Enough for shortcuts and folder drop |
| Clock | `wonderland.time.now`, `App:onTick`, `App:every`, ticker `present` | Drives scan slices, audio pump, animation, progress |
| Headless | `wonderland.headless` renders offscreen, saves PNG, injects events/clicks/drags | The visual QA renderer |
| Devtools | F12 panel, F11 boxes, frame/quads/memory readouts | Development builds only |
| Screens | one window by default; `createWindow` task available | Beat needs one window |

### Packages

| Package | What it gives beat | Gaps / notes |
|---|---|---|
| `treble` 0.1.1 | `Player` queue, play/pause/stop/next, seek, position, duration, volume; WAV/FLAC/MP3/Opus decoders; tags incl. pictures | `audio.probe` is too slow for scanning (measured); no previous/shuffle/repeat; no `inspect` header-only path |
| `image` 0.1.3 | `probe` (format/width/height/channels/bits without pixels), `decode`/`load`, `new`, `getPixel/setPixel`, encode | No resize/crop; beat needs a downscaler for covers |
| `fs` 0.3.1 | `readdir` (opendir/readdir with `d_type`), `stat`, `watch`, path helpers | Fast enough; no recursive iterator built in |
| `path` 0.1.0 | join, normalize, resolve, basename, dirname, extension, relative | Use everywhere; never concatenate separators by hand |
| `json` 0.1.1 | yyjson-backed encode/decode | Settings only; no library serialization |
| `wonderland` | see above | `Assets:release`, window sizing/DPI gaps |
| `lde` | monorepo discovery, path deps, scripts, test runner | Root `lde test` runs all packages |

### Verified gaps, ranked

**P0 — blocks the quality bar**

1. **Fast metadata inspection.** `treble.audio.probe` measures 4.59 ms/file on real Opus files
   (50 files, 230 ms CPU). 4,054 files would be ~18.6 s. That is unacceptable. Add a header-only
   `treble.audio.inspect(path, opts)` returning tags/properties without opening a decoder.
2. **Cover texture lifetime.** `wonderland.Assets` caches path loads forever and has no release;
   `TextureManager.release` exists but takes a surface. Add `Assets:release(asset)` so a view can
   free covers when it leaves / when a folder or album page changes. Without this, browsing a
   large library leaks textures.
3. **Cover downscale.** `image` decodes full resolution only. A 3000×3000 JPEG cover is 36 MB in
   GPU terms. Implement a fast FFI box-filter downscale + centre crop in `beat-core` (or add
   `image.Image:resize` upstream). Target 512×512 max for hero art, 256×256 for thumbnails.

**P1 — needed for polish**

4. **Window size / minimum size / DPI.** `winit.Window.fromEventLoop` hard-codes 1200×720; no app
   option or min size; no DPI query. Proposal: add initial width/height and `setMinSize` to winit,
   expose `App.width/height/minWidth/minHeight`, and add a beat `uiScale` setting (0.8–1.5) until
   real DPI support exists.
5. **Horizontal shelves.** No horizontal scroll. Proposal: spike a shelf made of a clipping
   parent (`:scroll(0)`) + inner row (`:offset(-x, 0)`) and verify clipping, hit-testing and wheel
   mapping. If it fails, use wrapped grids for v1 shelves; the layout stays valid without them.
6. **Bundled typeface.** System fallback is inconsistent across machines. Ship Inter static faces
   (OFL) under `packages/beat-ui/assets/fonts`, set the family at the root, fall back to the
   machine's sans if loading fails.

**P2 — nice to have**

7. **App-level previous/shuffle/repeat.** `treble.Player` has no previous; beat can rebuild the
   queue for previous (or add a small `Player:clear()`/`playAt` API to treble).
8. **Media keys / tray / native picker.** Out of v1. In-app folder picker and drag-and-drop cover
   the requirement.

---

## 3. Proposed dependency changes

### wonderland

```lua
--- Gives a picture back: its slot and texture are released, and the quad that named it is gone.
---@param asset wonderland.Asset
function Assets:release(asset)
    self.textureManager:release({ slot = asset.texture })
end
```

Also add the two existing/new methods to the `wonderland.Assets` class fields so lye sees them:

```lua
---@field upload fun(self: wonderland.Assets, decoded: image.Image): wonderland.Asset
---@field release fun(self: wonderland.Assets, asset: wonderland.Asset)
```

Use only `Assets:upload` for covers, never `Assets:image`, so no hidden path cache is created.
`Assets:release` is the ownership edge: whoever uploaded it releases it.

Window sizing (winit/wonderland, small change):

```lua
winit.Window.fromEventLoop(eventLoop, width?, height?)
winit.Window:setMinSize(width, height)
App.width / App.height / App.minWidth / App.minHeight
```

Until this lands, beat targets the default 1200×720 and a UI-scale setting; no code depends on
window creation internals.

### treble

Add `treble.audio.inspect(path, opts)`; see §6.3 for the exact format rules. It must not open a
decoder, must not decode pixels/audio, and must not return picture bytes by default. `opts.pictures
= true` is the explicit eager path for tests.

Optional, if the queue behaviour needs it: `Player:clear()` (drop queued items but keep the current
track) and `Player:playAt(index)` for previous. Otherwise beat rebuilds the queue.

### image

No required change for v1 if `beat-core` owns the downscale. If upstream work is preferred, add
`Image:resize(width, height, filter?)` and `Image:crop(x, y, width, height)` with an FFI hot loop.
The beat-side fallback stays as the reference until that exists.

---

## 4. Monorepo

```text
beat/
├── lde.json                     # package "beat": the app entry, path deps on core + ui
├── lde.lock
├── README.md
├── PLAN.md                      # this document
├── STYLE.md                     # code style (wonderland/lye style)
├── src/
│   ├── init.lua                 # App class, init/view/update/event, ticker, assets ownership
│   ├── app/
│   │   ├── state.lua            # BeatState: library, queue, player, router, theme, motion
│   │   ├── actions.lua          # action union + dispatch
│   │   ├── router.lua           # page stack, transitions, per-page scroll state
│   │   ├── scan.lua             # scan controller: enumeration/inspect slices, progress
│   │   ├── audio.lua            # treble Player adapter, queue events, fades
│   │   ├── settings.lua         # json settings read/write; no media data
│   │   ├── shortcuts.lua        # key -> action mapping
│   │   └── overlays.lua         # toast, modal, folder picker, expanded now playing
│   ├── pages/
│   │   ├── home.lua
│   │   ├── search.lua
│   │   ├── library.lua
│   │   ├── album.lua
│   │   ├── artist.lua
│   │   ├── settings.lua
│   │   └── folders.lua
│   └── components/
│       ├── shell.lua            # sidebar + main + now playing
│       ├── topbar.lua
│       ├── sidebar.lua
│       ├── cover.lua
│       ├── album_card.lua
│       ├── album_grid.lua       # virtualised grid rows
│       ├── track_row.lua
│       ├── track_list.lua       # virtualised list
│       ├── now_playing.lua      # compact bar + expanded layer
│       ├── progress.lua
│       ├── toast.lua
│       ├── folder_picker.lua
│       ├── empty.lua
│       └── skeleton.lua
├── packages/
│   ├── beat-core/
│   │   ├── lde.json             # fs, path, treble, image, json
│   │   ├── src/
│   │   │   ├── init.lua         # public: Library, Scanner, Queue, art, inspect
│   │   │   ├── library.lua      # in-memory model + indexes
│   │   │   ├── scan.lua         # two-pass scanner, no I/O cache
│   │   │   ├── inspect.lua      # header-only tags/properties (calls treble.audio.inspect)
│   │   │   ├── art.lua          # decode/probe/downscale/crop/dominant colour
│   │   │   ├── queue.lua        # order, shuffle, repeat, history
│   │   │   ├── player.lua       # treble adapter
│   │   │   └── util.lua         # duration/date/normalisation helpers
│   │   └── tests/
│   └── beat-ui/
│       ├── lde.json             # wonderland
│       ├── src/
│       │   ├── init.lua
│       │   ├── theme.lua        # token model, themes, accents, colour alpha
│       │   ├── paint.lua        # alpha-aware style helpers
│       │   ├── motion.lua       # Animator, easings, timelines, reduce-motion
│       │   ├── icons.lua        # Ionicons glyph lookup
│       │   ├── virtual.lua      # list/grid virtualisation math
│       │   └── components/      # reusable primitives: button, chip, slider, cover...
│       └── tests/
├── tools/
│   ├── shots.lua                # headless screenshot matrix
│   ├── bench-scan.lua           # readdir vs inspect; prints per-file costs
│   ├── gen-fixtures.lua         # synthetic library + generated covers
│   └── profile.lua              # frame/scan budgets
├── docs/
│   ├── mockup-home.svg          # visual target: shell, home, now playing
│   ├── mockup-album.svg         # visual target: hero, track grid
│   ├── screens/                 # reviewed headless screenshots
│   └── visual-qa.md             # checklist + review log
└── tests/
    └── integration.test.lua
```

Dependency graph:

```text
beat (app) ──> beat-core ──> fs, path, treble, image, json
     │
     └──────> beat-ui ─────> wonderland
     └──────> wonderland
```

Commands:

```bash
lde run                 # app
lde test                # every package
lde test -C packages/beat-core
lde run tools/shots.lua # screenshot matrix
lye check .
```

`beat-core` must not require wonderland. All pixels/textures are app/UI concerns; core returns
image objects and byte strings.

While the P0 changes are in flight, `beat-core` depends on `treble` and `wonderland` by path
(`../treble`, `../wonderland`) so the inspector and `Assets:release` are visible. Before a
distributable build, pin released versions that contain those changes rather than shipping path
dependencies.

---

## 5. Architecture

### State

```lua
---@class beat.State
---@field library beat.Library?      -- nil until a root is selected and the first pass is done
---@field scan beat.ScanSession?     -- nil when idle
---@field queue beat.Queue?
---@field player beat.Audio
---@field router beat.Router
---@field settings beat.Settings
---@field theme beat.ui.Theme
---@field motion beat.ui.Animator
---@field toasts beat.Toast[]
---@field covers beat.CoverView     -- textures owned by the current view, released on teardown
```

`App:init`:

1. Load settings (json from the platform config dir).
2. Construct the theme, motion engine, router, audio adapter, settings object.
3. If a root is configured, construct `Library` and start a scan immediately (no first-frame wait).
4. Register one adaptive ticker (`App:onTick`) for scan slices, audio pump, animation, progress.
5. Nothing in `init` touches `assets`; it is nil until the window exists.

`App:view(window, assets)` is pure with respect to services:

- Reads state and settings.
- Builds styles through `beat-ui` components and the current theme.
- Asks the view-scoped cover owner for textures for visible items; a missing cover is requested
  (placeholder drawn this frame) and decoded/uploaded on a later tick.
- Never decodes images or reads files. Those happen in actions/ticks, before the next frame.

`App:update(message, window)` handles the action union from UI callbacks. `App:event` translates
unclaimed keyboard and `fileDrop` events to actions. The ticker mutates scan/audio/motion state and
calls `self:present(window)` only while it changed something.

### Action union

```lua
---@alias beat.Action
--- | { type: "navigate", page: beat.Page }
--- | { type: "back" }
--- | { type: "search", value: string }
--- | { type: "focusSearch" }
--- | { type: "playAlbum", id: number, trackId: number? }
--- | { type: "playArtist", id: number, trackId: number? }
--- | { type: "playTrack", id: number }
--- | { type: "playQueue", index: number }
--- | { type: "togglePlay" }
--- | { type: "next" }
--- | { type: "previous" }
--- | { type: "seek", seconds: number }
--- | { type: "volume", value: number }
--- | { type: "mute" }
--- | { type: "shuffle" }
--- | { type: "repeat" }
--- | { type: "expandNowPlaying", open: boolean }
--- | { type: "openFolders" }
--- | { type: "chooseFolder", path: string }
--- | { type: "rescan" }
--- | { type: "cancelScan" }
--- | { type: "theme", name: string }
--- | { type: "accent", name: string }
--- | { type: "uiScale", value: number }
--- | { type: "reduceMotion", value: boolean }
--- | { type: "toast", tone: "info"|"success"|"error", text: string }
```

UI elements return actions as message tables. No component mutates app state directly. This keeps
headless tests and keyboard/mouse paths on the same code.

### Ticker

```lua
function App:tick(now, window)
    local changed = false
    if self.scan then changed = self.scan:step(6) or changed end   -- 6 ms wall budget
    changed = self.audio:update() or changed
    changed = self.motion:update(now) or changed
    changed = self.coverView:sweep() or changed
    if changed then self:present(window) end
    local busy = (self.scan and not self.scan.done)
        or self.audio:isPlaying()
        or self.motion:isActive()
    return busy and (1 / 60) or 0.5
end
```

The 0.5 s idle heartbeat keeps logic (e.g., track end reconciliation) alive without redrawing; the
caller only presents when something changed. While playing, 60 Hz is required because
`treble.Player:update()` feeds the audio device.

---

## 6. Scanning

### 6.1 Rules

- One root, absolute path. The picker normalizes with `path.normalize`.
- Recursive, breadth-first. BFS makes top-level albums appear first and keeps the UI useful during
  the scan.
- `fs.readdir` per directory; use `entry.type` from `d_type` and never `stat` during the walk.
  `type == "unknown"` is the only case that stats.
- Skip symlinks (directories and files) by default: cycles, duplicate paths and surprise mounts
  are not worth it. Count them as skipped; make following them an explicit later setting.
- Hidden directories and files (`name[1] == "."`) are skipped. Also skip known junk:
  `@eaDir`, `#recycle`, `System Volume Information`, `$RECYCLE.BIN`, `.Trash*`.
- Audio extensions, case-insensitive: `flac`, `mp3`, `opus`, `ogg` (Opus only), `wav`.
  A file that claims an extension but fails inspection is skipped and reported.
- Folder cover candidates, case-insensitive: `cover`, `folder`, `front`, `album` with
  `jpg/jpeg/png/gif/bmp`. Record the path; do not decode during the walk.
- Folder cover candidates are recorded during the walk; the worker reads and caches one cover per album after inspection.

### 6.2 Pass 1 — enumerate (fast, complete list)

Walk the tree and collect:

```lua
---@class beat.ScanEntry
---@field path string
---@field dir string
---@field name string
---@field ext string
---@field cover string?      -- folder cover candidate for this file's directory
```

This pass is bounded by directory metadata, not file content. It gives an exact file count for
progress and lets the UI say "4,054 files" immediately. Memory is one path + one dir string per
file; 50k tracks is a few MB. If enumeration itself is huge, it is still time-sliced every N
directories.

Measured reference on this machine (`find`, warm cache, 4,054 Opus files): **30 ms**. `fs.readdir`
uses the same `readdir` syscall family with `d_type`, so it should be in the same order. This is
the fastest portable path: no shelling out, no per-entry `stat`, no decoder construction. A raw
`getdents64` binding on Linux would save less than the directory walk's noise and would not work
on the other two platforms; `fs.readdir` is the right level.

### 6.3 Pass 2 — inspect (header-only, parallel)

For each entry:

1. Open once with `io.open(path, "rb")`.
2. Read a bounded head (8 KiB first, then up to 64 KiB if the tag block needs it).
3. Detect by magic, not extension: `fLaC`, `ID3`/MPEG sync, `RIFF…WAVE`, `OggS`.
4. Parse only metadata. Never initialise a decoder. Never read audio packets.

Target output:

```lua
---@class beat.Inspect
---@field format "flac"|"mp3"|"opus"|"wav"
---@field sampleRate number
---@field channels number
---@field duration number        -- 0 when the container cannot say
---@field tags treble.Tags       -- picture bytes omitted by default
---@field hasPicture boolean
---@field pictureOffset number?  -- file offset when cheap to record; else nil
```

Per format:

- **FLAC** — `fLaC`, then metadata blocks. `STREAMINFO` gives sample rate, channels, total samples.
  `VORBIS_COMMENT` gives text tags. `PICTURE` is skipped for scanning; set `hasPicture`. Block
  headers are length-prefixed, so this is a few small reads and seeks, not a whole-file parse.
- **MP3** — ID3v2 header (10 bytes, synchsafe size) and frames. Parse text frames only; skip
  `APIC` (picture) and set `hasPicture`. ID3v1 is read from the last 128 bytes. For duration:
  first MPEG frame header gives sample rate/bitrate/channels; a Xing/Info/VBRI header gives frame
  count when present; otherwise estimate from `(fileSize - tags) * 8 / bitrate` and set
  `durationEstimated = true`.
- **Ogg Opus** — walk Ogg page headers and segment tables with seeks. `OpusHead` gives channels
  and pre-skip. `OpusTags` may span pages and may be megabytes because of
  `METADATA_BLOCK_PICTURE`; therefore read its vendor/comment lengths and text fields, and seek
  over the picture payload instead of requiring the whole packet in memory. Comments can appear
  after the picture, so the parser continues with seeks; it never reads base64 art during a scan.
  Duration: seek to the tail (last 64 KiB), find the last page's granule position,
  `(granule - preSkip) / 48000`.
- **WAV** — RIFF chunk walk. `fmt ` gives rate/channels/bits; `data` size gives duration;
  `LIST/INFO` gives tags. Skip unknown chunks by their size. No whole-file read.

**The header pass skips picture payloads.** ID3 `APIC`, FLAC `PICTURE`, Opus
`METADATA_BLOCK_PICTURE`, and folder image files are recorded as pointers (`hasPicture`,
`coverPath`). The inspector pool later reads one cover per album into the local cache; the window
only loads that downscaled file. The tag reader works with lengths and `f:seek`, not by loading the
tag block.

Fallback: if a header is malformed, call `treble.audio.probe` once for that file (correctness over
speed for a rare file), or skip with a recorded error. Never let one file break the scan.

Why this is enough: the measured cost of opening and reading 64 KiB per file is **0.07 ms/file**
warm (50 files, 3.12 MB, 4 ms CPU). 4,054 files is ~0.28 s of I/O plus parsing. The current
decoder-based `audio.probe` is **4.59 ms/file**, 65× slower and ~18.6 s for the same library.

Benchmark gate: `tools/bench-scan.lua` on the 4,054-file Opus folder must report **< 1.5 s** for
pass 2 and **< 2 s** end to end; per-file inspect average **< 0.4 ms**. If a format fails the gate,
optimise that parser before moving on.

### 6.4 Time slicing

`ScanSession:step(budgetMs)` runs until wall-clock budget (`wonderland.time.now`) is exhausted.
Default 6 ms per frame. Because most files cost well under 0.1 ms, this is dozens of files per
frame; the UI stays at 60 fps. On a slow mount, one read can exceed the budget; the session stops
after the current file and reports a longer frame, then continues.

Progress model:

```lua
---@class beat.ScanProgress
---@field phase "enumerate"|"inspect"|"done"|"cancelled"
---@field files number        -- total from pass 1
---@field inspected number
---@field tracks number       -- accepted
---@field skipped number
---@field errors { path: string, message: string }[]
---@field current string?     -- the path being inspected, for the UI
```

### 6.5 Grouping and fallbacks

Per file after inspect:

```lua
title       = tags.title or stripTrackPrefix(path.extension-free name)
artist      = tags.artist or parent folder name or "Unknown Artist"
album       = tags.album or parent folder name or "Unknown Album"
albumArtist = tags.albumArtist or artist
trackNo     = tags.track or leading number in file name
disc        = tags.disc or 1
year        = first 4-digit run in tags.date
genre       = tags.genre
duration    = inspect.duration
cover       = first embedded picture found in the album, else folder cover
```

Album key: `albumArtist .. "\0" .. album`. Discs are a property of the track, not of the album
key, so a multi-disc release is one album whose tracks sort by `(disc, trackNo, title, path)`.
When `albumArtist` is missing, group by album title plus the album's directory, so a folder of
tracks by different artists is still one compilation rather than N one-track albums.
Artist key: `albumArtist` (with `Various Artists` kept as an artist, not exploded per track).

Library indexes:

```lua
---@class beat.Library
---@field root string
---@field tracks beat.Track[]          -- discovery order, id = array index
---@field albums beat.Album[]          -- sorted after scan
---@field artists beat.Artist[]        -- sorted after scan
---@field albumsById table<number, beat.Album>
---@field artistsById table<number, beat.Artist>
---@field trackById table<number, beat.Track>
---@field byPath table<string, beat.Track>
---@field warnings { path: string, message: string }[]
```

No persistent index. Search haystacks (`titleLower`, `albumLower`, `artistLower`) are fields on
the in-memory objects, built once as tracks are added. This is part of the library, not a cache.

### 6.6 Search

- Query normalized with ASCII lowercase (`string.lower`; non-ASCII kept exact).
- Match against title, album, artist, album artist, path.
- `string.find(haystack, query, 1, true)`; no patterns.
- Group results: albums, artists, tracks; cap each group (e.g. 50/50/200) and virtualise.
- Empty query returns the library landing state.
- Recompute per keystroke with a linear scan over in-memory haystacks; measure at 50k tracks.
  No search index in v1. If the measurement is unacceptable, the answer is a better data layout,
  not a persisted index.

### 6.7 Rescan / cancel

- Changing the root stops playback, releases the old library and starts a new scan.
- The Rescan button stops playback and rebuilds the library and cover cache from disk. Same
  folder, same paths.
- Cancel drops the scan, clears the partial library and returns to the folder picker.
- Errors are collected and shown as "N files skipped" with a details view; they do not abort.

---

## 7. Artwork and image metadata

### 7.1 Sources

1. Embedded picture in the first track of the album that has one (`treble.Tags.picture`).
2. Folder cover candidate recorded during pass 1.
3. Generated placeholder.

The scan worker decodes one cover per album — the first track with an embedded picture, else the
folder picture — downscales it and writes a local JPEG. The window only loads that local file;
`hasPicture` / `coverPath` remain on the track for the worker and for cache invalidation.

### 7.2 Pipeline

```text
bytes/path
  -> image.probe(bytes[, path])   -- format, width, height, channels, bits; no pixels
  -> image.decode(bytes, { channels = 4 })   -- or image.load(path)
  -> beat-core.art.fit(img, 512)  -- centre crop to square + box-filter downscale
  -> dominant colour (8×8 sample of the fitted image)
  -> decoded:close()
  -> assets:upload(fitted)
  -> fitted:close()
  -> texture owned by the current view; released when the view no longer needs it
```

- Hero/cover: 512×512 max. Thumbnails: 256×256 max.
- Box filter: average source pixels per destination pixel; direct `image.pixels` FFI access, not
  `getPixel`/`setPixel` per sample. This keeps a 3000² → 512² downscale in the tens of
  milliseconds.
- Non-square art is centre-cropped to square before scaling. This is what streaming UIs do;
  letterboxing looks amateurish.
- If `image.probe` fails or dimensions exceed a sane bound (e.g. 100 MP), use the placeholder and
  record a warning.
- The placeholder is drawn by `:canvas`: deterministic hue from the album title hash, two soft
  bands, the album's first letter/initials. No texture, no decode, themeable.

### 7.3 Texture lifetime

- Decoded files live in `~/.cache/beat/covers/<root-hash>/` (or the platform cache directory).
  The scan worker writes them; a completed scan prunes files it did not use.
- `beat-ui.Covers` is a per-view texture owner, not a second disk cache. It maps
  `sourceKey -> asset` only while that source is drawn by the current page; when the page changes,
  it releases every asset with `Assets:release` and clears the map.
- The home page and sidebar may show the same album simultaneously: one key, one asset, released
  when the page teardown runs.
- No path cache in `Assets:image`.
- Visible bound: home grid + sidebar + now playing, roughly 40 covers × 512² × 4 = 42 MB worst
  case; with 256 thumbnails for grids, ~11 MB. Releasing on navigation keeps it flat.
- The window loads a local cached JPEG on the frame after the page is requested and fits it to the
  requested size; the placeholder is shown until the texture exists. No remote read, no shimmer
  loop.

### 7.4 Theme from artwork

`dominantColour` returns the cached cover's averaged colour. Use it for the featured album cover
halo (album hero, artist hero and expanded now playing); keep the global accent for controls. Clamp
it against text contrast. It comes from the same local cover file that is uploaded, so no extra
remote read is needed.

---

## 8. Playback

### 8.1 Adapter

`beat-core.Player` wraps one `treble.Player`.

- `playQueue(tracks, index)`: `player:close()`, enqueue `tracks[index..]` (all of them; paths are
  opened lazily), `play()`.
- `toggle()`: `isPlaying()` ? `pause()` : `play()`.
- `next()`: `player:next()` if a next item exists; update queue index. If at the end, stop.
- `previous()`: if `position() > 3`, `seek(0)`; else rebuild the queue at `index - 1` and play.
- `seek(seconds)`: `player:seek(seconds)`; update the UI immediately.
- `volume(value)`: map 0–1 to `player:setVolume`; mute keeps the previous value.
- `update()`: call `player:update()` every tick while playing/feeding; return whether the UI needs
  a frame (position changes, track end, error).
- `onTrackEnd`: advance the queue index; when repeat-one is on, seek(0) instead of advancing.
  Keep the UI honest even if treble moved to the next track before the callback.
- `onError(err)`: toast the error, mark the track failed, try the next item; never crash browsing.

### 8.2 Queue

```lua
---@class beat.Queue
---@field tracks beat.Track[]
---@field order number[]          -- playback order, indices into tracks
---@field position number         -- index into order
---@field repeat "off"|"all"|"one"
---@field shuffle boolean
---@field source string           -- "album:12", "artist:4", "library", "search"
```

- Shuffle: Fisher–Yates over `order`, keeping the current track first. Reshuffle starts from the
  current track. No persistence.
- Repeat all: wrap to the first item and rebuild the treble queue when the end is reached.
  Repeat one: enqueue only the current track, so `treble` cannot auto-advance; on `onTrackEnd`,
  `seek(0)` and play. Repeat all: wrap and rebuild the treble queue.
- Queue view lists current + upcoming; "play next" and "remove" are v1 if cheap, otherwise v2.
- Gapless: `treble` stages the next decoded track; beat enqueues the full order, so the next track
  is already decoding. Do not enqueue one-at-a-time.

### 8.3 Fades

- Play: volume ramps 0 → target over 120 ms.
- Pause: volume ramps target → 0 over 80 ms, then `pause()`. If the user presses play again during
  the ramp, reverse from the current value.
- Seek: no fade; the position jump is what the user asked for.
- Track transitions: no crossfade in v1; `treble` gapless. Each new track starts at the target
  volume (or a 120 ms fade-in if it is user-initiated, not auto-advance).
- Reduce-motion does not disable audio fades.

### 8.4 Position/progress

- While playing, tick at 60 Hz; `player:position()` is cheap. The progress bar and elapsed time
  are rebuilt each frame.
- While paused, no 60 Hz tick; position is stable.
- Duration comes from the library inspect. If unknown/estimated, show `--:--` until the player
  reports a duration; do not animate a fake total.

---

## 9. UI

### 9.1 Shell

```text
┌───────────────┬──────────────────────────────────────────────────────────┐
│ 264 sidebar   │ top bar 64: back/forward · search · settings            │
│               ├──────────────────────────────────────────────────────────┤
│ brand         │                                                          │
│ Home          │  page content (scrolls)                                  │
│ Search        │                                                          │
│ Library       │                                                          │
│               │                                                          │
│ Your Library  │                                                          │
│ chips         │                                                          │
│ album rows    │                                                          │
│               │                                                          │
├───────────────┴──────────────────────────────────────────────────────────┤
│ 88 now playing: cover · title/artist · controls · progress · volume     │
└──────────────────────────────────────────────────────────────────────────┘
```

- Window: 1200×720 default; min 960×640 once winit supports it.
- Sidebar: 264 px; collapsed icon rail at <1040 px, with a tooltip/label on hover. It is resizable
  via `:resize({ edge = "right" })`; width persists in settings.
- Main content: 32 px padding; 24 px at <1100; content scrolls under a 64 px top bar.
- Now playing: 88 px fixed bottom, top border, cover 56, controls centered, progress 600 px max,
  volume 90 px. Expanded mode layers over the entire window.
- Background: layered surfaces. Album pages get a blurred/dimmed cover wash; home gets a subtle
  top vignette (canvas gradient bands) and no big imagery.
- No pure black on night theme; `#0b0c10` base, `#14161b` surface, `#1b1e24` elevated.

### 9.2 Pages

**Onboarding / folder picker** — full-window, centered. Brand, headline "Choose your music
folder", path breadcrumb, folder list (icons, names, chevrons), "Select this folder", "Use home",
recent root. Drag-and-drop hint. The list uses `fs.readdir`, hides dot folders, supports back/up,
and an editable path field. Double-click opens a folder; the primary button selects the current
one.

**Scanning** — shell with sidebar; content shows progress and the last inspected title. Top bar
chip: spinning equaliser + "4,054 files · 1,200 scanned". Cancel button. Skeleton shelves appear
as tracks arrive. No modal blocking.

**Home** — "Good evening" (time-of-day greeting), "Recently added" 5-across card row, "Your albums"
3-across cards, "Artists" row. Cards: square art, title, artist. Hover lifts/brightens the card and
reveals a lime circular play button over the art. Clicking the card opens the album; clicking play
starts it. Shelf rows are grids in v1 until the horizontal-shelf spike passes.

**Library** — header with count, sort menu (title/artist/year/recent), grid/list toggle, filter
chips. Grid uses virtualised rows of cards; list uses 56 px rows with 40 px art. Alphabet jump
could be v2.

**Album** — hero: 224 px cover, "ALBUM" eyebrow, 46 px title, artist link, year · tracks · duration,
lime play button and a ghost shuffle button. Backdrop: dominant colour + blurred cover wash,
falling off into the page background. Track table: `#`, title, album, time, 48 px rows; current
track highlighted with equalizer bars; hover shows a play glyph in the index column. Header row is
sticky? v1: scrolls with content; v2 sticky.

**Artist** — hero whose image is the first album cover, softly cropped, or the generated
placeholder; name, track/album counts;
top tracks; albums grid.

**Search** — top bar field focused; results grouped Albums / Artists / Tracks; each group has a
"see all" if capped. Empty query shows "Search your library" with recent-ish suggestions that are
derived from the current library (not persisted). No results: illustration + copy + clear action.

**Settings** — appearance (theme swatches, accent chips, UI scale, reduce motion), library (root,
rescan, details of skipped files), audio (volume), about (version, formats, build). Settings are
immediate; no save button.

**Now playing expanded** — full-window overlay. Blurred/dimmed dominant cover backdrop, large
cover (up to 360 px), title/artist, progress with scrubbing, controls, volume, queue side panel
(upcoming tracks). Fade/scale in from the bar. Escape or the chevron closes. Clicking the cover
opens the album.

**Queue** — panel/list of current + upcoming; now-playing row accent; drag reordering is v2;
"play next"/"remove" if cheap.

**Toasts** — bottom center above the now-playing bar, 320 px max, tone icon, text, 4 s exit fade;
errors 8 s and dismissible.

### 9.3 Typography

- Bundled Inter (OFL): Regular 400, Medium 500, SemiBold 600, Bold 700. Fallback: `Segoe UI`,
  `SF Pro Text`, `Noto Sans`, `DejaVu Sans`.
- Scale: 11, 12, 13, 14, 16, 20, 24, 30, 32, 46. Line heights from font metrics; no manual line
  boxes unless a component needs a fixed row.
- Page title 30/32 semibold; hero title 46 bold; section 19 semibold; card title 13 semibold;
  body 13/14 regular; metadata 12; captions 11.
- Never all-caps for content; only 10/11 px eyebrows with 1.2 letter-spacing.
- Ellipsis on every single-line bounded text: card title, artist, sidebar row.

### 9.4 Colour and themes

Tokens (night default):

| Token | Value |
|---|---|
| `bg` | `#0b0c10` |
| `sidebar` | `#07080a` |
| `surface` | `#14161b` |
| `elevated` | `#1b1e24` |
| `hover` | `#23272f` |
| `active` | `#2a2f38` |
| `text` | `#f4f6f9` |
| `muted` | `#9aa3b2` |
| `faint` | `#6f7786` |
| `border` | `#ffffff12` |
| `accent` | `#c9f45b` (lime) |
| `accentInk` | `#0a0c08` |
| `danger` | `#ff6b6b` |
| `success` | `#7ee787` |
| `overlay` | `#000000a6` |

Day theme: bg `#f6f7f9`, sidebar `#ffffff`, surface `#ffffff`, elevated `#f0f1f4`, hover
`#e7e9ee`, text `#111318`, muted `#5c6474`, border `#00000014`, accent `#4f7f00` (with white ink).
AMOLED: bg/sidebar `#000000`, surface `#0a0a0c`, elevated `#121216`, same text scale.

Accents: lime `#c9f45b`, mint `#5eead4`, violet `#b69cff`, coral `#ff7a66`, blue `#6ea8ff`, amber
`#ffc857`. Each has an `accentInk` (dark for lime/mint/amber, near-white for violet/coral/blue).
Accent is used for play controls, active nav, current track, focus rings, progress fill, selection;
not for large surfaces. Album pages may tint with the art's dominant colour while keeping controls
accented.

Themes are pure data + a `theme.color(token, alpha)` function. Every component builds styles
through it. Switching theme is a state change plus a 220 ms colour fade (interpolate token values,
rebuild each frame).

### 9.5 Responsive rules

Computed from `window.width`/`height` in the view:

- `>= 1240`: sidebar 264, 5 album columns, now-playing progress 600.
- `1040–1239`: sidebar 240, 4–5 columns, progress 480.
- `960–1039`: sidebar 76 (icon rail), 4 columns, progress 360, volume slider 70.
- `760–959`: sidebar 76, 3 columns, compact top bar.
- `< 760`: phone shell — no sidebar, bottom tabs, mini player, 16-px gutters and responsive grids.
  `docs/mobile.md` has the full mobile/touch contract.
- Card size `min(180, floor((contentWidth - gaps) / columns))`; art is square.
- Now-playing title truncates before controls compress; controls never overlap.
- Page padding 32 → 24 → 20 as width falls.

### 9.6 Component behaviour and states

- **Button**: primary (accent fill, ink text), secondary (surface, border), ghost (text only),
  icon (transparent, circular hover), danger. Hover bright + hover surface; active pressed
  brightness; focus ring 2 px accent; disabled 40% alpha (app-level, no built-in disabled).
- **Chip**: pill, surface; selected uses accent ink; 28 px height.
- **Cover**: 1:1, radius 8 (cards) / 10 (hero), placeholder, image, overlay play button on hover,
  release on teardown.
- **Album card**: art, title, artist; hover lift via `:offset(0,-2)` (animate 160 ms) + shadow;
  play button 40 px accent circle; click card navigates, click button plays.
- **Track row**: 48 px; hover surface; index becomes play glyph; current row accent title + 3
  animated equalizer bars; playing row shows pause glyph on hover.
- **Progress/slider**: 4 px track, accent fill, 12 px thumb on hover/drag; buffered? no; tooltip
  with target time on drag; click jumps; drag updates a preview, commit on release (or live seek
  every 100 ms while dragging).
- **Now playing bar**: click cover/title navigates to album; controls; expand chevron; queue button.
- **Toast**: accent/danger left rule, icon, text; in/out motion; stack max 3.
- **Empty state**: canvas illustration (vinyl/record), title, muted copy, primary action.
- **Skeleton**: 3 stacked blocks with an alpha pulse (1.2 s), used only before first library data.

### 9.7 Icons and brand

- Icons are Ionicons 7.4 SVGs, packed into a generated font so the text renderer anti-aliases them
  at every size and the theme colours them. Filled icons are used for transport, search, home,
  library, folder, settings and GitHub; outline icons are used for chevrons, shuffle, repeat,
  check and mute.
- Icon set: play, pause, previous, next, shuffle, repeat, repeat-one, volume, mute, search, home,
  library, playlists, tag, folder, chevron-left/right/down/up, close, check, settings, GitHub.
- Brand mark: beat's original five-bar mark + lowercase `beat` wordmark.
- No emoji in the UI; no external icon font.

### 9.8 Keyboard

| Key | Action |
|---|---|
| `space` | play/pause (unless a text field is focused) |
| `left` / `right` | seek −5 s / +5 s |
| `up` / `down` | move selection in a list |
| `return` | activate selection / play |
| `/` or `ctrl+f` | focus search |
| `escape` | close overlay, clear search, or back |
| `ctrl+left` / `alt+left` | back |
| `ctrl+,` | settings |
| `ctrl+o` | folder picker |
| `f12` | devtools (dev builds) |

Inputs keep their own keyboard while focused; `App:event` handles only unclaimed keys. `space` in a
search field must type a space, not toggle playback.

---

## 10. Motion and theming implementation

### 10.1 Motion engine (`beat-ui/motion.lua`)

- `Animator` holds a list of live animations; `update(now)` returns true if any are live.
- `Tween` with `from`, `to`, `duration`, `easing`, `onUpdate`; `Spring` for the now-playing
  expansion and press feedback.
- Easings: `outCubic`, `outQuint`, `inOutCubic`, `outBack` (small overshoot only).
- Tokens: `instant 0`, `fast 120 ms`, `base 180 ms`, `slow 260 ms`, `page 220 ms`, `overlay 280 ms`,
  `startup 400 ms`.
- Reduce motion: all non-essential durations become 0; page/overlay crossfades become 80 ms
  opacity-only; audio fades stay.
- Animations are state, not closures stored in elements; the view reads current values each frame.
- No animation runs when nothing is visible/playing: the ticker goes to the 0.5 s idle heartbeat.

### 10.2 Alpha

wonderland has no global opacity. `beat-ui/paint.lua` carries an `alpha` multiplier; every colour
goes through `paint.colour(token, extraAlpha)`. Components receive `paint`, so a page/overlay fade
is a single multiplier threaded through text, surfaces, borders and images. Image alpha is not
per-quad; image fades use a solid veil (theme bg with alpha) or `bright` toward black on dark
themes. Text and surfaces fade correctly.

### 10.3 Motion inventory

| Transition | Motion |
|---|---|
| App startup | 400 ms veil from black + shell fade; stagger hero/sections by 40 ms |
| Page push | 220 ms; incoming alpha 0→1, offset y 10→0; outgoing alpha 1→0 under it |
| Back | reverse, 180 ms |
| Now playing expand | 280 ms spring (stiffness 220, damping 26); bar rises into full overlay; cover grows 56→320; backdrop alpha 0→1 |
| Now playing collapse | 220 ms ease-in; reverse |
| Album hero | 260 ms backdrop fade/scale 1.03→1 on enter |
| Track hover | 120 ms surface fade; play glyph alpha 0→1 |
| Card hover | 160 ms lift −2 px + shadow; play button alpha/scale 0.9→1 |
| Play/pause press | 90 ms scale 1→0.94→1 (implemented as size/offset, not transform) |
| Progress | position interpolation at 60 Hz while playing; seek preview line 120 ms |
| Scan | equalizer bars 900 ms loop, progress width eased; no spinner texture |
| Toast | 180 ms slide 12 px + fade in; 160 ms fade out |
| Theme switch | 220 ms colour interpolation across tokens |
| Album art ready | 160 ms brightness ramp over the placeholder on dark themes; immediate swap on light themes (images have no per-quad alpha) |

### 10.4 Theme implementation

- `theme.lua` exposes static token tables and `theme.style(name)` helpers for shared style atoms
  (surface, card, row, button). Style atoms are immutable design tokens, not a data cache.
- Accent changes rebuild style atoms once per theme switch; views use them.
- Per-album dominant colour is passed as a local override for hero/backdrop and current-row
  highlight; contrast is recomputed against text.
- No theme is hard-coded in a component: components ask for `theme.colors.*`, `theme.radii.*`,
  `theme.space(n)`, `theme.type.*`.

---

## 11. Performance budgets

| Area | Budget |
|---|---|
| First frame | < 150 ms from launch, shell visible before scan completes |
| Enumeration | < 150 ms for 10k files; bounded by directory metadata |
| Inspect | < 1.5 s for 4k files; < 0.4 ms/file average; 6 ms slice |
| Scan end-to-end | < 2 s for 4k warm files; UI stays at 60 fps |
| View build | < 4 ms for 200 elements / < 8 ms for a 1000-node screen |
| Frame | 60 fps while animating/playing; no full-tree rebuild for progress if avoidable |
| Memory | library tables < 10 MB for 10k tracks; visible cover textures < 64 MB; released on navigation |
| Textures | 512 hero / 256 thumbs; release on page teardown |
| Search | < 8 ms per keystroke at 10k tracks; virtualise results |
| Audio | `player:update()` every 60 Hz frame while playing; no file or image work in that tick |

Virtualisation:

- Track list: render `ceil(viewport / 48) + overscan(6)` rows plus top/bottom spacer heights.
- Album grid: compute columns from width; render visible rows + 1, with spacers.
- Sidebar library: cap at a virtualised window; the whole library is not built as elements.
- Never build one element per track for a 20k-track album page.

---

## 12. Testing and visual QA

### 12.1 Unit tests

`packages/beat-core/tests/`:

- Inspector vs `treble.audio.probe` on tagged fixtures: title/artist/album/track/disc/year,
  duration, sample rate, channels, picture presence.
- Duration edge cases: VBR MP3 without Xing (estimated), FLAC total samples, Opus tail granule,
  WAV data size.
- Scanner: synthetic tree with nested albums, hidden dirs, symlink loop, junk extension, corrupt
  file, folder cover, missing tags; assert grouping and fallbacks. Scan twice, assert identical
  grouping and a stable local cover cache.
- Covers: downscale dimensions, aspect ratio, centre crop, dominant colour bounds, image close.
- Queue: shuffle keeps current, repeat off/all/one, previous threshold, end-of-queue.
- Settings: round-trip all keys, missing/corrupt file → defaults, path per OS.
- Performance: `bench-scan.lua` numbers in CI logs; no hard wall-clock assertion unless stable.

`packages/beat-ui/tests/`:

- Theme token contrast (text on bg/surface/accent), colour alpha, accent ink.
- Motion easing endpoints, animator completion, reduce-motion zero duration.
- Virtual list math: offsets, overscan, spacer heights, empty list.
- Icons render without errors at all sizes (headless).

### 12.2 Headless integration

`tests/integration.test.lua`:

- Build a fixture library (synthetic, no filesystem) and render every page with
  `wonderland.headless` at 1200×720 and 1440×900.
- Inject clicks: nav, album card, play, seek, search, theme switch, now-playing expand.
- Assert state transitions (page, queue index, playing, theme) and no diagnostic/error output.
- Render after scan progress, empty library, no results, error toast.
- Save screenshots to `docs/screens/`.

### 12.3 Visual QA loop

`tools/shots.lua` is the design review harness:

- Deterministic fixture library: 40 albums with generated covers (gradients/geometric motifs),
  long titles, missing art, current track, scan states.
- Deterministic font (bundled Inter) and fixed window sizes.
- Matrix: pages × themes × sizes × states (hover, playing, paused, empty, error).
- Save PNGs and a contact sheet; inspect each at 1:1 with the image viewer.
- Checklist: alignment to the 4/8 px grid, spacing rhythm, type hierarchy, contrast, truncation,
  image aspect, radius consistency, shadow softness, hover/selected/playing distinction, no clipped
  text, no overlapping now-playing, no scrollbar collisions, theme legibility, empty/loading/error
  completeness.
- No screen ships without a reviewed screenshot. Record the review in `docs/visual-qa.md` with
  date and screenshot path. Re-run after any layout/theme change.
- Use `wonderland.devtools` (F11 boxes) to catch one-pixel gaps and overflow during development.

Golden-image pixel comparisons are deliberately avoided: fonts and GPUs differ. Invariant pixel
probes (accent button fill, current-row tint, background token) and visual review are the gate.

### 12.4 Cross-platform

- Linux is the development platform.
- Windows/macOS: run core tests, inspector fixtures, folder picker, path handling, and a manual
  smoke on the audio backend. `fs`, `path`, `treble` and `winit` are already cross-platform; add
  CI jobs when the app stabilises.
- Do not concatenate `/`; always `path.join`.
- Case-insensitive extension checks.
- Long paths on Windows: use `path` and keep names; document the limitation if `io.open` fails.

---

## 13. Milestones

### M0 — repo and foundations

- Replace the scratch app; create monorepo packages and `lde.json` files, deps (`fs`, `path`,
  `treble`, `image`, `json`, `wonderland`, `lde-test` dev).
- Copy the style guide; add `tools/bench-scan.lua`, `tools/gen-fixtures.lua`, `tools/shots.lua`
  skeleton.
- Add `Assets:release` in wonderland (or a local patch), and the UI scale setting.
- Acceptance: `lde run` opens an empty themed window; `lde test` green; lye clean.

### M1 — scan and library

- `treble.audio.inspect` (or beat-core equivalent) + tests + benchmark.
- Scanner pass 1/2, time slicing, progress/cancel, grouping/fallbacks, folder covers.
- In-memory library indexes, search haystacks, sort.
- Acceptance: 4,054 files scanned in < 2 s; 10k synthetic files; the worker writes the local
  metadata/cover caches while the window stays responsive; corrupt and missing tags handled.

### M2 — UI foundation and onboarding

- Theme + paint + motion + icons + primitives (button, chip, cover, empty, skeleton, toast).
- Shell (sidebar/topbar) with responsive rules.
- Folder picker page; settings persistence; drag-and-drop.
- Acceptance: choose a folder, see scan progress, shell looks correct in all three themes at three
  sizes; screenshot review passed.

### M3 — home and album

- Home shelves (grids first; horizontal spike behind a flag).
- Album page hero, track table, virtualization, play/seek wiring.
- Cover loading/downscaling/dominant colour; release on navigation.
- Acceptance: album page matches the mockup; 40-cover page stays within texture budget; hover,
  current-track and playing states reviewed.

### M4 — library, artist, search

- Library grid/list, sort, filters; artist page; search page with grouped results and keyboard.
- Acceptance: 10k-track library navigates without frame drops; search < 8 ms; empty/no-results
  states reviewed.

### M5 — playback, queue, now playing

- `beat-core.Queue` and `Player` adapter; gapless queue; shuffle/repeat/previous; fades.
- Compact and expanded now playing; queue panel; toasts/errors.
- Acceptance: full album plays gaplessly; controls, seek, volume, shuffle/repeat; now-playing
  expansion at 60 fps; audio errors do not crash.

### M6 — polish

- Page transitions, stagger, theme colour interpolation, album backdrop motion, progress smoothing.
- Settings page complete (appearance, library details, about).
- Keyboard shortcuts; accessibility pass.
- Acceptance: motion inventory implemented; reduce-motion respected; screenshots reviewed.

### M7 — hardening and release

- Performance profiling with `wonderland.devtools`; memory soak while browsing 200 albums.
- Cross-platform smoke; packaging; README with screenshots and shortcuts.
- Final visual QA matrix; no known P0/P1 visual defects.
- Acceptance: definition of done below.

---

## 14. Risks

| Risk | Mitigation |
|---|---|
| Header inspector is subtly wrong for some files | Test against `treble.audio.probe` on fixtures per format; fall back to probe on parse failure; never skip silently |
| Slow disks/network mounts stall a slice | Small first read; time-sliced; progress; do not run inspection in the audio tick |
| Cover textures exhaust GPU memory | 512/256 caps, visible-only loading, release on navigation, measured bound |
| Blur backdrop is expensive | Bound to album hero (not full screen); fall back to dominant-colour wash if frame time exceeds budget |
| Fonts differ across machines | Bundle Inter; deterministic font path in screenshots; fallback chain |
| No DPI awareness | UI scale setting now; winit DPI later; test at 1.0/1.25/1.5 |
| Horizontal shelves unsupported | Spike early; fall back to wrapped grids, which still match the planned information architecture |
| `treble` backend fails on a machine | Browse still works; toast error; core tests do not require an audio device |
| Remote scan delays first paint | Cached library metadata draws immediately; the scan worker fills metadata and local covers without blocking frames |
| Huge libraries (50k+) | Virtualise lists/grids; measure scan/search; cap search results; no per-track elements |
| Theme contrast regressions | Token contrast tests; visual QA in all themes |
| Stale beat scaffold confusion | M0 deletes it; do not extend `src/init.lua` or `src/ui/init.lua` |

---

## 15. Definition of done

- [ ] Select a folder in the in-app picker; the library scans with progress and no blocking.
- [ ] A second launch rescans from disk; no library/metadata/art cache exists.
- [ ] Albums, artists, tracks and search reflect the folder exactly, with sane fallbacks.
- [ ] Embedded and folder covers load lazily, are downscaled/cropped, and are released when a
  view goes away.
- [ ] Playback: play/pause, previous/next, seek, volume/mute, shuffle, repeat off/all/one,
  gapless next track, error recovery.
- [ ] Now playing compact/expanded, queue, progress, current-track highlight, keyboard shortcuts.
- [ ] Folder picker, scan, home, library, album, artist, search, settings, empty/loading/error
  states all present and reviewed.
- [ ] Night, day and AMOLED themes; six accents; theme switch animates; settings persist.
- [ ] Motion inventory implemented; reduce-motion works; no animation runs while idle.
- [ ] Responsive at 1440×900, 1200×720 and 960×640; no clipped text or overlapping controls.
- [ ] `lye check .` clean; `lde test` green; benchmark gate met; screenshots in `docs/screens/`.

---

## Appendix A — theme tokens

```lua
---@class beat.ui.Theme
---@field name string
---@field colors table<string, beat.ui.Colour>
---@field radii { sm: number, md: number, lg: number, xl: number, full: number }
---@field space fun(n: number): number
---@field type { xs: number, sm: number, base: number, md: number, lg: number, xl: number,
---              xxl: number, hero: number }
---@field motion { fast: number, base: number, slow: number, page: number, overlay: number }
```

Required colour tokens: `bg`, `sidebar`, `surface`, `surfaceAlt`, `elevated`, `hover`, `active`,
`text`, `muted`, `faint`, `border`, `accent`, `accentInk`, `danger`, `dangerInk`, `success`,
`overlay`, `skeleton`, `scrollbar`.

## Appendix B — file support

| Format | Extensions | Decoder | Tags | Picture |
|---|---|---|---|---|
| FLAC | `.flac` | treble/dr_flac | Vorbis comments | FLAC picture block |
| MP3 | `.mp3` | treble/dr_mp3 | ID3v2/ID3v1 | APIC |
| Opus | `.opus`, `.ogg` | treble/opusfile | Vorbis comments | `METADATA_BLOCK_PICTURE` |
| WAV | `.wav` | treble built in | LIST/INFO | none |

Cover image formats: whatever `image` decodes — PNG, JPEG, GIF, BMP, TGA, QOI, PNM. No WebP.

## Appendix C — mockups

- `docs/mockup-home.svg` — shell, home shelves, sidebar library, compact now playing.
- `docs/mockup-album.svg` — album hero, dominant-colour wash, track table, current track.

These are the visual targets for M2/M3. They are wireframes: final screenshots in
`docs/screens/` are the review evidence, not the mockups.

---

## Appendix D — reference measurements

Environment: Linux, warm page cache, `/home/once/Drive/Music/Checked`, 4,054 Opus files.

| Operation | Measurement |
|---|---|
| `find` all files | 0.030 s |
| `fs.stat` | 0.005 ms/file |
| Read 64 KiB header | 0.070 ms/file |
| `treble.audio.probe` | 4.59 ms/file |
| Projected 4k probe scan | ~18.6 s |
| Projected 4k header scan | ~0.3 s I/O + parsing |

These numbers are the reason for the header-only inspector. The metadata cache avoids a rescan on every launch; the worker's local cover cache keeps remote artwork reads off the UI thread.
