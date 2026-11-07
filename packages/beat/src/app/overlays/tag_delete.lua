-- The one destructive tag action asks first: a tag that has never been put on a track goes
-- straight away, but one that has is also what its automatic playlist is built from. The
-- dialog says how many tracks are involved before anything is removed.
local wonderland = require("wonderland")
local format = require("beat.app.components.format")
local metrics = require("beat.app.components.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.TagDeleteState
---@field id number

---@type beat.OverlaySurface
local tagDelete = {}

---@param params { id: number }
function tagDelete.new(app, params)
	local tag = params.id ~= nil and app.services.collections.taxonomy.tagById[params.id] or nil
	if tag == nil then return nil end
	---@type beat.TagDeleteState
	return { id = tag.id}
end

function tagDelete.update(app, overlay, message)
	local state = overlay.state --[[@as beat.TagDeleteState]]
	local kind = message.type
	if kind == "confirmDeleteTag" then
		-- The page that asked clears what it was keeping about the tag: its row's hover and the
		-- name field if it was being edited. The search service drops the tag from its filter
		-- when collections announce the change.
		local page = app.page
		if page ~= nil and page.kind == "playlists" then
			page = app:currentPage()
			if page.state.tagEditId == state.id then
				page.state.tagEditId = nil
				page.state.tagEditDraft = ""
				app:focusField(nil)
			end
			if page.state.hoverTagId == state.id then page.state.hoverTagId = nil end
		end
		app.services.collections:deleteTag(state.id)
		app:close(overlay)
		app:refresh()
		return true
	elseif kind == "cancelDeleteTag" then
		app:close(overlay)
		app:refresh()
		return true
	end
	return false
end

function tagDelete.view(app, overlay, window)
	local state = overlay.state --[[@as beat.TagDeleteState]]
	local tag = app.services.collections.taxonomy.tagById[state.id]
	if tag == nil then return nil end

	local theme = app.services.appearance.theme
	local panelWidth = metrics.panelWidth(app, window, 380)
	local pad = theme:px(18)
	local panelHeight = theme:px(154)

	local cancelStyle = sty():w(theme:px(80)):h(theme:px(30)):radius(theme:radius("full"))
	:align("center"):justify("center"):bg(theme:color("surface"))
	:border(theme:px(1), theme:color("border"))
	local cancelHover = sty():w(theme:px(80)):h(theme:px(30)):radius(theme:radius("full"))
	:align("center"):justify("center"):bg(theme:color("hover"))
	:border(theme:px(1), theme:color("border"))
	local deleteStyle = sty():w(theme:px(88)):h(theme:px(30))
	:radius(theme:radius("full")):align("center"):justify("center"):bg(theme:color("danger"))
	local deleteHover = sty():w(theme:px(88)):h(theme:px(30))
	:radius(theme:radius("full")):align("center"):justify("center"):bg(theme:color("danger"))
	:bright(1.08)

	local panel = div()
	:style(sty():w(panelWidth):h(panelHeight):column():pad(pad):gap(theme:px(10))
	:radius(theme:radius("lg")):bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
	:shadow(0, theme:px(16), theme:px(42), "#00000080"))
	:onClick({ type = "keep"})
	:children({
	text("Delete “" .. tag.name .. "”?"):style(theme:s():wrel(1.0):text(theme:type("lg"))
	:weight("bold"):fg(theme:color("text")):ellipsis()),
	text("It is used on " .. format.count(tag.count, "track") .. "."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	text("Its automatic playlist will be deleted too."):style(
	theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
	div():style(sty():row():wrel(1.0):h(theme:px(32)):gap(theme:px(8)):align("center")
	:justify("end")):children({
	div():style(cancelStyle):hover(cancelHover):onClick({ type = "cancelDeleteTag"})
	:children(text("Cancel"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("text")))),
	div():style(deleteStyle):hover(deleteHover):onClick({ type = "confirmDeleteTag"})
	:children(text("Delete"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg(theme:color("bg")))),
	}),
	})

	return div():style(sty():fill():offset(0, 0):z(124):column():align("center"):justify("center")
	:bg(theme:color("overlay"))):onClick({ type = "cancelDeleteTag"}):children({ panel})
end

return tagDelete
