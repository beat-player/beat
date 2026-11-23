-- The settings screen: theme, accent, scale, motion, the window, sidebar, the folder the library is
-- read from, volume, Last.fm, the plugins page and the About section, as rows in grouped lists.
local wonderland = require("wonderland")
local path = require("path")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local volume = require("beat.app.components.volume")
local metrics = require("beat.app.components.helpers.metrics")
local settingsList = require("beat.app.components.settings_list")
local version = require("beat.version")

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
	local ctx = app:ui(window)
	local values = app.services.settings.values
	local narrow = window.width < 560
	local content = metrics.contentWidth(app, window.width)
	local column = settingsList.columnWidth(app, content)
	local inner = column - theme:px(32)
	local stacked = settingsList.stacked(app, column)

	-- A segmented choice is drawn at the width its labels ask for, and fills the room the row
	-- leaves when that is wider than the row can give it.
	---@param options beat.components.SettingsOption[]
	---@return wonderland.Element
	---@return number
	local function segmented(options)
		local element, width = settingsList.segmented(app, { options = options })
		local limit = stacked and inner or (inner - theme:px(80) - theme:px(16))
		if width > limit then
			element, width = settingsList.segmented(app, { options = options, width = limit })
		end
		return element, width
	end

	local themeOptions = {}
	for _, name in ipairs(app.services.appearance:names()) do
		themeOptions[#themeOptions + 1] = {
			label = name == "auto" ? "Auto" : (name:sub(1, 1):upper() .. name:sub(2)),
			message = { type = "theme", name = name },
			selected = values.theme == name
		}
	end
	local themeControl, themeWidth = segmented(themeOptions)

	-- The accent swatches and the Custom button share one control, so the row can put them beside
	-- the words or under them as a single piece.
	local accentSize = theme:px(narrow ? 20 : 28)
	local accentGap = theme:px(narrow ? 5 : 8)
	local customWidth = theme:px(110)
	local accentNames = app.services.appearance:accents()
	local accentWidth = #accentNames * accentSize + #accentNames * accentGap + customWidth
	if accentWidth > inner then
		accentSize = theme:px(18)
		accentGap = theme:px(4)
		accentWidth = #accentNames * accentSize + #accentNames * accentGap + customWidth
	end

	local accents = {}
	for _, name in ipairs(accentNames) do
		local active = values.accent == name
		accents[#accents + 1] = div()
			:style(
				sty()
					:size(accentSize, accentSize):radius(theme:radius("full"))
					:bg(app.services.appearance:accentColour(name)):align("center"):justify("center")
			):onClick({ type = "accent", name = name })
			:children(
				active ? ui.icon(ctx, { name = "check", size = theme:px(14), colour = app.services.appearance:accentInk(name) }) : div()
			)
	end
	local customButton = div()
		:style(
			sty()
				:row():w(customWidth):h(theme:px(32)):radius(theme:radius("full")):bg("#000000")
				:border(theme:px(1), theme:color("border")):align("center"):justify("center")
		):onClick({ type = "open", overlay = "accent_picker" })
		:children(text("Custom"):style(theme:s():text(theme:type("sm")):weight("semibold"):fg("#f4f6f9")))
	accents[#accents + 1] = customButton
	local accentControl = div()
		:style(sty():row():w(accentWidth):h(theme:px(32)):gap(accentGap):align("center"))
		:children(accents)

	local scaleOptions = {}
	for _, choice in ipairs({ { label = "90%", value = 0.9 }, { label = "100%", value = 1 }, { label = "125%", value = 1.25 } }) do
		scaleOptions[#scaleOptions + 1] = {
			label = choice.label,
			message = { type = "uiScale", value = choice.value },
			selected = values.uiScale == choice.value
		}
	end
	local scaleControl, scaleWidth = segmented(scaleOptions)

	local motionControl, motionWidth = settingsList.toggle(app, {
		on = values.reduceMotion,
		onClick = { type = "reduceMotion", value = not values.reduceMotion }
	})

	local appearanceRows = {
		settingsList.row(app, {
			label = "Theme",
			-- Only the automatic choice has a rule to explain; a named palette is its own answer.
			description = values.theme == "auto" ? "Day from 7:00 to 19:00, night otherwise" : nil,
			control = themeControl,
			controlWidth = themeWidth,
			controlHeight = theme:px(32),
			width = column
		}),
		settingsList.row(
			app,
			{ label = "Accent", control = accentControl, controlWidth = accentWidth, controlHeight = theme:px(32), width = column }
		),
		settingsList.row(
			app,
			{ label = "Scale", control = scaleControl, controlWidth = scaleWidth, controlHeight = theme:px(32), width = column }
		),
		settingsList.row(app, {
			label = "Reduce motion",
			description = "Fewer animations and transitions",
			control = motionControl,
			controlWidth = motionWidth,
			controlHeight = theme:px(26),
			width = column
		})
	}
	local appearance, appearanceHeight = settingsList.group(app, { title = "Appearance", rows = appearanceRows, width = column })

	-- The phone shell has bottom tabs, so a sidebar width means nothing there.
	local sidebar, sidebarHeight
	if not ctx.mobile then
		local sidebarControl, sidebarControlWidth = segmented({
			{ label = "Narrow", message = { type = "sidebarWidth", width = 220 }, selected = values.sidebarWidth == 220 },
			{ label = "Balanced", message = { type = "sidebarWidth", width = 264 }, selected = values.sidebarWidth == 264 },
			{ label = "Wide", message = { type = "sidebarWidth", width = 320 }, selected = values.sidebarWidth == 320 },
			{ label = "Collapse", message = { type = "toggleSidebar" }, selected = values.sidebarCollapsed }
		})
		sidebar, sidebarHeight = settingsList.group(app, {
			title = "Sidebar",
			rows = {
				settingsList.row(app, {
					label = "Width",
					control = sidebarControl,
					controlWidth = sidebarControlWidth,
					controlHeight = theme:px(32),
					width = column
				})
			},
			width = column
		})
	end

	-- Hiding the window keeps its loop, media keys and audio alive, so only a backend that can put
	-- an icon in the notification area offers it.
	local windowGroup, windowHeight
	if window.setTray ~= nil then
		local trayButton, trayWidth = settingsList.toggle(app, {
			on = values.minimizeToTray == true,
			onClick = { type = "minimizeToTray", value = not values.minimizeToTray }
		})
		windowGroup, windowHeight = settingsList.group(app, {
			title = "Window",
			rows = {
				settingsList.row(app, {
					label = "Minimize to tray",
					description = "Where minimizing sends the window",
					control = trayButton,
					controlWidth = trayWidth,
					controlHeight = theme:px(26),
					width = column
				})
			},
			width = column
		})
	end

	local buttonGap = theme:px(8)
	local chooseWidth = theme:px(narrow ? 160 : 150)
	local rescanWidth = theme:px(narrow ? 160 : 90)
	local libraryControlWidth = chooseWidth + rescanWidth + buttonGap
	if libraryControlWidth > inner then
		chooseWidth = math.floor((inner - buttonGap) / 2)
		rescanWidth = inner - buttonGap - chooseWidth
		libraryControlWidth = inner
	end
	local libraryButtons = div()
		:style(sty():row():w(libraryControlWidth):h(theme:px(32)):gap(buttonGap))
		:children({
			ui.button(
				ctx,
				{
					label = "Choose folder…",
					onClick = { type = "chooseFolder" },
					variant = "primary",
					height = theme:px(32),
					width = chooseWidth
				}
			),
			ui.button(ctx, { label = "Rescan", onClick = { type = "rescan" }, height = theme:px(32), width = rescanWidth })
		})
	local libraryRows = {
		settingsList.row(app, {
			label = "Music folder",
			description = values.root or "No folder chosen",
			control = libraryButtons,
			controlWidth = libraryControlWidth,
			controlHeight = theme:px(32),
			width = column
		})
	}
	local scan = app.services.scan
	if scan.skipped > 0 then
		libraryRows[#libraryRows + 1] = settingsList.row(app, {
			label = format.count(scan.skipped, "file") .. " skipped",
			description = "Files the last scan could not read",
			width = column
		})
		for at, failure in ipairs(scan.errors) do
			if at > 3 then break end
			libraryRows[#libraryRows + 1] = settingsList.row(app, {
				label = path.basename(failure.path),
				description = failure.message,
				width = column
			})
		end
	end
	local library, libraryHeight = settingsList.group(app, { title = "Library", rows = libraryRows, width = column })

	local volumeWidth = theme:px(narrow ? 80 : 200)
	local percentWidth = theme:px(38)
	local audioControlWidth = volumeWidth + theme:px(10) + percentWidth
	local audioControl = div()
		:style(sty():row():w(audioControlWidth):h(theme:px(22)):gap(theme:px(10)):align("center"))
		:children({
			volume.view(app, { width = volumeWidth, ui = ctx }),
			text(tostring(math.floor((values.isMuted ? 0 : values.volume) * 100)) .. "%")
				:style(theme:s():w(percentWidth):text(theme:type("xs")):fg(theme:color("faint")))
		})
	local audio, audioHeight = settingsList.group(app, {
		title = "Audio",
		rows = {
			settingsList.row(app, {
				label = "Volume",
				control = audioControl,
				controlWidth = audioControlWidth,
				controlHeight = theme:px(22),
				width = column
			})
		},
		width = column
	})

	local lastfm = app.services.lastfm.client
	local lastfmButton
	local lastfmControlWidth
	if lastfm:isConnected() then
		lastfmControlWidth = theme:px(narrow ? 92 : 110)
		lastfmButton = ui.button(
			ctx,
			{ label = "Disconnect", onClick = { type = "lastfmDisconnect" }, height = theme:px(28), width = lastfmControlWidth }
		)
	elseif lastfm:isAuthorizing() then
		lastfmControlWidth = theme:px(narrow ? 78 : 88) + theme:px(6) + theme:px(70)
		lastfmButton = div()
			:style(sty():row():w(lastfmControlWidth):h(theme:px(28)):gap(theme:px(6)))
			:children({
				ui.button(
					ctx,
					{
						label = "Open page",
						onClick = { type = "lastfmOpenAuth" },
						height = theme:px(28),
						width = theme:px(narrow ? 78 : 88)
					}
				),
				ui.button(
					ctx,
					{ label = "Cancel", onClick = { type = "lastfmCancel" }, height = theme:px(28), width = theme:px(70) }
				)
			})
	else
		lastfmControlWidth = theme:px(narrow ? 84 : 96)
		lastfmButton = ui.button(
			ctx,
			{
				label = "Connect",
				onClick = { type = "lastfmConnect" },
				variant = "primary",
				height = theme:px(28),
				width = lastfmControlWidth
			}
		)
	end
	local scrobbling, scrobblingWidth = settingsList.toggle(app, {
		on = values.lastfmEnabled == true,
		onClick = { type = "lastfmEnabled", value = not values.lastfmEnabled }
	})
	local lastfmGroup, lastfmHeight = settingsList.group(app, {
		title = "Last.fm",
		rows = {
			settingsList.row(app, {
				label = "Account",
				description = lastfm:statusText(),
				control = lastfmButton,
				controlWidth = lastfmControlWidth,
				controlHeight = theme:px(28),
				width = column
			}),
			settingsList.row(app, {
				label = "Scrobbling",
				description = values.lastfmEnabled ? "Sending what you play to Last.fm" : "Paused",
				control = scrobbling,
				controlWidth = scrobblingWidth,
				controlHeight = theme:px(26),
				width = column
			})
		},
		width = column
	})

	local pluginsRow = settingsList.row(app, {
		label = "Plugins",
		description = "Manage built-in and installed plugins",
		control = ui.icon(ctx, { name = "chevronRight", size = theme:px(18), colour = theme:color("muted") }),
		controlWidth = theme:px(18),
		controlHeight = theme:px(18),
		width = column,
		onClick = { type = "navigate", page = { kind = "plugins" } }
	})
	local pluginsGroup, pluginsHeight = settingsList.group(app, {
		title = "Plugins",
		rows = { pluginsRow },
		width = column
	})

	local versionBadge, versionBadgeWidth = settingsList.badge(app, version)
	local versionRow = settingsList.row(app, {
		label = "beat",
		description = "local files only · wonderland + treble · Ionicons",
		badge = versionBadge,
		badgeWidth = versionBadgeWidth,
		width = column
	})

	local githubWidth = theme:px(narrow ? 160 : 124)
	local issuesWidth = theme:px(narrow ? 160 : 92)
	local linksWidth = githubWidth + issuesWidth + buttonGap
	if linksWidth > inner then
		githubWidth = math.floor((inner - buttonGap) / 2)
		issuesWidth = inner - buttonGap - githubWidth
		linksWidth = inner
	end
	local links = div()
		:style(sty():row():w(linksWidth):h(theme:px(32)):gap(buttonGap))
		:children({
			ui.button(
				ctx,
				{
					label = "GitHub",
					onClick = { type = "openURL", url = GITHUB },
					icon = "github",
					variant = "primary",
					height = theme:px(32),
					width = githubWidth
				}
			),
			ui.button(
				ctx,
				{
					label = "Issues",
					onClick = { type = "openURL", url = GITHUB .. "/issues" },
					height = theme:px(32),
					width = issuesWidth
				}
			)
		})
	local about, aboutHeight = settingsList.group(app, {
		title = "About",
		rows = {
			versionRow,
			settingsList.row(app, {
				label = "Project",
				description = "Source code and issue tracker",
				control = links,
				controlWidth = linksWidth,
				controlHeight = theme:px(32),
				width = column
			})
		},
		width = column
	})

	local groupElements = {}
	local groupHeights = {}
	local function addGroup(element, height)
		if element == nil then return end
		groupElements[#groupElements + 1] = element
		groupHeights[#groupHeights + 1] = height
	end
	addGroup(appearance, appearanceHeight)
	addGroup(sidebar, sidebarHeight)
	addGroup(windowGroup, windowHeight)
	addGroup(library, libraryHeight)
	addGroup(audio, audioHeight)
	addGroup(lastfmGroup, lastfmHeight)
	addGroup(pluginsGroup, pluginsHeight)
	addGroup(about, aboutHeight)

	local titleHeight = math.floor(theme:type("xxl") * 1.25)
	local gap = theme:px(28)
	local totalHeight = titleHeight
	for _, height in ipairs(groupHeights) do totalHeight += height end
	totalHeight += gap * #groupElements

	app.services.scroll:setLimit(app:pageKey(), metrics.pageScrollLimit(app, window, totalHeight))

	local children = {
		text("Settings"):style(
			theme:s():w(column):h(titleHeight):text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))
		)
	}
	for _, element in ipairs(groupElements) do children[#children + 1] = element end

	local pageColumn = div():style(sty():column():w(column):h(totalHeight):gap(gap)):children(children)
	if ctx.mobile then return pageColumn end
	return div():style(sty():row():wrel(1.0):h(totalHeight):justify("center")):children({ pageColumn })
end

return settings
