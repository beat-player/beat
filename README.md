# Beat

A local-first desktop music player for LuaJIT and lde, built on wonderland. It reads the tags and
cover art already in your files, plays through treble, and writes user settings, tag and playlist
definitions, and local caches. There is no database or search index. The scanner keeps a local metadata cache and a
per-album cover cache, so a remote music folder is read by the background worker rather than by the
window. Last.fm scrobbling is optional and only talks to Last.fm when an account is connected.

## Layout

| Path | What it is |
|---|---|
| `packages/beat/src/` | The app package: state, actions, the shell and every page |
| `packages/beat-core` | Scanning, library grouping, tags and playlists, search, cover caching/downscaling, queue, playback, Last.fm signing |
| `packages/beat-ui` | Theme tokens, motion, icons and shared drawing primitives |
| `packages/beat/tests/` | Headless app tests: pages, search input, library windowing, Last.fm, theme and sidebar width |
| `packages/beat/tools/scan-worker.lua` | The background scanner process |
| `packages/beat/tools/shots.lua` | Renders the screenshot matrix into `packages/beat/docs/screens/` |
| `packages/beat/tools/bench-scan.lua` | Measures directory enumeration and header inspection on a real folder |
| `packages/beat/tools/layout-debug.lua` | Solves a page headlessly, saves devtools boxes, and writes a text box table |
| `packages/beat/tools/build-icon-font.cjs` | Rebuilds the bundled Ionicons face from `packages/beat/assets/ionicons/` |
| `packages/beat-ui/src/assets/fonts/` | Ionicons (MIT), embedded into the UI package as vector glyphs |
| `packages/beat/assets/ionicons/` | Ionicons 7.4 SVG sources and licence, used to build the bundled face |
| `packages/beat/docs/` | Visual QA notes and rendered screenshots |
| `packages/beat/docs/mobile.md` | Phone layout, winit input audit and the touch-bridge plan |

`beat-core` and `beat-ui` are sibling path dependencies. `wonderland 0.1.6` and `texter 0.1.4`
add faces read from bytes, which is what lets the icon font travel inside the executable. While
those releases are being prepared, the UI package and wonderland point at the sibling wonderland
and texter checkouts; the published versions replace those path dependencies. The rest of the
external dependencies come from the registry: `winit 0.1.8`, and `treble 0.2.0` plus the registry
image/JSON/path/fs packages for `beat-core`. The app depends on winit through wonderland, so the
window-icon implementation comes from that release as well.

## Run

```sh
lde sync -C packages/beat
lde run -C packages/beat
```

The first launch asks for a music folder. **Choose folder…** opens the desktop's own dialog in a
separate window — zenity or kdialog on Linux, the Finder chooser on macOS. The app keeps running
while the dialog is open, polls its result, and starts the scan when a folder is chosen. **Browse**
is the in-app fallback, and dropping a folder on the window also starts a scan.

Scanning runs in `packages/beat/tools/scan-worker.lua` as a separate coordinator process. It walks the folder
once, then starts a small pool of inspector processes (`BEAT_SCAN_WORKERS`, four by default) so a
high-latency mount keeps several file reads in flight. The library grows as tracks report, so albums,
search and playback are usable before the scan finishes. The inspectors also write one downscaled
JPEG per album into the local cover cache, so the window never reads artwork from the remote folder
and covers fill in as albums arrive. A floating progress island can be collapsed into the progress
bar in the sidebar; the sidebar bar reopens it.

Settings live at `$XDG_CONFIG_HOME/beat/settings.json` or `~/.config/beat/settings.json`; tags and
playlists live beside them in `tags.json`. Settings hold the root folder, theme, accent, volume,
mute, sort order, sidebar width and collapsed state, UI scale, reduced-motion preference, and the
connected Last.fm account's username and session key. The tag file holds track paths, their tags,
and the smart and manual playlist definitions. No media data is persisted. The file is kept private to the account that runs beat because the Last.fm
session key can act on that account.

## Tags and playlists

Tags are the organizing layer. A track can carry tags such as **High Energy** or **Late Night**.
The tag button in the expanded now-playing track view opens a tag picker with every tag as a pill;
changes are saved to `tags.json` immediately. Each tag automatically owns a smart playlist with its
name. On the Playlists page tags are pills: clicking a tag's name makes that pill writable, and a reserved
right-hand slot holds the delete control when the pill is hovered. An unused tag deletes at once;
a tag already on tracks asks first, because its automatic playlist and assignments go with it.
Playlists keep the stable tag id, not the name, so a rename follows through everywhere.

