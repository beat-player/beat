-- How a playlist is shown wherever it appears: its tracks, its mosaic square with initials, the
-- marks for how it fills, and when it was last edited.
local wonderland = require("wonderland")
local utf8 = require("utf8")
local ui = require("beat-ui")
local render = require("beat.app.ui")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local PlaylistArt = {}

---@param app beat.App
---@param playlist beat.Playlist
---@return beat.Track[]
function PlaylistArt.tracks(app, playlist)
	if app.library == nil then return {} end
	return app.taxonomy:playlistTracks(playlist, app.library)
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
		return (cp >= 0x0300 and cp <= 0x036F)
		or (cp >= 0xFE00 and cp <= 0xFE0F)
		or (cp >= 0x1F3FB and cp <= 0x1F3FF)
		or cp == 0x20E3
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
		while at <= #name and name:sub(at, at):match("%s") do at = at + 1 end
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

--- A playlist's square: four evenly spread album pictures behind the playlist's initials. A
--- one-track playlist is one cover, and two or three leave their remaining cells black. The
--- rounded parent clips whatever the cells do, so every playlist has the same outer shape.
---@param app beat.App
---@param tracks beat.Track[]
---@param size number
---@param radius number?
---@param name string
---@return wonderland.Element
function PlaylistArt.art(app, tracks, size, radius, name)
	local theme = app.theme
	local artRadius = radius or theme:radius("sm")
	local picked = PlaylistArt.mosaicTracks(tracks)
	local initials = PlaylistArt.initials(name)
	local badgeSize = math.floor(size * (#initials > 1 and 0.46 or 0.5))
	local fontSize = math.max(10, math.floor(size * (#initials > 1 and 0.32 or 0.38)))
	local badge = div():style(sty():size(badgeSize, badgeSize):radius(badgeSize / 2)
	:offset(math.floor((size - badgeSize) / 2), math.floor((size - badgeSize) / 2))
	:bg(theme:color("bg", 0.72)):align("center"):justify("center"))
	:children(text(initials):style(theme:s():text(fontSize):weight("bold")
	:fg(theme:color("text"))))

	local root = div():style(sty():column():size(size, size):radius(artRadius):bg("#000000"))
	:clip()

	if #picked <= 1 then
		local track = picked[1]
		local album = track ~= nil and app.library ~= nil and app.library:album(track.albumId) or nil
		if album ~= nil then
			---@cast album beat.Album
			root:children({ render.cover(app, album, size, 0)})
		end
		root:children({ badge})
		return root
	end

	local cell = math.floor(size / 2)
	local function cellAt(slot)
		local track = picked[slot]
		local album = track ~= nil and app.library ~= nil and app.library:album(track.albumId) or nil
		if album ~= nil then
			---@cast album beat.Album
			return render.cover(app, album, cell, 0)
		end
		return div():style(sty():size(cell, cell):bg("#000000"))
	end

	root:children({
	div():style(sty():row():h(cell)):children({ cellAt(1), cellAt(2)}),
	div():style(sty():row():h(cell)):children({ cellAt(3), cellAt(4)}),
	badge,
	})
	return root
end

---@param app beat.App
---@param playlist beat.Playlist
---@return wonderland.Element
function PlaylistArt.icons(app, playlist)
	local theme = app.theme
	local children = {}
	if playlist.smart and #playlist.tagIds > 0 then
		children[#children + 1] = ui.icons.element("tag", theme:px(13), theme:color("accent"))
	end
	if playlist.manual then
		children[#children + 1] = ui.icons.element("hand", theme:px(13), theme:color("muted"))
	end
	return div():style(sty():row():w(theme:px(#children * 17)):h(theme:px(16)):gap(theme:px(4))
	:align("center")):children(children)
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
