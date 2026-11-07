-- The tags on the track that is playing, as toggles. Clicking the dark area dismisses it;
-- clicking the panel itself does not.
local wonderland = require("wonderland")
local button = require("beat.app.components.button")
local tagPills = require("beat.app.components.tag_pills")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.TagPickerState
---@field trackId number

---@type beat.OverlaySurface
local tagPicker = {}

---@param params { id: number? }
function tagPicker.new(app, params)
	local track = params.id ~= nil and app.services.library.current ~= nil
	and app.services.library.current:track(params.id) or app.services.playback:current()
	if track == nil then return nil end
	---@type beat.TagPickerState
	return { trackId = track.id}
end

function tagPicker.update(app, overlay, message)
	local state = overlay.state --[[@as beat.TagPickerState]]
	if message.type == "toggleTrackTag" then
		local track = app.services.library.current ~= nil
		and app.services.library.current:track(state.trackId) or app.services.playback:current()
		if track ~= nil then
			app.services.collections.taxonomy:toggleTag(track.path, message.id)
			app.services.collections:save()
			app:refresh()
		end
		return true
	end
	return false
end

function tagPicker.view(app, overlay, window)
	local state = overlay.state --[[@as beat.TagPickerState]]
	local track = app.services.library.current ~= nil
	and app.services.library.current:track(state.trackId) or app.services.playback:current()
	if track == nil then return nil end
	local theme = app.services.appearance.theme
	local tags = app.services.collections.taxonomy:visibleTags()
	local selected = {}
	local assigned = app.services.collections.taxonomy.byPath[track.path]
	if assigned ~= nil then
		for id in pairs(assigned) do selected[id] = true end
	end

	local panelWidth = metrics.panelWidth(app, window, 380)
	local pad = theme:px(18)
	local content = panelWidth - pad * 2
	local pills = tagPills.view(app, {
	tags = tags,
	selected = selected,
	action = function(tag)
		return { type = "toggleTrackTag", id = tag.id}
	end,
	width = content,
	columns = 2,
	})

	local children = {
	text("Tags on this track"):style(theme:s():text(theme:type("lg")):weight("bold")
	:fg(theme:color("text"))),
	text(track.title):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted"))
	:ellipsis()),
	}
	if pills ~= nil then children[#children + 1] = pills
	else children[#children + 1] = text("No tags yet. Create one to start grouping this track."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted"))
	) end
	children[#children + 1] = div():style(sty():row():h(theme:px(32)):gap(theme:px(8))
	:align("center"):justify("end")):children({
	button.view(app, {
	label = "New tag",
	onClick = { type = "open", overlay = "tag_dialog"},
	height = theme:px(30),
	width = theme:px(92),
	}),
	})
	local pillRows = math.max(1, math.min(8, #tags))
	local pillsHeight = pills ~= nil and (math.ceil(pillRows / 2) * theme:px(28)
	+math.max(0, math.ceil(pillRows / 2) - 1) * theme:px(8)
	+(#tags > 8 and theme:px(18) or 0)) or theme:px(20)
	local panelHeight = pad * 2 + theme:px(24) + theme:px(20) + pillsHeight + theme:px(32)
	+theme:px(10) * 3

	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(10)):radius(theme:radius("lg"))
	:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "keep"})
	:children(children)

	return div():style(sty():fill():offset(0, 0):z(115):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "dismiss"}):children({ panel})
end

return tagPicker
