# beat-ui

The stable UI API beat's plugins build their screens from. beat's own screens use the same
components, so the API a plugin sees is the one the app is drawn with.

```lua
local ui = require("beat-ui")

return {
	name = "my-plugin",
	version = "1.0.0",
	requires = { ["beat-ui"] = "^0.1.0" },
	setup = function(handle)
		handle.page("my-plugin:home", {
			view = function(app, page, window)
				local ctx = app:ui(window)
				return ui.emptyState(ctx, {
					title = "Nothing here yet",
					copy = "A plugin page, drawn with beat-ui.",
					actionLabel = "Search",
					action = { type = "navigate", page = { kind = "search" } },
				})
			end,
		})
	end,
}
```

`beat-ui` never requires `beat`: everything a component needs is in the context. An outside
plugin's bundle may carry its own copy of beat-ui; beat drops that copy in favour of the one the
app ships, so `require("beat-ui")` inside a plugin is the app's version.

## Stability

`beat-ui` follows semantic versioning.

- **Major** — a documented prop, a context field, a context method or a component's documented
  behaviour changes or is removed.
- **Minor** — a component, prop, context field or context method is added.
- **Patch** — a fix that does not change the documented interface.

The version a plugin requires is compared by the plugin loader. A plugin that writes
`requires = { ["beat-ui"] = "^0.1.0" }` is not loaded, and is reported, when the app ships a
version outside that range. `require("beat-ui").version` is the same string.

## Context

`App:ui(window): beat.ui.Context` is built by beat for the window being drawn. Every component
takes it as its first argument. A plugin page or overlay gets the window in its own `view`, so the
usual line is:

```lua
local ctx = app:ui(window)
```

The same object is returned for repeated calls with the same window and state, so a component
does not make its own.

| Field / method | Meaning |
| --- | --- |
| `ctx.theme` | The live theme. `beat.ui.Theme` is documented below. |
| `ctx.assets` | The window's loaded pictures and fonts, or `nil` on a headless screen. |
| `ctx.width` | The window's width in pixels. |
| `ctx.height` | The window's height in pixels. |
| `ctx.contentWidth` | The width a page has inside the shell, its gutters and the scroll bar. |
| `ctx.contentHeight` | The height a page has between the top bar and the player or bottom navigation; a page's scroll limit is its content's height less this. |
| `ctx.mobile` | `true` below the phone breakpoint (760 px at 100% scale). |
| `ctx.focusedId` | The focus id the layout has, or `nil` when nothing is focused. |
| `ctx.accentInk` | The colour that reads on the accent colour. |
| `ctx:color(token, alpha?)` | A theme colour; `alpha` is 0..1 and omitted keeps the token's own. |
| `ctx:px(n)` | `n` scaled by the UI scale, for a length. |
| `ctx:space(n)` | `n` scaled by the UI scale, for spacing. |
| `ctx:type(name)` | A type size in pixels. |
| `ctx:radius(name)` | A corner radius in pixels. |
| `ctx:s()` | A `wonderland.StyleBuilder` in the theme's font family. |
| `ctx:focused(name)` | Whether the layout's focus is on the field with this id. |
| `ctx:panelWidth(max)` | A floating panel's width: `max` in unscaled pixels, no wider than the window less its gutter. |

### Theme

`ctx.theme` is the theme object beat passes. Its documented interface:

| Member | Meaning |
| --- | --- |
| `theme:color(token, alpha?)` | A colour token, or a colour literal passed through. |
| `theme:px(n)`, `theme:space(n)` | Scaled lengths. |
| `theme:type(name)`, `theme:radius(name)` | Scaled type and radius names. |
| `theme:s()` | A style builder in the theme's family. |
| `theme.accentColour`, `theme.accentInk` | The accent and the ink that reads on it. |
| `theme.fontFamily`, `theme.name`, `theme.accent`, `theme.isDark`, `theme.scale` | What the theme is. |

Colour tokens: `bg`, `sidebar`, `surface`, `elevated`, `hover`, `active`, `text`, `muted`,
`faint`, `border`, `overlay`, `scrim`, `skeleton`, `sheen`, `danger`, `success`, `warning`,
`accent`, `accentInk`.

Type names: `xs`, `sm`, `base`, `md`, `lg`, `xl`, `xxl`, `hero`.

Radius names: `sm`, `md`, `lg`, `xl`, `hero`, `full`.

## Components

Every component is a function `ui.<name>(ctx, props)` returning a `wonderland.Element`.

### `ui.button`

```lua
ui.button(ctx, {
	label = "Play",
	onClick = { type = "togglePlay" },
	variant = "primary", -- or "secondary" (default), "quiet"
	width = ctx:px(120), -- optional; the label's own width when absent
	height = ctx:px(36),  -- optional
	icon = "play",        -- optional glyph before the label
})
```

