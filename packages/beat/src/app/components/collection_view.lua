-- One collection is a cover, a title block, and a track table. Albums and playlist pages
-- differ in the words and the one extra control they offer, not in how the page is built.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local render = require("beat.app.components.ui")
local metrics = require("beat.app.components.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local collection = {}

---@param app beat.App
---@param window wonderland.RenderWindow
---@param opts { label: string, icons: wonderland.Element?, cover: fun(size: number): wonderland.Element, coverMenu: fun(x: number, y: number, width: number, height: number, modifiers: any?, windowX: number, windowY: number): any?, title: string, subtitle: string, subtitleAction: any?, meta: string, playAction: any, playIcon: string, shuffleAction: any, addAction: any?, tracks: beat.Track[], trackAction: fun(track: beat.Track, at: number): any, trackIndex: (fun(track: beat.Track, at: number): number)?, empty: wonderland.Element?, titleOnly: boolean? }
---@return wonderland.Element
function collection.page(app, window, opts)
	local theme = app.services.appearance.theme
	local mobile = metrics.mobile(app, window.width)
	local stacked = mobile and window.height >= theme:px(560)
	local content = metrics.contentWidth(app, window.width)
	local coverSize
	if stacked then
		coverSize = math.min(theme:px(150), content)
	elseif mobile then
		coverSize = math.min(theme:px(120), math.floor(content * 0.25))
	else
		coverSize = math.min(theme:px(224), math.floor(content * 0.32))
	end
	local titleSize = theme:type(mobile and "xxl" or "hero")
	local labelHeight = theme:px(16)
	local titleHeight = math.floor(titleSize * 1.25)
	local subtitleHeight = math.floor(theme:type("md") * 1.3)
	local metaHeight = math.floor(theme:type("sm") * 1.3)
	local actionsHeight = theme:px(52)
	local infoHeight = labelHeight + titleHeight + subtitleHeight + metaHeight + actionsHeight
	+theme:px(8) * 4
	local heroHeight = stacked and (coverSize + theme:space(16) + infoHeight)
	or (coverSize + theme:space(mobile and 70 or 90))
	local hasTracks = #opts.tracks > 0
	local rowsHeight = hasTracks and #opts.tracks * theme:px(48)
	or (opts.empty ~= nil and theme:px(120) or 0)
	local trackListHeight = theme:space(20) + (hasTracks and theme:px(34) or 0)
	+rowsHeight + theme:space(24)
	local current = app.services.playback:current()
	local playing = app.services.playback.player:isPlaying()

	local cover = div():style(sty():size(coverSize, coverSize):radius(theme:radius("lg")))
	if opts.coverMenu ~= nil then cover:onContextMenu(opts.coverMenu) end
	cover:children({ opts.cover(coverSize)})

	local labelChildren = {
	text(opts.label):style(theme:s():text(theme:type("xs")):weight("bold"):fg(theme:color("muted"))),
	}
	if opts.icons ~= nil then labelChildren[#labelChildren + 1] = opts.icons end
	local subtitle = text(opts.subtitle):style(theme:s():wrel(1.0):text(theme:type("md"))
	:weight("semibold"):fg(theme:color("text")):ellipsis())
	if opts.subtitleAction ~= nil then subtitle:onClick(opts.subtitleAction) end

	local actions = {
	div():style(sty():size(theme:px(52), theme:px(52)):radius(theme:radius("full")):bg(theme:color("accent"))
	:align("center"):justify("center"))
	:onClick(opts.playAction)
	:children(ui.icons.element(opts.playIcon, theme:px(24), theme.accentInk)),
	render.iconButton(app, "shuffle", theme:px(30), opts.shuffleAction),
	}
	if opts.addAction ~= nil then
		actions[#actions + 1] = render.iconButton(app, "add", theme:px(30), opts.addAction)
	end

	local info = div():style(sty():column():h(stacked and infoHeight or heroHeight)
	:justify("center"):gap(theme:px(8)):wrel(1.0)):children({
	div():style(sty():row():h(theme:px(16)):gap(theme:px(7)):align("center")):children(labelChildren),
	text(opts.title):style(theme:s():text(titleSize):weight("bold")
	:fg(theme:color("text")):ellipsis()),
	subtitle,
	text(opts.meta):style(theme:s():wrel(1.0):text(theme:type("sm"))
	:fg(theme:color("muted")):ellipsis()),
	div():style(sty():row():h(theme:px(52)):gap(theme:px(10)):align("center")):children(actions),
	})
	local hero
	if stacked then
		hero = div():style(sty():column():wrel(1.0):h(heroHeight):gap(theme:space(16))):children({
		div():style(sty():row():wrel(1.0):h(coverSize):justify("center")):children({ cover}),
		info,
		})
	else
		hero = div():style(sty():row():wrel(1.0):h(heroHeight):pad(0, 0, 0, 0)
		:gap(theme:space(28)):align("center")):children({ cover, info})
	end

	local rows = {}
	if hasTracks then
		rows[#rows + 1] = div():style(sty():row():w(content):h(theme:px(34))
		:pad(0, theme:px(10), 0, theme:px(10)):gap(theme:px(12)):align("center")):children({
		text("#"):style(theme:s():w(24):text(theme:type("xs")):weight("bold")
		:fg(theme:color("faint"))),
		text("TITLE"):style(theme:s():w(content - theme:px(122)):text(theme:type("xs"))
		:weight("bold"):fg(theme:color("faint"))),
		text("TIME"):style(theme:s():w(54):text(theme:type("xs")):weight("bold")
		:fg(theme:color("faint"))),
		})
	end

	local trackStart = heroHeight + theme:space(20) + (hasTracks and theme:px(34) or 0)
	local viewport = metrics.viewportHeight(app, window.width, window.height)
	app.services.scroll:setLimit(app:pageKey(),
	math.max(0, heroHeight + trackListHeight + theme:space(20) - viewport))
	local scroll = app.services.scroll:offset(app:pageKey())
	local first, last, top = app.services.scroll.slices(#opts.tracks, 1, theme:px(48),
	math.max(0, scroll - trackStart), viewport)
	---@cast first number
	---@cast last number
	---@cast top number

	if top > 0 then rows[#rows + 1] = div():style(sty():h(top)) end
	for at = first, last do
			local track = opts.tracks[at]
			if track ~= nil then
				local number = opts.trackIndex ~= nil and opts.trackIndex(track, at) or at
				rows[#rows + 1] = render.trackRow(app, track, number,
				current ~= nil and current.id == track.id, playing,
				opts.trackAction(track, at), content, false, opts.titleOnly)
			end
		end
	if #opts.tracks == 0 and opts.empty ~= nil then rows[#rows + 1] = opts.empty end

	return div():style(sty():column():wrel(1.0):h(heroHeight + trackListHeight)):children({
	hero,
	div():style(sty():column():wrel(1.0):h(trackListHeight):pad(theme:space(20), 0, theme:space(24), 0))
	:children(rows),
	})
end

return collection
