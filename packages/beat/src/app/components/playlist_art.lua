-- How a playlist is shown wherever it appears: its tracks, its mosaic square with initials, the
-- marks for how it fills, and when it was last edited.
local wonderland = require("wonderland")
local utf8 = require("utf8")
local ui = require("beat-ui")
local cover = require("beat.app.components.cover")
local styles = require("beat.app.components.helpers.styles")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local PlaylistArt = {}

---@param app beat.App
---@param playlist beat.Playlist
---@return beat.Track[]
function PlaylistArt.tracks(app, playlist)
	return app.services.collections:playlistTracks(playlist)
end

--- One grapheme from a byte offset: a letter, or the whole picture of an emoji -- its variation
--- selector, skin tone, keycap or joined parts included. Initials count pictures, not bytes.
---@param value string
---@param at number
---@return string cluster
---@return number nextAt
local function firstCluster(value, at)
	local codepoint, nextAt = utf8.decode(value, at)
	if codepoint == nil then return "", at end
	local last = nextAt - 1

	local function modifier(cp)
		return (cp >= 0x0300 and cp <= 0x036F) or (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0x1F3FB and cp <= 0x1F3FF) or cp == 0x20E3
	end

	if codepoint >= 0x1F1E6 and codepoint <= 0x1F1FF and nextAt <= #value then
		local following, after = utf8.decode(value, nextAt)
		if following ~= nil and following >= 0x1F1E6 and following <= 0x1F1FF then
			last, nextAt = after - 1, after
		end
	end

	while nextAt <= #value do
		local cp, after = utf8.decode(value, nextAt)
		if cp == nil or not modifier(cp) then break end
		last, nextAt = after - 1, after
	end

	while nextAt <= #value do
		local cp, after = utf8.decode(value, nextAt)
		if cp ~= 0x200D then break end
		local joined, joinedAfter = utf8.decode(value, after)
		if joined == nil then break end
		last, nextAt = joinedAfter - 1, joinedAfter
		while nextAt <= #value do
			local nextCp, nextAfter = utf8.decode(value, nextAt)
			if nextCp == nil or not modifier(nextCp) then break end
			last, nextAt = nextAfter - 1, nextAfter
		end
	end

	return value:sub(at, last), nextAt
end

