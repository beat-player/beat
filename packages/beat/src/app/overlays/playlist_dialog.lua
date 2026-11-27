-- A new playlist: a name first, then -- only if wanted -- the tags whose songs join it by
-- themselves. Songs can always be added by hand later, so nothing past the name is required.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local tagPills = require("beat.app.components.tag_pills")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.PlaylistDialogState
---@field smart boolean
---@field name string
---@field tagIds table<number, boolean>
---@field match "all"|"any"

---@class beat.PlaylistDialogOverlay: beat.OverlaySurface
local playlistDialog = {}

---@param params { smart: boolean? }
---@param app beat.App
function playlistDialog.new(app, params)
	app:close("tag_picker")
	app:close("tag_dialog")
	app:close("playlist_picker")
	-- The caret goes in as soon as the dialog opens, so typing the name is the next thing.
	app:focusField("playlistName")
	---@type beat.PlaylistDialogState
	return { smart = params.smart == true, name = "", tagIds = {}, match = "all" }
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistDialogState>
function playlistDialog.close(app, overlay)
	app:focusField(nil)
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistDialogState>
---@param message beat.Message
function playlistDialog.update(app, overlay, message)
	local state = overlay.state
	if message.type == "playlistDraft" then
		state.name = message.value or ""
		app:refresh()
		return true
	elseif message.type == "playlistDraftTag" then
		if message.id ~= nil then
			if state.tagIds[message.id] then
				state.tagIds[message.id] = nil
			else
				state.tagIds[message.id] = true
			end
			app:refresh()
		end
		return true
	elseif message.type == "playlistDraftMatch" then
		state.match = message.value == "any" ? "any" : "all"
		app:refresh()
		return true
	elseif message.type == "createPlaylist" then
		local tagIds = {}
		for id in pairs(state.tagIds) do tagIds[#tagIds + 1] = id end
		table.sort(tagIds)
		local playlist = app.services.collections.taxonomy:addPlaylist(
			state.name,
			#tagIds > 0,
			tagIds,
			state.match,
			{ manual = true }
		)
		if playlist == nil then
			app.services.toasts:show("Choose a playlist name", "error")
		else
			app.services.collections:save()
			app:close(overlay)
			app.services.toasts:show("Playlist created · " .. playlist.name)
		end
		app:refresh()
		return true
	end
	return false
end

--- The All/Any choice for two or more tags, as one control split in two.
---@param app beat.App
---@param match "all"|"any"
---@param width number
---@param height number
---@return wonderland.Element
local function matchControl(app, match, width, height)
	local theme = app.services.appearance.theme
	local inset = theme:px(3)
	local half = math.floor((width - inset * 2) / 2)
	local function option(label, value)
		local chosen = match == value
		return div()
			:style(
				sty()
					:w(half):h(height - inset * 2):radius(theme:radius("full")):align("center"):justify("center")
					:bg(chosen ? (theme:color("hover")) : "#00000000")
			)
			:onClick({ type = "playlistDraftMatch", value = value })
			:children(
				text(label)
					:style(theme:s():text(theme:type("sm")):weight("semibold"):fg(chosen ? (theme:color("text")) : (theme:color("muted"))))
			)
	end
	return div()
		:style(
			sty()
				:row():w(width):h(height):pad(inset):radius(theme:radius("full")):align("center")
				:border(theme:px(1), theme:color("border"))
		)
		:children({ option("Has all tags", "all"), option("Has any tag", "any") })
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.PlaylistDialogState>
---@param window wonderland.RenderWindow
function playlistDialog.view(app, overlay, window)
	local state = overlay.state
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local tags = app.services.collections.taxonomy:visibleTags()
	local panelWidth = ctx:panelWidth(440)
	local pad = theme:px(20)
	local content = panelWidth - pad * 2
	local gap = theme:px(14)

	---@type wonderland.Element[]
	local children = {}
	local height = 0
	local function add(element, elementHeight)
		if #children > 0 then height += gap end
		children[#children + 1] = element
		height += elementHeight
	end

	local muted = theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()

	add(text("New playlist"):style(theme:s():h(theme:px(26)):text(theme:type("lg")):weight("bold"):fg(theme:color("text"))), theme:px(26))
	add(
		ui.field(
			ctx,
			{
				name = "playlistName",
				value = state.name,
				placeholder = "Playlist name",
				oninput = |value| -> { type = "playlistDraft", value = value },
				onsubmit = || -> { type = "createPlaylist" }
			}
		),
		theme:px(34)
	)

	if #tags > 0 then
		local labelHeight = theme:px(20)
		local helpHeight = theme:px(18)
		add(
			div()
				:style(sty():column():wrel(1.0):h(labelHeight + theme:px(2) + helpHeight):gap(theme:px(2)))
				:children(
					{
						div()
							:style(sty():row():wrel(1.0):h(labelHeight):gap(theme:px(8)):align("center"))
							:children(
								{
									text("Fill from tags"):style(theme:s():text(theme:type("base")):weight("semibold"):fg(theme:color("text"))),
									text("optional"):style(theme:s():text(theme:type("xs")):fg(theme:color("faint")))
								}
							),
						text("Songs with these tags join it by themselves."):style(muted)
					}
				),
			labelHeight + theme:px(2) + helpHeight
		)

		local columns = metrics.mobile(app, window.width) ? 2 : 3
		local tagRows = math.ceil(#tags / columns)
		add(
			assert(tagPills.view(
				app,
				{
					tags = tags,
					selected = state.tagIds,
					action = |tag| -> { type = "playlistDraftTag", id = tag.id },
					width = content,
					columns = columns
				}
			)),
			tagRows * theme:px(28) + math.max(0, tagRows - 1) * theme:px(8)
		)

		local picked = 0
		for _ in pairs(state.tagIds) do picked += 1 end
		-- All or any only means something once there are two tags to combine.
		if picked >= 2 then
			add(matchControl(app, state.match, math.min(content, theme:px(280)), theme:px(34)), theme:px(34))
		end
	end

	add(text("Add songs by hand from any song's menu, too."):style(muted:h(theme:px(18))), theme:px(18))

	-- Create is quiet until there is a name to create the playlist with.
	local named = state.name:match("%S") ~= nil
	add(
		div()
			:style(sty():row():wrel(1.0):h(theme:px(38)):gap(theme:px(8)):align("center"):justify("end"))
			:children(
				{
					ui.button(ctx, { label = "Cancel", onClick = { type = "dismiss" }, variant = "quiet", height = theme:px(36), width = theme:px(84) }),
					ui.button(
						ctx,
						{
							label = "Create",
							onClick = named and { type = "createPlaylist" } or { type = "keep" },
							variant = named and "primary" or "secondary",
							height = theme:px(36),
							width = theme:px(96)
						}
					)
				}
			),
		theme:px(38)
	)

	local panel = div()
		:style(
			sty()
				:w(panelWidth):h(pad * 2 + height):column():pad(pad):gap(gap):radius(theme:radius("lg"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(16), theme:px(42), "#00000080")
		):onClick({ type = "keep" }):children(children)

	return div()
		:style(sty():fill():offset(0, 0):z(120):column():align("center"):justify("center"):bg(theme:color("overlay")))
		:children({ panel })
end

return playlistDialog
