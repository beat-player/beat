-- The playlists page: the playlists to open and the tags that make the smart ones. A tag's
-- name is edited in place here, so the draft and the one being edited belong to this page.
local wonderland = require("wonderland")
local core = require("beat-core")
local render = require("beat.app.ui")
local metrics = require("beat.app.metrics")
local measure = require("beat.app.measure")
local PlaylistArt = require("beat.app.playlist_art")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty
local util = core.util

---@class beat.PlaylistsState
---@field tagEditId number? # The tag whose name is being edited in place
---@field tagEditDraft string
---@field hoverTagId number?

---@type beat.PageSurface
local playlists = {}

function playlists.new()
	---@type beat.PlaylistsState
	return { tagEditId = nil, tagEditDraft = "", hoverTagId = nil}
end

function playlists.update(app, page, message)
	local state = page.state --[[@as beat.PlaylistsState]]
	local kind = message.type
	if kind == "editTag" then
		local tag = app.taxonomy.tagById[tonumber(message.id)]
		if tag ~= nil and not tag.hidden then
			state.tagEditId = tag.id
			state.tagEditDraft = tag.name
			app:focusField("tagName", #tag.name)
			app:refresh()
		end
		return true
	elseif kind == "tagEditDraft" then
		state.tagEditDraft = message.value or ""
		app:refresh()
		return true
	elseif kind == "cancelTagEdit" then
		state.tagEditId = nil
		state.tagEditDraft = ""
		app:focusField(nil)
		app:refresh()
		return true
	elseif kind == "renameTag" then
		local tag = app.taxonomy:renameTag(state.tagEditId --[[@as number]], state.tagEditDraft)
		if tag == nil then
			app:toast("Choose a tag name that is not already used", "error")
		else
			app:saveTaxonomy()
			state.tagEditId = nil
			state.tagEditDraft = ""
			app:focusField(nil)
			app:toast("Tag renamed · " .. tag.name)
		end
		app:refresh()
		return true
	elseif kind == "hoverTag" then
		if state.hoverTagId ~= message.id then
			state.hoverTagId = message.id
			app:refresh()
		end
		return true
	elseif kind == "deleteTag" then
		local id = tonumber(message.id)
		local tag = id ~= nil and app.taxonomy.tagById[id] or nil
		if tag ~= nil then
			-- A tag a track uses asks first; an empty one only removes its own list.
			if tag.count > 0 then
				app:open("tag_delete", { id = tag.id})
			else
				app:deleteTag(tag.id)
				app:refresh()
			end
		end
		return true
	elseif kind == "playPlaylist" then
		app:playPlaylist(message.id --[[@as number]], message.shuffle == true)
		app:refresh()
		return true
	end
	return false
end

---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function playlists.view(app, page, window)
	local state = page.state --[[@as beat.PlaylistsState]]
	local theme = app.theme
	local mobile = metrics.mobile(app, window.width)
	local taxonomy = app.taxonomy
	local content = metrics.contentWidth(app, window.width)
	local tags = taxonomy:visibleTags()
	---@cast tags beat.Tag[]

	local headerActions = {
	render.button(app, "New playlist", { type = "open", overlay = "playlist_dialog", smart = false},
	{ primary = true, height = theme:px(30), width = theme:px(128)}),
	render.button(app, "New tag", { type = "open", overlay = "tag_dialog"},
	{ height = theme:px(30), width = theme:px(92)}),
	}
	local headerHeight = theme:px(mobile and 92 or 44)
	local actionRow = div():style(sty():row():wrel(1.0):h(theme:px(30)):gap(theme:px(8))
	:align("center"):justify(mobile and "start" or "end")):children(headerActions)
	local title = text("Playlists"):style(theme:s():wrel(1.0):text(theme:type("xxl")):weight("bold")
	:fg(theme:color("text")):ellipsis())
	local header
	if mobile then
		header = div():style(sty():column():wrel(1.0):h(headerHeight):gap(theme:px(10))):children({
		title,
		actionRow,
		})
	else
		header = div():style(sty():row():wrel(1.0):h(headerHeight):gap(theme:px(8))
		:align("center"):justify("space-between")):children({
		title,
		div():style(sty():row():w(theme:px(230)):h(theme:px(30)):gap(theme:px(8))
		:align("center"):justify("end")):children(headerActions),
		})
	end

	local function playlistRow(playlist)
		local tracks = PlaylistArt.tracks(app, playlist)
		local infoWidth = math.max(theme:px(120), content - theme:px(128))
		local nameStyle = theme:s():text(theme:type("base")):weight("semibold")
		local measured = measure.width(app, playlist.name, nameStyle)
		local fallback = measure.estimate(playlist.name, theme:type("base"), 0.48)
		local nameWidth = math.min(infoWidth - theme:px(50),
		math.max(theme:px(36), math.ceil(math.max(measured or 0, fallback)) + 1))
		local rowStyle = sty():row():wrel(1.0):h(theme:px(72)):pad(0, theme:px(10), 0, theme:px(10))
		:gap(theme:px(12)):align("center"):radius(theme:radius("md")):bg(theme:color("surface"))
		return div():style(rowStyle):hover(sty():row():wrel(1.0):h(theme:px(72)):pad(0,
		theme:px(10), 0, theme:px(10)):gap(theme:px(12)):align("center"):radius(theme:radius("md"))
		:bg(theme:color("hover")))
		:onClick({ type = "navigate", page = { kind = "playlist", id = playlist.id}})
		:onContextMenu(function(_, _, _, _, _, windowX, windowY)
			return { type = "open", overlay = "playlist_menu", id = playlist.id, x = windowX, y = windowY}
		end)
		:children({
		PlaylistArt.art(app, tracks, theme:px(54), nil, playlist.name),
		div():style(sty():column():w(infoWidth):hrel(1.0):justify("center")
		:gap(theme:px(4))):children({
		-- The type marks sit against the end of the name rather than at the far edge of
		-- the row. The estimate only caps an unusually long name; real names measure short.
		div():style(sty():row():wrel(1.0):h(theme:px(18)):gap(theme:px(6)):align("center")):children({
		text(playlist.name):style(theme:s():w(nameWidth)
		:text(theme:type("base")):weight("semibold"):fg(theme:color("text")):ellipsis()),
		PlaylistArt.icons(app, playlist),
		}),
		text(util.count(#tracks, "track") .. " · " .. PlaylistArt.editedLabel(playlist.updatedAt)):style(
		theme:s():wrel(1.0):h(theme:px(16)):text(theme:type("xs"))
		:fg(theme:color("muted")):ellipsis()),
		}),
		render.iconButton(app, "play", theme:px(30), { type = "playPlaylist", id = playlist.id}),
		})
	end

	local rows = {}
	for _, playlist in ipairs(taxonomy.playlists) do rows[#rows + 1] = playlistRow(playlist) end
	if #rows == 0 then
		rows[#rows + 1] = text("No playlists yet. Tags make smart playlists, or make one by hand."):style(
		theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted"))
		)
	end

	-- Tags are pills whose width comes from what is in them, wrapped by hand because the layout
	-- has no wrap container: two short names fit where one long one takes the row.
	local tagRows = {}
	local tagLine = {}
	local lineWidth = 0
	local pillGap = theme:px(8)
	local pillPadLeft = theme:px(10)
	local pillPadRight = theme:px(6)
	local gaps = theme:px(12)
	local pillBorder = theme:px(1)
	local closeWidth = theme:px(mobile and 28 or 22)
	local nameSize = theme:type(mobile and "sm" or "base")

	local function flushTagLine()
		if #tagLine == 0 then return end
		tagRows[#tagRows + 1] = div():style(sty():row():wrel(1.0):h(theme:px(34))
		:gap(pillGap)):children(tagLine)
		tagLine = {}
		lineWidth = 0
	end

	for _, tag in ipairs(tags) do
			local countText = tostring(tag.count)
			local countStyle = theme:s():text(theme:type("xs"))
			local countFallback = math.floor(#countText * theme:type("xs") * 0.7)
			local countWidth = math.max(theme:px(12),
			math.ceil(math.max(measure.width(app, countText, countStyle) or 0, countFallback)) + 1)
			local nameStyle = theme:s():text(nameSize):weight("semibold")
			local nameFallback = measure.estimate(tag.name, nameSize, 0.54)
			local nameWidth = math.max(theme:px(16), math.ceil(
			math.max(measure.width(app, tag.name, nameStyle) or 0, nameFallback)) + 1)
			-- The row break is manual because Wonderland has no wrap container, but each pill's
			-- width comes from the same measured runs the text is drawn with.
			local estimatedWidth = pillPadLeft + pillPadRight + countWidth + nameWidth
			+closeWidth + gaps
			estimatedWidth = math.min(content, math.max(theme:px(64), estimatedWidth))
			nameWidth = math.max(theme:px(16), estimatedWidth - pillPadLeft - pillPadRight
			-countWidth - closeWidth - gaps)

			local editing = state.tagEditId == tag.id
			local pill
			local usedWidth = estimatedWidth
			if editing then
				local editWidth = math.min(content, math.max(estimatedWidth, theme:px(190)))
				usedWidth = editWidth
				local fieldWidth = math.max(theme:px(80),
				editWidth - theme:px(20) - theme:px(24) * 2 - theme:px(8))
				local field = render.field(app, "tagName", state.tagEditDraft, tag.name,
				function(value) return { type = "tagEditDraft", value = value} end,
				function() return { type = "renameTag"} end, fieldWidth)
				pill = div():style(sty():row():w(editWidth):h(theme:px(34)):gap(theme:px(4))
				:pad(0, theme:px(8), 0, theme:px(8)):align("center"):radius(theme:radius("full"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))):children({
				field,
				render.iconButton(app, "check", theme:px(24), { type = "renameTag"}),
				render.iconButton(app, "close", theme:px(22), { type = "cancelTagEdit"}),
				})
			else
				pill = div()
				:style(sty():row():w(estimatedWidth):h(theme:px(34)):gap(theme:px(6))
				:pad(0, pillPadRight, 0, pillPadLeft):align("center"):radius(theme:radius("full"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border")))
				:hover(sty():row():w(estimatedWidth):h(theme:px(34)):gap(theme:px(6))
				:pad(0, pillPadRight, 0, pillPadLeft):align("center"):radius(theme:radius("full"))
				:bg(theme:color("hover")):border(theme:px(1), theme:color("border")))
				:onMouseMove(function() return { type = "hoverTag", id = tag.id} end)
				:children({
				text(countText):style(countStyle:w(countWidth):fg(theme:color("faint")):ellipsis()),
				text(tag.name):style(nameStyle:w(nameWidth):fg(theme:color("text")):ellipsis())
				:onClick({ type = "editTag", id = tag.id}),
				div():style(sty():size(closeWidth, theme:px(mobile and 28 or 22))
				:align("center"):justify("center"))
				:onClick({ type = "deleteTag", id = tag.id})
				:children(text("×"):style(theme:s():text(theme:type("lg")):weight("semibold")
				:fg(theme:color("muted")))),
				})
			end

			if lineWidth > 0 and lineWidth + pillGap + usedWidth > content then flushTagLine() end
			tagLine[#tagLine + 1] = pill
			lineWidth = lineWidth + (lineWidth > 0 and pillGap or 0) + usedWidth
		end
	flushTagLine()
	if #tagRows == 0 then
		tagRows[#tagRows + 1] = text("No tags yet. A tag is also a smart playlist."):style(
		theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted"))
		)
	end

	local playlistHeight = #taxonomy.playlists * theme:px(72)
	+math.max(0, #taxonomy.playlists - 1) * theme:px(8)
	local tagHeight = #tagRows * theme:px(34) + math.max(0, #tagRows - 1) * theme:px(8)
	if #taxonomy.playlists == 0 then playlistHeight = theme:px(20) end
	if #tags == 0 then tagHeight = theme:px(20) end
	local height = headerHeight + playlistHeight + theme:px(24) + tagHeight
	+theme:space(18) * 3 + theme:px(24)

	return div():style(sty():column():wrel(1.0):h(height):gap(theme:space(18))):children({
	header,
	div():style(sty():column():wrel(1.0):h(playlistHeight):gap(theme:px(8))):children(rows),
	render.section(app, "Tags"),
	div():style(sty():column():wrel(1.0):h(tagHeight):gap(theme:px(8))):children(tagRows),
	})
end

return playlists