Playlists are one kind of thing, not two: a playlist may have tag criteria, hand-added tracks, or
both. Smart matches and manual additions are merged; the two small icons beside a playlist name show
which it has. Clicking a playlist opens the same collection page an album does — hero, Play,
shuffle and track table — with one extra **+** control that opens the album picker. Tracks and albums
can also be added from their context menus. Every playlist can be edited by hand, including the
automatic playlist a tag creates. Right-click a playlist row to delete it. The sidebar keeps up to
three playlist shortcuts, most recently played first; the row shows artwork and count, and hovering
reveals the playlist name. The last row
is an accented **New playlist** tile.

Search and its see-all pages expose the same tag filters, with all/any matching. Listens are recorded
for tracks, albums, tags and playlists; the home page puts **Recently listened** before the rest of
the shelves. The library's sort control is a dropdown whose options take the accent colour on hover.

At phone widths the desktop rail becomes a bottom tab bar with a compact mini player, full-width
pages, two-column shelves and stacked collection heroes. Album and playlist pages share the same
layout. `packages/beat/docs/mobile.md` records the responsive rules and why a real touch build still needs a
winit mobile backend for touch, density, IME and lifecycle events.

## Last.fm

Last.fm is optional. The application's API key and shared secret are compiled into beat, so a
listener does not configure anything:

1. Open **Settings → Last.fm** and press **Connect**.
2. Authorize **beat** on the Last.fm page that opens, then return to the app. It polls
   `auth.getSession` and stores the session key for that listener's account once the browser step
   is done.

Each account gets its own session key. It is kept in `settings.json`; disconnecting clears it.
Because the shared secret is carried by a desktop binary, it can be extracted; the key identifies
beat, and the session key is what can act on a listener's account. The app credentials live in
`src/app/lastfm_credentials.lua` and should be replaced there when they are rotated. While
connected, beat sends `track.updateNowPlaying` when playback starts and submits a scrobble after
the track has been heard halfway, or for four minutes, whichever comes first. Tracks shorter than
30 seconds are not scrobbled. Requests go through the `curl-sys` multi interface, so the window
stays responsive while Last.fm is slow or offline; failed scrobbles stay queued for the next attempt
while beat is running. The **Scrobbling** toggle pauses submissions without disconnecting.

## Controls

- `Space` play/pause
- `Left` / `Right` seek five seconds
- `/` or `Ctrl+F` search
- `Ctrl+O` choose a folder through the native dialog
- `Ctrl+,` settings
- `Escape` close the expanded now-playing view, clear search, or go back

## Distribution builds

`.github/workflows/_build.yml` is the reusable native build matrix. Every target is built on its
own runner through `lde-org/setup-lde@v2`:

| Asset | Runner |
|---|---|
| `beat-linux-x86-64.zip` | `ubuntu-22.04` |
| `beat-linux-aarch64.zip` | `ubuntu-22.04-arm` |
| `beat-windows-x86-64.zip` | `windows-latest` |
| `beat-windows-aarch64.zip` | `windows-11-arm` |
| `beat-macos-x86-64.zip` | `macos-15-intel` |
| `beat-macos-aarch64.zip` | `macos-15` |

Nightly builds run on pushes to `master` that touch `packages/**`, and from manual dispatch. They
publish to the rolling `nightly` prerelease. Release builds run when a GitHub release is created and
upload each target asset directly to that release. Every matrix job is independent: if one target
fails, the release receives the assets the other targets built. Each archive contains only the
executable: the window icon and the icon face are embedded as Lua modules. The CI jobs install
`glslang-tools`, Homebrew `glslang`, or the official Windows `glslang.exe` before syncing, because
wonderland compiles its Vulkan shaders with one of those tools.

```sh
git tag v0.2.0
git push origin v0.2.0
# then create the GitHub release from the tag
```

## Test and check

```sh
lde test                              # every package in this repository
lde test -C packages/beat             # app headless tests only
lde test -C packages/beat-core
lde test -C packages/beat-ui
cd packages/beat && lye check
```

