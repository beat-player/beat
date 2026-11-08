<p align="center">
  <img src="packages/beat/assets/icon-256.png" width="88" alt="beat icon">
</p>

<h1 align="center">beat</h1>

<p align="center">
  <strong>A small, fast desktop music player.</strong>
</p>

![beat playing the home screen](docs/screenshots/home.png)

## Features

- **Executable size.** The native executable is 4.1 MB. It contains the application, the renderer, and the audio engine. You do not install a runtime or a browser.
- **Memory use.** An empty window uses approximately 130 MB RSS. A library of 4,054 tracks uses approximately 166 MB RSS. Scan processes use approximately 60 MB RSS in total.
- **Parallel scan.** The application does not scan the music folder in the window process. A scan coordinator starts four inspector processes. The inspectors read files at the same time. A network folder can keep several reads active. Tracks and covers appear during the scan.
- **LuaJIT.** The application is written in Lua. LuaJIT compiles the Lua code. [lde](https://lde.sh) builds one native executable. You do not install Lua or a virtual machine.
- **Last.fm.** You can connect a Last.fm account in Settings. The application sends now-playing data and scrobbles. Network requests do not block the user interface. Failed scrobbles are retried while the application runs.
- **Tags and playlists.** A tag makes a smart playlist. You can add tracks to a playlist by hand. You can also combine tag rules and hand-added tracks. Search filters use the same tags. The application stores tags and playlists in JSON files next to the settings.

> **Plugins** The application is one LuaJIT process. The pages, services, library, tags, and playback queue are Lua code. The renderer and audio engine are lde packages with Lua interfaces. A plugin loads into the same Lua state. It can call the same functions as the application and can extend any screen. There is no IPC boundary and no ABI. A plugin is one file made with `lde bundle` from its own lde package; put it in the `plugins` folder inside beat's config folder (Settings → Plugins has a button that opens it). A plugin found there is on. The Plugins page lists what loaded and can switch an outside plugin file off; a switched-off file is skipped before it is run, and a switch takes effect after beat is restarted, because plugins are part of the app from its first frame. A bundle carries copies of the modules it was built against, but it cannot replace one beat already ships, and a plugin that will not load is listed with the reason rather than stopping the app — and can still be switched off. A plugin can add a destination to the sidebar and the phone's tabs with `beat.nav`, ask for the system folder dialog and get its answer as a message (`pickFolder`), add one folder to the library without rescanning the rest (`libraryAddFolder`), and make non-blocking HTTP requests or downloads through the shared `http` service.

## Screenshots

<p align="center">
  <a href="docs/screenshots/library.png"><img src="docs/screenshots/library.png" width="49%" alt="Library album grid"></a>
  <a href="docs/screenshots/album.png"><img src="docs/screenshots/album.png" width="49%" alt="Album page with track list"></a>
  <br>
  <a href="docs/screenshots/now-playing.png"><img src="docs/screenshots/now-playing.png" width="49%" alt="Expanded now playing view"></a>
  <a href="docs/screenshots/playlists.png"><img src="docs/screenshots/playlists.png" width="49%" alt="Playlists and tags"></a>
</p>

<p align="center">
  <img src="docs/screenshots/mobile.png" width="260" alt="beat at phone width">
  <br>
  <em>The same application at phone width.</em>
</p>

## Install

Download the archive for your platform from [Releases](https://github.com/bycruz/beat/releases). The [`nightly`](https://github.com/bycruz/beat/releases/tag/nightly) prerelease contains the newest build.

| Linux | Windows | macOS |
| :---: | :---: | :---: |
| x86-64, arm64 | x86-64, arm64 | Intel, Apple silicon |

Extract the archive. Run `beat` on Linux or macOS. Run `beat.exe` on Windows. The first start asks for a music folder.

The application needs a Vulkan driver. The builds are not code-signed. On macOS, right-click the application and select Open at the first start. On Windows, SmartScreen can show a warning.

**Controls:** `Space` play or pause. `Left` and `Right` seek. `/` search. `Ctrl+,` settings. `Ctrl+O` select a folder.

## Build

Install [lde](https://lde.sh/docs/general/setup/installation). Install a C compiler. Install `glslang` to compile the shaders. Then run these commands:

```sh
lde sync -C packages/beat
lde run -C packages/beat      # run from source
lde compile -C packages/beat  # build one executable
lde test -C packages/beat     # run headless tests
```

## Benchmarks

These values are from a Linux x86-64 computer with an Intel i7-9700F processor. The library is on a Google Drive mount through rclone FUSE. The library contains 539 albums, 4,054 tracks, and 12 GB of data.

| Measurement | Result |
| --- | --- |
| Native executable | 4.1 MB |
| Window, no library | approximately 130 MB RSS, approximately 65 MB PSS |
| Window, full library | approximately 166 MB RSS, approximately 105 MB PSS |
| Scan, 4 inspectors | 2.4 to 3.0 seconds, approximately 60 MB RSS total |
| Scan, 1 inspector | 17.5 seconds, approximately 39 MB RSS |

Scan times use a warm VFS cache. RSS includes shared libraries. PSS divides shared pages across processes. A full library adds approximately 35 MB PSS to an empty window.

## Status

Beat is early software. Only nightly builds are available. Behavior can change. Report bugs and ideas in [Issues](https://github.com/bycruz/beat/issues).
