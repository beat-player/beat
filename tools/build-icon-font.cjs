#!/usr/bin/env node
// Regenerates packages/beat-ui/src/assets/fonts/Ionicons.ttf from the Ionicons SVGs in
// packages/beat/assets/ionicons.
//
// The face belongs to beat-ui's icon component (src/icon.lua), which embeds it in a Lua module so
// a compiled binary carries it. The codepoint table below must match the GLYPHS table in that
// component.
//
//   npm install --no-save svgicons2svgfont svg2ttf
//   node tools/build-icon-font.cjs
//
// Ionicons outlines use both filled paths and strokes. Inkscape converts the strokes to filled
// paths first, so the generated face has every icon as a single outline; the app then draws the
// glyph with its text renderer and colours it from the theme. Only the SVGs that actually paint a
// stroke go through Inkscape: a filled icon (the Ionicons default, and all the metadata marks)
// contains no stroke and is used as-is, so a fill-only set needs no Inkscape at all.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { SVGIcons2SVGFontStream } = require("svgicons2svgfont");
const svg2ttf = require("svg2ttf");

const root = path.resolve(__dirname, "..");
const source = path.join(root, "packages", "beat", "assets", "ionicons");
const output = path.join(root, "packages", "beat-ui", "src", "assets", "fonts", "Ionicons.ttf");

const icons = [
	["play", 0xE000, "play"],
	["pause", 0xE001, "pause"],
	["previous", 0xE002, "material-skip-previous"],
	["next", 0xE003, "material-skip-next"],
	["shuffle", 0xE004, "shuffle"],
	["repeat", 0xE005, "repeat"],
	["repeatOne", 0xE006, "repeat-one"],
	["volume", 0xE007, "volume-high"],
	["mute", 0xE008, "volume-mute"],
	["search", 0xE009, "search"],
	["home", 0xE00A, "home"],
	["library", 0xE00B, "library"],
	["folder", 0xE00C, "folder"],
	["chevronLeft", 0xE00D, "chevron-back"],
	["chevronRight", 0xE00E, "chevron-forward"],
	["chevronDown", 0xE00F, "chevron-down"],
	["chevronUp", 0xE010, "chevron-up"],
	["close", 0xE011, "close"],
	["check", 0xE012, "checkmark"],
	["settings", 0xE013, "settings-outline"],
	["github", 0xE015, "logo-github"],
	["tag", 0xE016, "pricetag"],
	["playlists", 0xE017, "material-library-music"],
	["hand", 0xE018, "hand-left"],
	["edit", 0xE019, "pencil"],
	["add", 0xE01A, "add"],
	["star", 0xE01B, "star"],
	["starOutline", 0xE01C, "star-outline"],
	["queue", 0xE01D, "list"],
	["person", 0xE01E, "person"],
	["people", 0xE01F, "people"],
	["disc", 0xE020, "disc"],
	["calendar", 0xE021, "calendar"],
	["musicalNote", 0xE022, "musical-note"],
	["listNumber", 0xE023, "list"],
];

const converted = fs.mkdtempSync(path.join(os.tmpdir(), "beat-icons-"));

// An SVG paints a stroke when it has a stroke attribute other than "none"; only those need
// Inkscape's object-stroke-to-path. Filled icons are copied straight through.
const paintsStroke = (svg) => /stroke\s*=\s*"(?!none")/.test(svg);

for (const [, , file] of icons) {
	const sourcePath = path.join(source, `${file}.svg`);
	const convertedPath = path.join(converted, `${file}.svg`);
	if (fs.existsSync(convertedPath)) continue;
	const svg = fs.readFileSync(sourcePath, "utf8");
	if (!paintsStroke(svg)) {
		fs.copyFileSync(sourcePath, convertedPath);
		continue;
	}
	try {
		execFileSync("inkscape", [
			sourcePath,
			"--export-type=svg",
			`--export-filename=${convertedPath}`,
			"--actions=select-all;object-stroke-to-path",
		], { stdio: "ignore" });
	} catch (error) {
		if (error.code === "ENOENT") {
			throw new Error(`${file}.svg paints a stroke, so it needs Inkscape on the PATH: ${error.message}`);
		}
		throw error;
	}
}

const font = new SVGIcons2SVGFontStream({
	fontName: "Ionicons",
	normalize: true,
	centerHorizontally: true,
	centerVertically: true,
	fontHeight: 1000,
	descent: 0,
});

const chunks = [];
font.on("data", (chunk) => chunks.push(chunk));
font.on("error", (error) => { throw error; });

for (const [name, codepoint, file] of icons) {
	const glyph = fs.createReadStream(path.join(converted, `${file}.svg`));
	glyph.metadata = { unicode: [String.fromCodePoint(codepoint)], name };
	font.write(glyph);
}

font.on("end", () => {
	const svg = chunks.join("");
	const ttf = svg2ttf(svg, { fontName: "Ionicons", version: "1.0" });
	fs.mkdirSync(path.dirname(output), { recursive: true });
	fs.writeFileSync(output, Buffer.from(ttf.buffer));
	fs.rmSync(converted, { recursive: true, force: true });
	console.log(`wrote ${path.relative(root, output)} (${ttf.buffer.byteLength} bytes)`);
});

font.end();
