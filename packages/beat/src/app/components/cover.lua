-- An album's picture at a given size, or its first initial while the picture is still decoding.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local cover = {}

-- The letter an album without a picture shows, kept per album: a cover is asked for on every
-- frame, and matching and upper-casing its title each time is a string the frame did not need.
---@type table<beat.Album, string>
local initials = setmetatable({}, { __mode = "k" })

---@param album beat.Album
---@return string
local function initialOf(album)
	local known = initials[album]
	if known == nil then
		local first = album.title:match("^[%z\1-\127\194-\244][\128-\191]*") or ""
		known = first:upper()
		initials[album] = known
	end
	return known
end

---@class beat.components.CoverProps
---@field album beat.Album
---@field size number # Width and height of the square
---@field radius number? # Default 8
---@field glow boolean? # A soft halo in the picture's dominant colour
---@field sheen boolean? # Lightens under the pointer, for a cover that opens something

---@class beat.components.CoverStyles
---@field placeholder wonderland.StyleBuilder
---@field initial wonderland.StyleBuilder
---@field sheen wonderland.StyleBuilder
---@field sheenHover wonderland.StyleBuilder
---@field images table<wonderland.Asset, wonderland.StyleBuilder> # weak keys: released covers fall out

--- The styles one box of a given size and corner radius draws with, made once per theme and mix
--- step. A cover is drawn for every album a page lists, every frame, so building them again per
--- frame is most of what the component costs. A picture's own style is kept beside them, keyed by
--- the asset: the texture it names is the only thing about it that is not the size and the radius.
---@param theme beat.Theme
---@param size number
---@param radius number
---@return beat.components.CoverStyles
local function stylesFor(theme, size, radius)
	local cache = theme:cache()
	---@type table<number, table<number, beat.components.CoverStyles>>?
	local bySize = cache.coverStyles
	if bySize == nil then
		bySize = {}
		cache.coverStyles = bySize
	end
	---@type table<number, beat.components.CoverStyles>?
	local byRadius = bySize[size]
	if byRadius == nil then
		byRadius = {}
		bySize[size] = byRadius
	end
	---@type beat.components.CoverStyles?
	local styles = byRadius[radius]
	if styles ~= nil then return styles end

	styles = {
		placeholder = sty():size(size, size):radius(radius):align("center"):justify("center"):bg(theme:color("elevated")),
		initial = theme:s():text(math.max(12, math.floor(size * 0.28))):weight("bold"):fg(theme:color("muted", 0.8)),
		sheen = sty():size(size, size):radius(radius):offset(0, 0),
		sheenHover = sty():size(size, size):radius(radius):offset(0, 0):bg(theme:color("sheen", 0.14)),
		images = setmetatable({}, { __mode = "k" })
	}
	byRadius[radius] = styles

	return styles
end

---@param styles beat.components.CoverStyles
---@param size number
---@param radius number
---@param asset wonderland.Asset
local function imageStyle(styles, size, radius, asset)
	local style = styles.images[asset]
	if style == nil then
		style = sty():size(size, size):radius(radius):image(asset.texture, asset.uv)
		styles.images[asset] = style
	end
	return style
end

---@param app beat.App
---@param props beat.components.CoverProps
---@return wonderland.Element
function cover.view(app, props)
	local theme = app.services.appearance.theme
	local album, size = props.album, props.size
	-- The scan worker writes each cover into the local cache before its track events arrive, so
	-- decoding these files while the rest of the library is still being scanned is cheap. Covers
	-- fill in as albums appear instead of waiting for the scan to finish.
	local asset = app.services.covers:request(album, size)
	local radius = props.radius or 8
	local styles = stylesFor(theme, size, radius)

	-- A picture is drawn as white times its texture, and white is as bright as a colour goes, so a
	-- brightness on the card cannot lift the art. A veil of light laid over it can. It is a box of
	-- its own because a hover belongs to the box the pointer is in.
	local sheen = nil
	if props.sheen then
		sheen = div():style(styles.sheen):hover(styles.sheenHover)
	end

	if props.glow then
		-- The dominant colour is known once the picture has been decoded into the cache. On the
		-- first frame the cover is a placeholder, so the halo appears with the art.
		local colour = app.services.covers:colourOf(album)
		if colour ~= nil and asset ~= nil then
			-- A halo is the one thing a cover's style cannot be shared with: it names this
			-- album's colour, and a hero is the only place a cover wears one anyway.
			local alpha = 0x66
			local style = sty():size(size, size):radius(radius):image(asset.texture, asset.uv)
			style:shadow(
				0,
				0,
				math.max(12, math.floor(size * 0.24)),
				string.format(
					"#%02x%02x%02x%02x",
					math.floor(colour.r * 255 + 0.5),
					math.floor(colour.g * 255 + 0.5),
					math.floor(colour.b * 255 + 0.5),
					alpha
				)
			)

			local halo = div():style(style)
			if sheen ~= nil then halo:children(sheen) end
			return halo
		end
	end

	if asset ~= nil then
		local art = div():style(imageStyle(styles, size, radius, asset))
		if sheen ~= nil then art:children(sheen) end
		return art
	end

	-- The first character, not the first byte: a title in Japanese or with an accent begins with a
	-- character several bytes long, and its first byte alone draws as a broken glyph.
	local placeholder = div():style(styles.placeholder):children(text(initialOf(album)):style(styles.initial))
	if sheen ~= nil then placeholder:children(sheen) end
	return placeholder
end

return cover