The scan benchmark takes any music folder:

```sh
lde run -C packages/beat bench -- /path/to/music
# or: lde run -C packages/beat tools/bench-scan.lua /path/to/music
```

Its two numbers are the two passes the scanner runs: directory enumeration, then a header-only read
per file. The scan coordinator hands directory-balanced shards to several inspector processes, and
they read and downscale one cover per album into the local cache; the window only loads those local
files and never reads the music folder for artwork. On a local filesystem the scan is milliseconds
per thousand files. On a network/FUSE mount every header read is a round trip; a Google Drive rclone
mount is bound by the mount, not by the scanner, and the process pool overlaps those round trips
without blocking the frame.

Library grids, the artist album grid, and the search see-all pages are windowed; home shelves are
capped. The search result page previews two album rows, 10 artists, and 100 tracks and links to the
full category. Decoded cover textures are view-local and released on navigation; the downscaled
JPEGs they come from stay in the local cache. The interface font is Inter when the machine has it,
with the platform fallback otherwise.

## Screenshots and layout debugging

```sh
lde run -C packages/beat shots
```

This writes the night shell, all pages, day, AMOLED, onboarding, scanning, toasts, idle/no-result
search, 1440×900 and 960×640 variants to `packages/beat/docs/screens/`.
`packages/beat/docs/visual-qa.md` records the reviewed matrix and the known limits.

When something looks off, inspect the solved boxes rather than guessing from the pixels:

```sh
lde run -C packages/beat tools/layout-debug.lua                 # library at 960, 1200, and 1440
lde run -C packages/beat tools/layout-debug.lua album 960 640
```

It writes `packages/beat/docs/screens/debug-<page>-<width>.png` with every layout box and
`packages/beat/docs/screens/debug-<page>-<width>.txt` with every text box's `x y width height`. It
also reports text boxes that fall outside the window or a scroll viewport.

## Design notes

- **The music folder stays off the search path.** The scan runs in a coordinator process and a pool
  of inspector processes, and they also read and downscale album art into `~/.cache/beat/covers`
  (or the platform cache directory). The window loads only local metadata and cover files, so
  searching or browsing cannot block on the mount. Playback still streams the chosen audio file
  through treble; making that path asynchronous is a separate change in the audio layer.
- **Covers are view-local.** Only the page on screen owns textures; navigation releases them. The
  downscaled files behind them are cached per library root and pruned after a complete scan.
- **One queue.** Shuffle, repeat and queue jumps live in `beat-core` and are shared by the bar, the
  album page, the artist page, and the expanded view.
- **Playlist art is a mosaic.** A long playlist spreads four tracks over a 2×2 cover behind its
  initials; one track uses its cover whole, two or three leave the rest black, and the rounded
  parent clips every case to the same silhouette.
- **Tags are the source of truth.** Smart playlists, manual playlist membership and search filters
  all read the same path-keyed tag assignments; a manual playlist's membership is a hidden tag tied
  to its playlist id.
- **Last.fm is optional and non-blocking.** The client signs its calls in `beat-core`, carries them
  over `curl-sys`'s multi interface, and runs the same scrobbler state machine as the rest of the
  app; an offline Last.fm never stalls a frame.
- **Cover colour carries the page.** Featured covers cast a soft halo in their dominant colour;
  the colour comes from the same small decoded copy that is uploaded as the texture.
- **Manual starts fade in.** A 120 ms ramp avoids the click of a hard start; treble's gapless
  automatic transition keeps the target volume.
- **The equalizer lives below the screen.** Five peaking biquads run over decoded PCM in treble
  before volume; beat stores the band gains and built-in or custom presets, and the panel's
  centre-zero sliders edit the same values the audio thread uses.
- **Small type has a floor.** The type scale keeps labels at 15 px even at the 90% UI setting;
  below that, hinted grayscale glyphs lose their counters and spacing rather than merely looking
  small. FreeType light hinting keeps horizontal bearings aligned with HarfBuzz's advances, and
  glyphs retain subpixel horizontal positions, so a short word does not pull itself apart.
- **Immediate mode.** Views are plain functions; page transitions, hover states and the now-playing
  expansion are values in app state, not retained widgets. A page change slides the new body in
  from the direction of travel and settles it from a slightly dimmed state, with no black veil.
