# Ionicons

The SVG sources are from [Ionicons](https://ionic.io/ionicons) 7.4.0, under the MIT licence in
`LICENSE`. `repeat-one.svg` is derived from `repeat.svg` by adding a `1` in the free centre.

`packages/beat-ui/src/assets/fonts/Ionicons.ttf` is generated from these files: Inkscape converts
the outline icons' strokes to filled paths, then the files are packed as a font. beat-ui's build
script embeds the face as a Lua module, so a compiled binary carries it. To regenerate it, from the
repository root, with Inkscape on the PATH:

```sh
npm install --no-save svgicons2svgfont svg2ttf
node tools/build-icon-font.cjs
```

The font is used through `packages/beat-ui/src/icon.lua`; its `GLYPHS` table, not the SVG names,
holds the mapping from an icon name to its private-use codepoint, and must match the table in
`tools/build-icon-font.cjs`. The beat brand mark in
the top-left of the shell is drawn separately in `packages/beat/src/app/components/logo.lua` and is
not part of Ionicons.
