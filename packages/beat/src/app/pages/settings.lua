-- The settings screen: theme, accent, scale, motion, sidebar, the folder the library is read from,
-- Last.fm and the About section.
local wonderland = require("wonderland")
local path = require("path")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local button = require("beat.app.components.button")
local volume = require("beat.app.components.volume")
local metrics = require("beat.app.components.helpers.metrics")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local GITHUB = "https://github.com/bycruz/beat"

---@type beat.PageSurface
local settings = {}

---@param app beat.App
---@param page beat.PageInstance
---@param window wonderland.RenderWindow
---@return wonderland.Element
function settings.view(app, page, window)
	local theme = app.services.appearance.theme

	local function section(title, copy, rows, height)
		local content = {
		text(title):style(theme:s():text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
		text(copy):style(theme:s():wrel(1.0):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
		}
		for _, row in ipairs(rows) do content[#content + 1] = row end

		return div():style(sty():column():wrel(1.0):h(theme:px(height)):gap(theme:space(12))
		:pad(theme:space(18)):radius(theme:radius("md")):bg(theme:color("surface"))
		:border(theme:px(1), theme:color("border"))):children(content)
	end

	local themeChips = {}
	local narrowTheme = window.width < 560
	for _, name in ipairs(ui.theme.names()) do
			themeChips[#themeChips + 1] = button.view(app, {
			label = name:sub(1, 1):upper() .. name:sub(2),
			onClick = { type = "theme", name = name},
			primary = app.services.settings.values.theme == name,
			height = theme:px(30),
			width = theme:px(narrowTheme and 120 or 92),
			})
		end
	local themeRow
	if narrowTheme then
		themeRow = div():style(sty():column():h(theme:px(106)):gap(theme:px(8))):children(themeChips)
	else
		themeRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8))):children(themeChips)
	end

	local accents = {}
	for _, name in ipairs(ui.theme.accents()) do
			local active = app.services.settings.values.accent == name
			accents[#accents + 1] = div()
			:style(sty():size(theme:px(narrowTheme and 20 or 28), theme:px(narrowTheme and 20 or 28))
			:radius(theme:radius("full"))
			:bg(ui.theme.accentColour(name))
			:align("center"):justify("center"))
			:onClick({ type = "accent", name = name})
			:children(active and ui.icons.element("check", theme:px(14), ui.theme.accentInk(name)) or div())
		end
	local accentRow = div():style(sty():row():h(theme:px(narrowTheme and 20 or 28))
	:gap(theme:px(narrowTheme and 5 or 8))):children(accents)

	local customButton = div()
	:style(sty():row():w(theme:px(110)):h(theme:px(32)):radius(theme:radius("full"))
	:bg("#000000"):border(theme:px(1), theme:color("border"))
	:align("center"):justify("center"))
	:onClick({ type = "open", overlay = "accent_picker"})
	:children(text("Custom"):style(theme:s():text(theme:type("sm")):weight("semibold")
	:fg("#f4f6f9")))
	local customRow = div():style(sty():row():h(theme:px(32)):align("center")):children({ customButton})

	local scaleRow = div():style(sty():row():h(theme:px(32))
	:gap(theme:px(narrowTheme and 4 or 8)):align("center")):children({
	text("Scale"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
	button.view(app, {
	label = "90%",
	onClick = { type = "uiScale", value = 0.9},
	height = theme:px(28),
	width = theme:px(narrowTheme and 38 or 60),
	primary = app.services.settings.values.uiScale == 0.9,
	}),
	button.view(app, {
	label = "100%",
	onClick = { type = "uiScale", value = 1},
	height = theme:px(28),
	width = theme:px(narrowTheme and 40 or 62),
	primary = app.services.settings.values.uiScale == 1,
	}),
	button.view(app, {
	label = "125%",
	onClick = { type = "uiScale", value = 1.25},
	height = theme:px(28),
	width = theme:px(narrowTheme and 40 or 62),
	primary = app.services.settings.values.uiScale == 1.25,
	}),
	})

	local motionRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center")):children({
	text("Motion"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
	button.view(app, {
	label = app.services.settings.values.reduceMotion and "Motion reduced" or "Reduce motion",
	onClick = { type = "reduceMotion", value = not app.services.settings.values.reduceMotion},
	height = theme:px(28),
	width = theme:px(narrowTheme and 130 or 150),
	primary = app.services.settings.values.reduceMotion,
	}),
	})

	local mobileSidebar = metrics.mobile(app, window.width)
	local sidebarControls = {
	text(mobileSidebar and "Hidden on phones" or "Width"):style(theme:s():text(theme:type("sm"))
	:fg(theme:color("muted"))),
	}
	if mobileSidebar then
		-- The phone shell uses bottom tabs; sidebar width has no meaning there.
	elseif window.width >= 1040 then
		sidebarControls[#sidebarControls + 1] = button.view(app, {
		label = "Narrow",
		onClick = { type = "sidebarWidth", width = 220},
		height = theme:px(28),
		width = theme:px(74),
		primary = app.services.settings.values.sidebarWidth == 220,
		})
		sidebarControls[#sidebarControls + 1] = button.view(app, {
		label = "Balanced",
		onClick = { type = "sidebarWidth", width = 264},
		height = theme:px(28),
		width = theme:px(86),
		primary = app.services.settings.values.sidebarWidth == 264,
		})
		sidebarControls[#sidebarControls + 1] = button.view(app, {
		label = "Wide",
		onClick = { type = "sidebarWidth", width = 320},
		height = theme:px(28),
		width = theme:px(64),
		primary = app.services.settings.values.sidebarWidth == 320,
		})
		sidebarControls[#sidebarControls + 1] = button.view(app, {
		label = app.services.settings.values.sidebarCollapsed and "Expand" or "Collapse",
		onClick = { type = "toggleSidebar"},
		height = theme:px(28),
		width = theme:px(76),
		primary = app.services.settings.values.sidebarCollapsed,
		})
	else
		sidebarControls[#sidebarControls + 1] = text("Icon rail below 1040 px"):style(
		theme:s():text(theme:type("xs")):fg(theme:color("faint"))
		)
	end
	local sidebarRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"))
	:children(sidebarControls)

	local libraryRows = {
	text(app.services.settings.values.root or "No folder chosen"):style(theme:s():text(theme:type("sm"))
	:fg(theme:color("muted")):ellipsis()),
	(function()
		local buttons = {
		button.view(app, {
		label = "Choose folder…",
		onClick = { type = "chooseFolder"},
		primary = true,
		height = theme:px(32),
		width = theme:px(narrowTheme and 160 or 150),
		}),
		button.view(app, {
		label = "Rescan",
		onClick = { type = "rescan"},
		height = theme:px(32),
		width = theme:px(narrowTheme and 160 or 90),
		}),
		}
		if narrowTheme then
			return div():style(sty():column():h(theme:px(72)):gap(theme:px(8))):children(buttons)
		end
		return div():style(sty():row():h("auto"):gap(theme:px(8))):children(buttons)
	end)(),
	}
	local scan = app.services.scan
	if scan.skipped > 0 then
		libraryRows[#libraryRows + 1] = text(format.count(scan.skipped, "file") .. " skipped"):style(
		theme:s():text(theme:type("xs")):fg(theme:color("danger"))
		)
		for at, failure in ipairs(scan.errors) do
				if at > 3 then break end
				libraryRows[#libraryRows + 1] = text(path.basename(failure.path) .. " · " .. failure.message):style(
				theme:s():text(theme:type("xs")):fg(theme:color("muted")):ellipsis()
				)
			end
	end

	local audioRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(12)):align("center")):children({
	text("Volume"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
	volume.view(app, { width = theme:px(narrowTheme and 80 or 200) }),
	text(tostring(math.floor((app.services.settings.values.isMuted and 0 or app.services.settings.values.volume) * 100)) .. "%"):style(
	theme:s():text(theme:type("xs")):fg(theme:color("faint"))
	),
	})

	local lastfm = app.services.lastfm.client
	local lastfmTone = lastfm:statusTone()
	local lastfmColour = lastfmTone == "success" and theme:color("success")
	or (lastfmTone == "danger" and theme:color("danger") or theme:color("muted"))
	local lastfmButton
	local lastfmActionWidth
	if lastfm:isConnected() then
		lastfmActionWidth = theme:px(narrowTheme and 92 or 110)
		lastfmButton = button.view(app, {
		label = "Disconnect",
		onClick = { type = "lastfmDisconnect"},
		height = theme:px(28),
		width = lastfmActionWidth,
		})
	elseif lastfm:isAuthorizing() then
		lastfmActionWidth = theme:px(narrowTheme and 78 or 88) + theme:px(6) + theme:px(70)
		lastfmButton = div():style(sty():row():h(theme:px(28)):gap(theme:px(6))):children({
		button.view(app, {
		label = "Open page",
		onClick = { type = "lastfmOpenAuth"},
		height = theme:px(28),
		width = theme:px(narrowTheme and 78 or 88),
		}),
		button.view(app, {
		label = "Cancel",
		onClick = { type = "lastfmCancel"},
		height = theme:px(28),
		width = theme:px(70),
		}),
		})
	else
		lastfmActionWidth = theme:px(narrowTheme and 84 or 96)
		lastfmButton = button.view(app, {
		label = "Connect",
		onClick = { type = "lastfmConnect"},
		primary = true,
		height = theme:px(28),
		width = lastfmActionWidth,
		})
	end

	local lastfmStatusWidth = math.max(theme:px(80),
	metrics.contentWidth(app, window.width) - theme:space(18) * 2 - lastfmActionWidth - theme:px(10))
	local lastfmStatusRow = div():style(sty():row():wrel(1.0):h(theme:px(28)):gap(theme:px(10))
	:align("center")):children({
	text(lastfm:statusText()):style(theme:s():w(lastfmStatusWidth):text(theme:type("xs"))
	:fg(lastfmColour):ellipsis()),
	lastfmButton,
	})

	local lastfmToggleRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8)):align("center"))
	:children({
	text("Scrobbling"):style(theme:s():text(theme:type("sm")):fg(theme:color("muted"))),
	button.view(app, {
	label = app.services.settings.values.lastfmEnabled and "Enabled" or "Paused",
	onClick = { type = "lastfmEnabled", value = not app.services.settings.values.lastfmEnabled},
	height = theme:px(28),
	width = theme:px(narrowTheme and 76 or 88),
	primary = app.services.settings.values.lastfmEnabled,
	}),
	})

	local lastfmRows = { lastfmStatusRow, lastfmToggleRow}
	local lastfmHeight = 176

	local githubButtons = {
	button.view(app, {
	label = "GitHub",
	onClick = { type = "openURL", url = GITHUB},
	icon = "github",
	primary = true,
	height = theme:px(32),
	width = theme:px(narrowTheme and 160 or 124),
	}),
	button.view(app, {
	label = "Issues",
	onClick = { type = "openURL", url = GITHUB .. "/issues"},
	height = theme:px(32),
	width = theme:px(narrowTheme and 160 or 92),
	}),
	}
	local githubRow
	if narrowTheme then
		githubRow = div():style(sty():column():h(theme:px(72)):gap(theme:px(8))):children(githubButtons)
	else
		githubRow = div():style(sty():row():h(theme:px(32)):gap(theme:px(8))):children(githubButtons)
	end

	local appearanceHeight = (narrowTheme and 342 or 268) + 32 + 12
	local libraryHeight = (narrowTheme and 210 or 170)
	+(scan.skipped > 0 and (12 + math.min(#scan.errors, 3) * 16) or 0)
	local aboutHeight = narrowTheme and 196 or 156
	return div():style(sty():column():wrel(1.0):h(theme:px(32 + appearanceHeight + 136 + libraryHeight
	+134 + lastfmHeight + aboutHeight + 6 * 16 + 24))
	:gap(theme:space(16))):children({
	text("Settings"):style(theme:s():text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))),
	section("Appearance", "Theme, accent, custom colour, scale and motion.",
	{ themeRow, accentRow, customRow, scaleRow, motionRow}, appearanceHeight),
	section("Sidebar", "Width and rail behaviour.", { sidebarRow}, 136),
	section("Library", "Where the library is read from.", libraryRows, libraryHeight),
	section("Audio", "Output volume.", { audioRow}, 134),
	section("Last.fm", "Authorize your account to send now-playing updates and scrobbles.", lastfmRows,
	lastfmHeight),
	section("About", "beat 0.1 · local files only · wonderland + treble · Ionicons", {
	githubRow,
	}, aboutHeight),
	})
end

return settings
