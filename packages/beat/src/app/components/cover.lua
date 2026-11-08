-- An album's picture at a given size, or its first initial while the picture is still decoding.
local wonderland = require("wonderland")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local cover = {}

---@class beat.components.CoverProps
---@field album beat.Album
---@field size number # Width and height of the square
---@field radius number? # Default 8
---@field glow boolean? # A soft halo in the picture's dominant colour
---@field sheen boolean? # Lightens under the pointer, for a cover that opens something

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
	local style = sty():size(size, size):radius(radius)

	-- A picture is drawn as white times its texture, and white is as bright as a colour goes, so a
	-- brightness on the card cannot lift the art. A veil of light laid over it can. It is a box of
	-- its own because a hover belongs to the box the pointer is in.
	local sheen = nil
	if props.sheen then
		sheen = div()
			:style(sty():size(size, size):radius(radius):offset(0, 0))
			:hover(sty():size(size, size):radius(radius):offset(0, 0):bg(theme:color("sheen", 0.14)))
	end

	if props.glow then
		-- The dominant colour is known once the picture has been decoded into the cache. On the
		-- first frame the cover is a placeholder, so the halo appears with the art.
		local colour = app.services.covers:colourOf(album)
		if colour ~= nil then
			local alpha = 0x66
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
		end
	end

	if asset ~= nil then
		return div():style(style:image(asset.texture, asset.uv)):children({ sheen })
	end

	local initial = album.title:sub(1, 1):upper()

	return div()
		:style(style:align("center"):justify("center"):bg(theme:color("elevated")))
		:children(
			{
				text(initial)
					:style(theme:s():text(math.max(12, math.floor(size * 0.28))):weight("bold"):fg(theme:color("muted", 0.8))),
				sheen
			}
		)
end

return cover
