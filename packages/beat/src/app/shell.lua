-- The screen around a page: the sidebar, the top bar, the player bar, the scan cards and the
-- toasts, with the page in the middle and the open overlays over all of it. A full-screen overlay
-- is the whole screen instead. Views are functions of state and window; they return elements and
-- messages, and never change the app themselves.
local wonderland = require("wonderland")
local cache = require("beat-ui.cache")
local logo = require("beat.app.components.logo")
local metrics = require("beat.app.components.helpers.metrics")
local sidebar = require("beat.app.components.chrome.sidebar")
local topbar = require("beat.app.components.chrome.topbar")
local playerBar = require("beat.app.components.chrome.player_bar")
local mobileNav = require("beat.app.components.chrome.mobile_nav")
local scanStatus = require("beat.app.components.chrome.scan_status")
local toasts = require("beat.app.components.chrome.toasts")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local shell = {}

-- A page slide has the same handful of positions every time. They are made once per scale and
-- picked from, rather than made from the frame's exact progress: a style is interned by its
-- values, so asking for one per frame is asking the arena to grow with every transition.
---@type table<number, { forward: wonderland.StyleBuilder[], back: wonderland.StyleBuilder[] }>
local transitionCache = {}
local TRANSITION_STEPS = 16

-- The performance overlay's surface is drawn without being opened, so it is handed the state it
-- would have had: one table for every frame, rather than one made to be thrown away.
---@type beat.OverlayInstance
local DEBUG_OVERLAY = { name = "debug", state = {} }

---@param theme beat.Theme
local function transitionStyles(theme)
	local cached = transitionCache[theme.scale]
	if cached ~= nil then return cached end

	local forward, back = {}, {}
	for at = 0, TRANSITION_STEPS do
		local t = at / TRANSITION_STEPS
		local distance = (1 - t) * theme:px(28)
		local dim = 0.88 + 0.12 * t
		forward[at] = sty():fill():column():offset(distance, 0):bright(dim)
		back[at] = sty():fill():column():offset(-distance, 0):bright(dim)
	end

	cached = { forward = forward, back = back }
	transitionCache[theme.scale] = cached
	return cached
end