--- Two initials at most, one per word: Maximum Overdrive is MO. A word that is a single emoji
--- keeps the whole picture, so a playlist called by its emoji is not cut in half.
---@param name string
---@return string
function PlaylistArt.initials(name)
	local initials = {}
	local at = 1
	while at <= #name and #initials < 2 do
		while at <= #name and name:sub(at, at):match("%s") do at += 1 end
		if at > #name then break end

		local cluster, nextAt = firstCluster(name, at)
		if cluster ~= "" then
			if #cluster == 1 then cluster = cluster:upper() end
			initials[#initials + 1] = cluster
		end
		at = nextAt
		while at <= #name and not name:sub(at, at):match("%s") do
			local _, after = firstCluster(name, at)
			if after <= at then break end
			at = after
		end
	end
	return table.concat(initials)
end

--- Four tracks spread across the playlist, repeated when the playlist is shorter than four, so
--- the mosaic has the same weight whether it holds four songs or one.
---@param tracks beat.Track[]
---@return beat.Track[]
function PlaylistArt.mosaicTracks(tracks)
	local picked = {}
	local count = #tracks
	if count <= 4 then
		for at = 1, count do picked[at] = tracks[at] end
		return picked
	end
	for slot = 1, 4 do
		local offset = math.floor((slot - 1) * (count - 1) / 3 + 0.5)
		picked[slot] = tracks[math.min(count, 1 + offset)]
	end
	return picked
end

---@class beat.components.PlaylistArtProps
---@field tracks beat.Track[] # The playlist's tracks, in order
---@field size number # The square's width and height
---@field radius number? # Default theme:radius("sm")
---@field name string # The playlist's name, reduced to its initials
---@field ui beat.ui.Context

--- The mosaic's rows and square at one size, kept per size and corner radius.
---@class beat.components.PlaylistArtGridStyles
---@field radius number?
---@field row wonderland.StyleBuilder
---@field column wonderland.StyleBuilder

--- The badge and the square around it, kept per size and the shape of the initials.
---@class beat.components.PlaylistArtStyles
---@field fontSize number
---@field radius number
---@field badge wonderland.StyleBuilder
---@field badgeText wonderland.StyleBuilder
---@field root wonderland.StyleBuilder
---@field empty wonderland.StyleBuilder

--- The black cell of a mosaic with fewer than four pictures, kept per cell size.
---@class beat.components.PlaylistArtCellStyles
---@field radius number?
---@field style wonderland.StyleBuilder

--- Four separately rounded cells in two rows, a small gap between them: the square a mosaic is
--- drawn into. Each cell is built by `cell`, which gets the slot it fills and the size and corner
--- radius it should draw at.
---@param app beat.App
---@param cell fun(slot: number, size: number, radius: number): wonderland.Element # builds the cell for slot 1..4
---@param size number
---@param radius number
---@return wonderland.Element
function PlaylistArt.grid(app, cell, size, radius)
	local theme = app.services.appearance.theme
	local gap = math.max(1, math.floor(size * 0.02))
	local cellSize = math.floor((size - gap) / 2)
	local cellRadius = math.min(radius, math.floor(cellSize * 0.15))

	-- The rows and the square are the same for every frame at this size: kept rather than made
	-- again, because the sidebar around a scrolling page is built again with it.
	local kept = styles.of(theme, "playlistArtGrid", size) --[[@as beat.components.PlaylistArtGridStyles]]
	if kept.radius ~= radius then
		kept.radius = radius
		kept.row = sty():row():h(cellSize):gap(gap)
		kept.column = sty():column():size(size, size):gap(gap)
	end

	local function row(from)
		return div():style(kept.row):children(
			cell(from, cellSize, cellRadius),
			cell(from + 1, cellSize, cellRadius)
		)
	end

	return div():style(kept.column):children(row(1), row(3))
end

--- A playlist's square: four evenly spread album pictures behind the playlist's initials. A
--- one-track playlist is one cover, and two or three leave their remaining cells black. The cells
--- sit apart with corners of their own, so no rounded clip slices the covers they hold.
---@param app beat.App
---@param props beat.components.PlaylistArtProps
---@return wonderland.Element
function PlaylistArt.view(app, props)
	local tracks, size, name = props.tracks, props.size, props.name
	local theme = app.services.appearance.theme
	local artRadius = props.radius or theme:radius("sm")
	local picked = PlaylistArt.mosaicTracks(tracks)
	local initials = PlaylistArt.initials(name)
	local badgeSize = math.floor(size * (#initials > 1 and 0.46 or 0.5))
	local fontSize = math.max(10, math.floor(size * (#initials > 1 and 0.32 or 0.38)))

	-- The badge, the square it sits in and the cells of the mosaic are the same for every frame at
	-- this size, and the sidebar holding them is built again on every scroll step: kept rather than
	-- made again. A playlist with one initial wears a bigger badge than one with two, so the two
	-- shapes have a record of their own rather than taking turns at one.
	local variants = styles.of(theme, "playlistArt", size) --[[@as table<number, beat.components.PlaylistArtStyles?>]]
	local kept = variants[badgeSize]
	if kept == nil or kept.fontSize ~= fontSize or kept.radius ~= artRadius then
		local inset = math.floor((size - badgeSize) / 2)
		kept = {
			fontSize = fontSize,
			radius = artRadius,
			badge = sty()
				:size(badgeSize, badgeSize):radius(badgeSize / 2)
				:offset(inset, inset):bg(theme:color("bg", 0.72))
				:align("center"):justify("center"),
			badgeText = theme:s():text(fontSize):weight("bold"):fg(theme:color("text")),
			root = sty():size(size, size),
			empty = sty():size(size, size):radius(artRadius):bg("#000000")
		}
		variants[badgeSize] = kept
	end

	local badge = div():style(kept.badge):children(text(initials):style(kept.badgeText))

	local root = div():style(kept.root)

	local library = app.services.library.current
	if #picked <= 1 then
		local track = picked[1]
		local album = track ~= nil and library ~= nil ? (library:album(track.albumId)) : nil
		if album ~= nil then
			root:children({ cover.view(app, { album = album, size = size, radius = artRadius }) })
		else
			root:children({ div():style(kept.empty) })
		end
		root:children({ badge })
		return root
	end

	local function cellAt(slot, cellSize, cellRadius)
		local track = picked[slot]
		local album = track ~= nil and library ~= nil ? (library:album(track.albumId)) : nil
		if album ~= nil then
			return cover.view(app, { album = album, size = cellSize, radius = cellRadius })
		end
		local cells = styles.of(theme, "playlistArtCell", cellSize) --[[@as beat.components.PlaylistArtCellStyles]]
		if cells.radius ~= cellRadius then
			cells.radius = cellRadius
			cells.style = sty():size(cellSize, cellSize):radius(cellRadius):bg("#000000")
		end
		return div():style(cells.style)
	end

	root:children({ PlaylistArt.grid(app, cellAt, size, artRadius), badge })
	return root
end

---@class beat.components.PlaylistIconsProps
---@field playlist beat.Playlist
---@field ui beat.ui.Context

---@param app beat.App
---@param props beat.components.PlaylistIconsProps
---@return wonderland.Element
function PlaylistArt.icons(app, props)
	local playlist = props.playlist
	local theme = app.services.appearance.theme
	local ctx = props.ui
	local children = {}
	if playlist.smart and #playlist.tagIds > 0 then
		children[#children + 1] = ui.icon(ctx, { name = "tag", size = theme:px(13), colour = theme:color("accent") })
	end
	if playlist.manual then
		children[#children + 1] = ui.icon(ctx, { name = "hand", size = theme:px(13), colour = theme:color("muted") })
	end
	return div()
		:style(sty():row():w(theme:px(#children * 17)):h(theme:px(16)):gap(theme:px(4)):align("center")):children(children)
end

---@param at number
---@return string
function PlaylistArt.editedLabel(at)
	if at == nil or at <= 0 then return "Never edited" end
	local now = os.date("*t")
	local then_ = os.date("*t", at)
	if now.year == then_.year and now.month == then_.month and now.day == then_.day then
		return "Edited today"
	end
	return "Edited " .. os.date("%b %d", at)
end

return PlaylistArt
