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
---@return wonderland.StyleBuilder
local function pageBodyStyle(ctx, bodyHeight, pad)
	return sty()
		:column():wrel(1.0):h(bodyHeight):pad(ctx:space(20), pad, 0, pad):gap(ctx:space(18))
		:bar(ctx:px(8), ctx:px(40), ctx:color("faint"))
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
---@return wonderland.StyleBuilder
local function mainStyle(ctx, pageHeight, rightWidth)
	return sty():column():w(rightWidth):h(pageHeight)
end

---@param ctx beat.ui.Context
---@param pageHeight number
---@return wonderland.StyleBuilder
local function frameStyle(ctx, pageHeight)
	return sty():row():wrel(1.0):h(pageHeight)
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

	local content = app.registry:page(page.kind).view(app, page, window)

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
	-- resize or a page that scrolls asks for the same one again.
	local bodyStyle = cache.of(uiCtx, pageBodyStyle, "shellPageBody", bodyHeight, pad) --[[@as wonderland.StyleBuilder]]

	local pageBody = div():style(bodyStyle):scroll(scroll):onScroll(send.scroll):children({ content })

	-- The page is moved by a wrapper whose styles are made once per scale, not by a style that
	-- names the frame's exact position: a style is interned by its values, and interning a new
	-- one every frame is what made repeated transitions slower and slower.
	local moving = transitionStyle == nil and pageBody or div():style(transitionStyle):children({ pageBody })

	-- Clipped so a page arriving from the side cannot draw over the sidebar during its travel.
	local clip = cache.of(uiCtx, clipStyle, "shellPageClip", bodyHeight) --[[@as wonderland.StyleBuilder]]
	local pageClip = div():style(clip):scroll(0):onScroll(send.scroll):children({ moving })

	local rightWidth = width - metrics.sidebarWidth(app, width)
	local mainBox = cache.of(uiCtx, mainStyle, "shellMain", pageHeight, rightWidth) --[[@as wonderland.StyleBuilder]]
	local main = div():style(mainBox)
	if not mobile then main:onMouseMove(send.leavePlaylist) end
	local inner = cache.of(uiCtx, clipStyle, "shellBody", bodyHeight) --[[@as wonderland.StyleBuilder]]
	main:children({ topbar.view(app, { width = width, ui = uiCtx }), div():style(inner):children({ pageClip }) })

	local shellChildren = { main }
	if not mobile then
		table.insert(shellChildren, 1, sidebar.view(app, { width = width, height = pageHeight, ui = uiCtx }))
	end
	local frameBox = cache.of(uiCtx, frameStyle, "shellFrame", pageHeight) --[[@as wonderland.StyleBuilder]]
	local frame = div():style(frameBox):children(shellChildren)

	local rootChildren = { frame }
	if mobile then
		if bar > 0 then rootChildren[#rootChildren + 1] = playerBar.mobile(app, { width = width, ui = uiCtx }) end
		rootChildren[#rootChildren + 1] = mobileNav.view(app, { width = width, ui = uiCtx })
	elseif bar > 0 then
		rootChildren[#rootChildren + 1] = playerBar.view(app, { width = width, ui = uiCtx })
	end
	local scanIsland = scanStatus.island(app, { width = width, ui = uiCtx })
	if scanIsland ~= nil then rootChildren[#rootChildren + 1] = scanIsland end
	local scanSummary = scanStatus.summary(app, { width = width, ui = uiCtx })
	if scanSummary ~= nil then rootChildren[#rootChildren + 1] = scanSummary end
	if not mobile then
		local tooltip = sidebar.tooltip(app, { width = width, height = height, ui = uiCtx })
		if tooltip ~= nil then rootChildren[#rootChildren + 1] = tooltip end
	end

	local rootBox = cache.of(uiCtx, rootStyle, "shellRoot") --[[@as wonderland.StyleBuilder]]
	local root = div():style(rootBox):children(rootChildren)

	local toastLayer = toasts.view(app, { window = window })
	if toastLayer ~= nil then root:children(toastLayer) end

	for _, overlay in ipairs(overlays(app, window, 1)) do root:children({ overlay }) end

	-- Everything this view asked for is kept; covers a changing page no longer asks for are
	-- given back before the next frame, so a scan cannot accumulate one texture per album.
	app.services.covers:sweep()

	return root
end

return shell