---@param elements wonderland.Element[]
---@param element wonderland.Element?
local function addElement(elements, element)
	if element ~= nil then elements[#elements + 1] = element end
end

--- The open overlays from `from` up, bottom first. An anchored overlay is drawn by the screen
--- that opened it, at the button that opened it, and a full-screen one is the screen itself.
---@param app beat.App
---@param window wonderland.RenderWindow
---@param from number
local function overlays(app, window, from)
	---@type wonderland.Element[]
	local elements = {}
	for at = from, #app.overlays do
		local overlay = app.overlays[at]
		local surface = app.registry:overlay(overlay.name)
		if not surface.anchored and not surface.fullscreen and surface.view ~= nil then
			addElement(elements, surface.view(app, overlay, window))
		end
	end
	return elements
end

-- The messages the frame's own boxes send -- the page scroller, and the pointer moving off a
-- playlist row. They read the app, not the numbers of the frame that drew them, so they are made
-- once per app: wonderland is handed the same function on every repaint.
---@class beat.ShellHandlers
---@field scroll fun(by: number?, to: number?): any
---@field leavePlaylist fun(): any

---@type table<beat.App, beat.ShellHandlers>
local handlers = setmetatable({}, { __mode = "k" })

--- The page scroller of one app: the key of the page it is showing, and how far it has moved.
---@param app beat.App
---@return fun(by: number?, to: number?): any
local function scrollHandler(app)
	return |by, to| -> { type = "scroll", key = app:pageKey(), by = by, to = to }
end

--- The pointer leaving a playlist row of one app: the name it was showing goes away.
---@param app beat.App
---@return fun(): any
local function leavePlaylistHandler(app)
	return function()
		if app.services.sidebar.hover ~= nil then return { type = "hoverPlaylist", id = nil } end
		return nil
	end
end

---@param app beat.App
---@return beat.ShellHandlers
local function handlersOf(app)
	local set = handlers[app]
	if set == nil then
		set = { scroll = scrollHandler(app), leavePlaylist = leavePlaylistHandler(app) }
		handlers[app] = set
	end
	return set --[[@as beat.ShellHandlers]]
end

--- The styles the shell's own boxes draw with. `cache.of` keeps one record per set of values: the
--- body's height and the page's padding, the rail's width, the top bar's height.
---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function fillStyle(ctx)
	return sty():fill()
end

---@param ctx beat.ui.Context
---@return wonderland.StyleBuilder
local function rootStyle(ctx)
	return sty():fill():column():bg(ctx:color("bg")):fg(ctx:color("text")):font(ctx.theme.fontFamily)
end

---@param ctx beat.ui.Context
---@param bodyHeight number
---@param pad number
---@param top number # Room above the first of the content: none under a pinned header, which has its own
---@return wonderland.StyleBuilder
local function pageBodyStyle(ctx, bodyHeight, pad, top)
	return sty()
		:column():wrel(1.0):h(bodyHeight):pad(top, pad, 0, pad):gap(ctx:space(18))
		:bar(ctx:px(8), ctx:px(40), ctx:color("faint"))
end

--- The box a page's pinned header sits in: the page's own top margin above it and a gap below.
---@param ctx beat.ui.Context
---@param height number # The header's own height
---@param pad number
---@return wonderland.StyleBuilder
local function pageHeaderStyle(ctx, height, pad)
	return sty():column():wrel(1.0):h(ctx:space(20) + height + ctx:space(12)):pad(ctx:space(20), pad, ctx:space(12), pad)
end

---@param ctx beat.ui.Context
---@param bodyHeight number
---@return wonderland.StyleBuilder
local function clipStyle(ctx, bodyHeight)
	return sty():column():wrel(1.0):h(bodyHeight)
end

---@param ctx beat.ui.Context
---@param pageHeight number
---@param rightWidth number
---@param topInset number # The status bar, which a phone's page starts under
---@return wonderland.StyleBuilder
local function mainStyle(ctx, pageHeight, rightWidth, topInset)
	local style = sty():column():w(rightWidth):h(pageHeight)
	if topInset > 0 then style:pad(topInset, 0, 0, 0) end
	return style
end

---@param ctx beat.ui.Context
---@param pageHeight number
---@return wonderland.StyleBuilder
local function frameStyle(ctx, pageHeight)
	return sty():row():wrel(1.0):h(pageHeight)
end

-- What the chrome pieces are asked for, written again each frame: they read it and keep nothing,
-- and the screen is built on every frame it scrolls.
---@type table<string, any>
local chromeProps = {}

-- Where the shadow of a bottom bar falls: the scan cards and the tooltip are placed above the
-- chrome rather than inside the page's scroll.
--- The root's layers, bottom first: the frame, then the phone's player bar and tabs (or the
-- desktop's tooltip), then the scan cards. Split out of `shell.view` so the trace that builds the
-- page does not also carry every bar, and the bars' own traces stay short.
---@param app beat.App
---@param mobile boolean
---@param bar number
---@param width number
---@param height number
---@param pageHeight number
---@param uiCtx beat.ui.Context
---@param frame wonderland.Element
---@return wonderland.Element
local function rootView(app, mobile, bar, width, height, pageHeight, uiCtx, frame)
	local rootChildren = { frame }
	if mobile then
		if bar > 0 then
			chromeProps.width, chromeProps.ui = width, uiCtx
			rootChildren[#rootChildren + 1] = playerBar.mobile(app, chromeProps --[[@as beat.components.chrome.PlayerBarProps]])
		end
		chromeProps.width, chromeProps.ui = width, uiCtx
		rootChildren[#rootChildren + 1] = mobileNav.view(app, chromeProps --[[@as beat.components.chrome.MobileNavProps]])
	elseif bar > 0 then
		chromeProps.width, chromeProps.ui = width, uiCtx
		rootChildren[#rootChildren + 1] = playerBar.view(app, chromeProps --[[@as beat.components.chrome.PlayerBarProps]])
	end
	chromeProps.width, chromeProps.ui = width, uiCtx
	local scanIsland = scanStatus.island(app, chromeProps --[[@as beat.components.chrome.ScanStatusProps]])
	if scanIsland ~= nil then rootChildren[#rootChildren + 1] = scanIsland end
	chromeProps.width, chromeProps.ui = width, uiCtx
	local scanSummary = scanStatus.summary(app, chromeProps --[[@as beat.components.chrome.ScanStatusProps]])
	if scanSummary ~= nil then rootChildren[#rootChildren + 1] = scanSummary end
	if not mobile then
		chromeProps.width, chromeProps.height, chromeProps.ui = width, height, uiCtx
		local tooltip = sidebar.tooltip(app, chromeProps --[[@as beat.components.chrome.SidebarTooltipProps]])
		if tooltip ~= nil then rootChildren[#rootChildren + 1] = tooltip end
	end

	local rootBox = cache.of(uiCtx, rootStyle, "shellRoot") --[[@as wonderland.StyleBuilder]]
	return div():style(rootBox):children(rootChildren)
end

---@param app beat.App
---@param window wonderland.RenderWindow
---@return wonderland.Element
function shell.view(app, window)
	local theme = app.services.appearance.theme
	local assets = app.assets
	if assets ~= nil then app.services.covers:use(assets) end
	app.services.covers:beginFrame()

	local width = window.width
	local height = window.height
	local mobile = metrics.mobile(app, width)
	local uiCtx = app:ui(window)
	local bar = (app.services.playback:current()) ~= nil ? (theme:px(mobile ? 64 : 88)) : 0
	local page = app:currentPage()
	local send = handlersOf(app)

	-- A full-screen overlay is the screen, not a panel over one: the page, the sidebar and the bar
	-- are not built at all, so nothing underneath can be clicked through and nothing around the
	-- edges is left showing. What was opened over it is drawn over it.
	for at = #app.overlays, 1, -1 do
		local overlay = app.overlays[at]
		local surface = app.registry:overlay(overlay.name)
		if surface.fullscreen and surface.view ~= nil then
			-- The screen itself may be padded, but overlays are placed in window coordinates. A
			-- bare wrapper keeps their fill and offsets measured from the window.
			local fill = cache.of(uiCtx, fillStyle, "shellFill") --[[@as wonderland.StyleBuilder]]
			local frame = div():style(fill):children({ surface.view(app, overlay, window) })
			for _, element in ipairs(overlays(app, window, at + 1)) do frame:children({ element }) end
			app.services.covers:sweep()
			return frame
		end
	end

	if app.services.scan:needsFolder() then
		-- The first launch is the folder browser and nothing else; it is the page, too, so its
		-- messages reach it.
		if page.kind ~= "folders" then
			app.page = app:pageFor({ kind = "folders" })
			app:persistPage()
			page = app.page
		end
		return div():style(sty():fill():column():bg(theme:color("bg")):fg(theme:color("text")):font(theme.fontFamily)):children({
			div():style(sty():fill():column():align("center"):justify("center")):children({
				div():style(sty():w(math.min(theme:px(620), width - metrics.pad(app, width) * 2)):h(theme:px(600)):column():gap(theme:space(18))):children({
					div():style(sty():row():h(theme:px(28)):gap(theme:px(10)):align("center")):children({
						logo.view(app, { size = theme:px(28), colour = theme:color("accent") }),
						text("beat"):style(theme:s():text(theme:type("xxl")):weight("bold"):fg(theme:color("text")))
					}),
					app.registry:page("folders").view(app, page, window)
				})
			})
		})
	end

	local surface = app.registry:page(page.kind)
	local content = surface.view(app, page, window)
	local header, headerHeight = nil, 0
	if surface.header ~= nil then header, headerHeight = surface.header(app, page, window) end

	local bottomHeight = metrics.bottomHeight(app, width)
	local pageHeight = height - bottomHeight
	local topbarHeight = metrics.topbarHeight(app, width)
	local bodyHeight = pageHeight - topbarHeight
	local pad = metrics.pad(app, width)
	local scroll = app.services.scroll:offset(app:pageKey())

	local motion = app.services.motion
	local transitionStyle
	local t = motion:slideProgress(wonderland.time.now())
	local slide = motion.pageSlide
	if t ~= nil and slide ~= nil and not motion.clock.reduce then
		local transitionSet = transitionStyles(theme)
		local direction = (slide.direction or 1) < 0 and transitionSet.back or transitionSet.forward
		transitionStyle = direction[math.floor(t * 16 + 0.5)]
	end

	-- The body's box is the window's height less the bars and the page's padding: every frame of a
	-- resize or a page that scrolls asks for the same one again. A page with a pinned header gives
	-- that header the top of the box, and only what is under it scrolls.
	local headerBox = header ~= nil and metrics.headerBox(app, headerHeight) or 0
	local bodyStyle = cache.of(uiCtx, pageBodyStyle, "shellPageBody", bodyHeight - headerBox, pad, header ~= nil and 0 or theme:space(20)) --[[@as wonderland.StyleBuilder]]

	local pageBody = div():style(bodyStyle):scroll(scroll):onScroll(send.scroll):children({ content })
	if header ~= nil then
		local headerStyle = cache.of(uiCtx, pageHeaderStyle, "shellPageHeader", headerHeight, pad) --[[@as wonderland.StyleBuilder]]
		local column = cache.of(uiCtx, clipStyle, "shellPageColumn", bodyHeight) --[[@as wonderland.StyleBuilder]]
		pageBody = div():style(column):children({ div():style(headerStyle):children({ header }), pageBody })
	end

	-- The page is moved by a wrapper whose styles are made once per scale, not by a style that
	-- names the frame's exact position: a style is interned by its values, and interning a new
	-- one every frame is what made repeated transitions slower and slower.
	local moving = transitionStyle == nil and pageBody or div():style(transitionStyle):children({ pageBody })

	-- Clipped so a page arriving from the side cannot draw over the sidebar during its travel.
	local clip = cache.of(uiCtx, clipStyle, "shellPageClip", bodyHeight) --[[@as wonderland.StyleBuilder]]
	local pageClip = div():style(clip):scroll(0):onScroll(send.scroll):children({ moving })

	local rightWidth = width - metrics.sidebarWidth(app, width)
	local topInset = mobile and metrics.topbarInset(app, width) or 0
	local mainBox = cache.of(uiCtx, mainStyle, "shellMain", pageHeight, rightWidth, topInset) --[[@as wonderland.StyleBuilder]]
	local main = div():style(mainBox)
	if not mobile then main:onMouseMove(send.leavePlaylist) end
	local inner = cache.of(uiCtx, clipStyle, "shellBody", bodyHeight) --[[@as wonderland.StyleBuilder]]
	local body = div():style(inner):children({ pageClip })
	-- A phone has no top bar: the page begins under the status bar, and the back gesture is the
	-- system's rather than a chevron's. A desktop keeps the bar with its search field and settings.
	if mobile then
		main:children({ body })
	else
		main:children({ topbar.view(app, { width = width, ui = uiCtx }), body })
	end

	local shellChildren = { main }
	if not mobile then
		table.insert(shellChildren, 1, sidebar.view(app, { width = width, height = pageHeight, ui = uiCtx }))
	end
	local frameBox = cache.of(uiCtx, frameStyle, "shellFrame", pageHeight) --[[@as wonderland.StyleBuilder]]
	local frame = div():style(frameBox):children(shellChildren)

	local root = rootView(app, mobile, bar, width, height, pageHeight, uiCtx, frame)

	-- The performance overlay is a plugin, so the shell draws nothing for it unless it is loaded:
	-- a switch in Settings takes it out of the app at the next start. It is added under the toasts
	-- and the panels, so the numbers never cover a message or a menu.
	if app.registry:hasPlugin("debug") then
		local surface = app.registry:overlay("debug")
		if surface.view ~= nil then root:children({ surface.view(app, DEBUG_OVERLAY, window) }) end
	end

	local toastLayer = toasts.view(app, { window = window })
	if toastLayer ~= nil then root:children(toastLayer) end

	for _, overlay in ipairs(overlays(app, window, 1)) do root:children({ overlay }) end

	-- Everything this view asked for is kept; covers a changing page no longer asks for are
	-- given back before the next frame, so a scan cannot accumulate one texture per album.
	app.services.covers:sweep()

	return root
end

return shell