`primary` is the accent-filled action a screen offers once. `secondary` keeps the raised fill and
adds a hairline border, so it reads on a page, a card and an elevated dialog alike. `quiet` has no
fill until the pointer is over it.

### `ui.icon`

```lua
ui.icon(ctx, { name = "play", size = ctx:px(18), colour = ctx:color("text") })
```

`name` is one of: `play`, `pause`, `previous`, `next`, `shuffle`, `repeat`, `repeatOne`, `volume`,
`mute`, `search`, `home`, `library`, `folder`, `chevronLeft`, `chevronRight`, `chevronDown`,
`chevronUp`, `close`, `check`, `settings`, `github`, `tag`, `playlists`, `hand`, `edit`, `add`.

### `ui.iconButton`

```lua
ui.iconButton(ctx, {
	name = "settings",
	size = ctx:px(32),
	onClick = { type = "navigate", page = { kind = "settings" } },
	active = false, -- optional
	-- content = element, -- optional: draw this instead of a glyph
})
```

The round hit area and hover every icon control uses. `content` lets a caller draw its own mark
while keeping the hit area and the hover.

### `ui.field`

```lua
ui.field(ctx, {
	name = "playlistName",
	value = draft,
	placeholder = "Playlist name",
	oninput = function(value) return { type = "draft", value = value } end,
	onsubmit = function() return { type = "create" } end,
	width = 260, -- optional; fills the parent when absent
})
```

A single-line text field. It reads focus from `ctx:focused(name)`, so the caller does not pass
`focused` itself.

### `ui.section`

```lua
ui.section(ctx, { title = "Recently added", action = { type = "navigate", page = { kind = "searchAll" } } })
```

A page heading with an optional "See all" link. The action is the message the link sends.

### `ui.emptyState`

```lua
ui.emptyState(ctx, {
	title = "Nothing here",
	copy = "A sentence about what would put something here.",
	actionLabel = "Choose a folder",
	action = { type = "chooseFolder" },
	icon = "😬", -- optional, instead of the drawn record
})
```

A centred empty screen: an illustration, a title, a wrapped explanation and one primary action.

### `ui.checkbox`

```lua
ui.checkbox(ctx, {
	checked = true,
	onClick = { type = "pluginEnabled", file = "one.lua", enabled = false },
	size = ctx:px(20),   -- optional box size
	target = ctx:px(32), -- optional clickable square
})
```

The box reflects `checked`; the click sends `onClick`. It keeps no state of its own.

### `ui.progressBar`

```lua
ui.progressBar(ctx, {
	value = 0.35,       -- 0..1, clamped; optional
	indeterminate = false, -- optional; draws a moving band while value is nil
	width = 240,        -- optional; fills the parent when absent
	height = ctx:px(4), -- optional
	tone = "accent",    -- optional theme colour token
})
```

A determinate bar is clamped to 0..1. With `indeterminate = true` and no `value`, a moving band
shows work of unknown length. A value that is not a number draws an empty track.

### `ui.card`

```lua
ui.card(ctx, {
	title = "Appearance",
	action = ui.iconButton(ctx, { name = "folder", size = ctx:px(32), onClick = ... }), -- optional
	children = { copy, row },
	width = nil,        -- optional; fills the parent when absent
	height = nil,       -- optional; without it the card fills the height its parent gives it
	padding = ctx:px(18), -- optional
	gap = ctx:px(12),     -- optional
	radius = "md",        -- optional radius name
})
```

The bordered panel Settings and Plugins use. A title, an optional title-row action, then the
children, inside the padding. Pass `height` when the card needs a fixed box; without it the card
fills the height its parent gives it.

### `ui.listRow`

```lua
ui.listRow(ctx, {
	height = ctx:px(42),
	children = { icon, text("A row") },
	onClick = { type = "navigate", page = { kind = "home" } }, -- optional
	width = nil,       -- optional; fills the parent when absent
	gap = ctx:px(10),  -- optional
	padding = ctx:px(10), -- optional horizontal padding
	justify = "start", -- optional: "start", "center" or "space-between"
	active = false,    -- optional current-destination fill
	radius = "sm",     -- optional radius name
})
```

A row with a hover fill and the message a click sends. `active` fills it for the destination the
app is showing.

## What stays in beat

Components that need app data — album covers, track rows, collection heroes, playlist art, the
chrome, the seek bar — are beat's, not beat-ui's. They use beat-ui internally. A plugin that
needs one of them can reach the registered page or draw the app data itself; beat-ui only promises
the pieces above.
