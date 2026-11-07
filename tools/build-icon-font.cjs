#!/usr/bin/env node
// Regenerates ../beat-ui/src/assets/fonts/Ionicons.ttf from the Ionicons SVGs in assets/ionicons.
//
// The face belongs to beat-ui, which embeds it in a Lua module so a compiled binary carries it.
//
//   npm install --no-save svgicons2svgfont svg2ttf
//   node tools/build-icon-font.cjs
//
// Ionicons outlines use both filled paths and strokes. Inkscape converts the strokes to filled
// paths first, so the generated face has every icon as a single outline; the app then draws the
// glyph with its text renderer and colours it from the theme.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { SVGIcons2SVGFontStream } = require("svgicons2svgfont");
const svg2ttf = require("svg2ttf");

const root = path.resolve(__dirname, "..");
const source = path.join(root, "assets", "ionicons");
const output = path.join(root, "..", "beat-ui", "src", "assets", "fonts", "Ionicons.ttf");

const icons = [
	["play", 0xE000, "play"],
	["pause", 0xE001, "pause"],
	["previous", 0xE002, "play-skip-back"],
	["next", 0xE003, "play-skip-forward"],
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
	["playlists", 0xE017, "list"],
	["hand", 0xE018, "hand-left"],
	["edit", 0xE019, "pencil"],
	["add", 0xE01A, "add"],
];

const converted = fs.mkdtempSync(path.join(os.tmpdir(), "beat-icons-"));

for (const [, , file] of icons) {
	execFileSync("inkscape", [
		path.join(source, `${file}.svg`),
		"--export-type=svg",
		`--export-filename=${path.join(converted, `${file}.svg`)}`,
		"--actions=select-all;object-stroke-to-path",
	], { stdio: "ignore" });
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
