-- The settings screen: theme, accent, scale, motion, the window, sidebar, the folder the library is
-- read from, volume, Last.fm, the plugins page and the About section, as rows in grouped lists.
local wonderland = require("wonderland")
local path = require("path")
local platform = require("beat.platform")
local ui = require("beat-ui")
local format = require("beat.app.components.helpers.format")
local volume = require("beat.app.components.volume")
local metrics = require("beat.app.components.helpers.metrics")
local settingsList = require("beat.app.components.settings_list")
local styles = require("beat.app.components.helpers.styles")
local version = require("beat.version")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

local GITHUB = "https://github.com/bycruz/beat"

--- A choice a segmented control offers, and the extra values the page reads back off it while
--- working out which one is chosen.
---@class beat.pages.SettingsChoice: beat.components.SettingsOption
---@field message table
---@field width number?
---@field channel string?

---@alias beat.pages.SettingsChoices beat.pages.SettingsChoice[]

local THEME_OPTIONS = {} --[[@as beat.pages.SettingsChoices]]

-- The record each row fills, one per row of this page, kept across frames: a row is built again
-- on every scroll step, and neither it nor the props it was built from is worth making again.
---@type beat.components.SettingsItem[]
local ROW_ITEMS = {}

---@param index integer
---@return beat.components.SettingsItem
local function rowSlot(index)
	local item = ROW_ITEMS[index]
	if item == nil then
		item = {}
		ROW_ITEMS[index] = item
	end
	return item
end

-- The choices the page offers, with their messages: the words never change, and a message is the
-- same table every frame. Only which of them is chosen is written again.
local THEME_LABELS = {}
local THEME_OPTION_NAMES = {}
local SCALE_OPTIONS = {
	{ label = "90%", message = { type = "uiScale", value = 0.9 } },
	{ label = "100%", message = { type = "uiScale", value = 1 } },
	{ label = "125%", message = { type = "uiScale", value = 1.25 } }
} --[[@as beat.pages.SettingsChoices]]
local SIDEBAR_OPTIONS = {
	{ label = "Narrow", message = { type = "sidebarWidth", width = 220 }, width = 220 },
	{ label = "Balanced", message = { type = "sidebarWidth", width = 264 }, width = 264 },
	{ label = "Wide", message = { type = "sidebarWidth", width = 320 }, width = 320 },
	{ label = "Collapse", message = { type = "toggleSidebar" } }
} --[[@as beat.pages.SettingsChoices]]
local CHANNEL_OPTIONS = {
	{ label = "Release", message = { type = "updateChannel", value = "release" }, channel = "release" },
	{ label = "Nightly", message = { type = "updateChannel", value = "nightly" }, channel = "nightly" }
} --[[@as beat.pages.SettingsChoices]]

local CHOOSE_FOLDER = { type = "chooseFolder" }
local RESCAN = { type = "rescan" }
local OPEN_ACCENT_PICKER = { type = "open", overlay = "accent_picker" }
local OPEN_PLUGINS = { type = "navigate", page = { kind = "plugins" } }
local GITHUB_ACTION = { type = "openURL", url = GITHUB }
local ISSUES_ACTION = { type = "openURL", url = GITHUB .. "/issues" }

-- What a segmented choice is asked for, written again per control: the component reads it and
-- keeps nothing, and the page is built again on every frame it is scrolled.
local segmentProps = {}

--- A segmented choice drawn at the width its labels ask for, filling the room the row leaves when
--- that is wider than the row can give it.
---@param app beat.App
---@param options beat.pages.SettingsChoices
---@param stacked boolean
---@param inner number
---@return wonderland.Element
---@return number
local function segmentedControl(app, options, stacked, inner)
	local theme = app.services.appearance.theme
	segmentProps.options = options
	segmentProps.width = nil
	local element, width = settingsList.segmented(app, segmentProps)
	local limit = stacked and inner or (inner - theme:px(80) - theme:px(16))
	if width > limit then
		segmentProps.width = limit
		element, width = settingsList.segmented(app, segmentProps)
	end
	return element, width
end

-- What a theme's swatches are drawn in, written again per page: the icon reads it and keeps
-- nothing, and the swatches are built on every frame.
---@type table<string, any>
local swatchIconProps = { name = "check", size = 0, colour = "" }

-- What a theme's swatches are drawn in, written again per page: the icon reads it and keeps
-- nothing, and the swatches are built on every frame.
---@type table<string, any>
local swatchIconProps = { name = "check", size = 0, colour = "" }

--- The accent swatches as one control. The loop is its own function so it compiles even while
--- the page around it is still being interpreted; the swatches themselves are kept per size.
---@param app beat.App
---@param ctx beat.ui.Context
---@param theme beat.Theme
---@param names string[]
---@param values beat.Settings
---@param size number
---@return wonderland.Element[]
local function buildAccents(app, ctx, theme, names, values, size)
	local swatches = styles.of(theme, "settingsSwatches", size) --[[@as table<string, wonderland.StyleBuilder>]]
	local messages = styles.of(theme, "settingsSwatchMessages") --[[@as table<string, table>]]
	local accents = {}
	for at = 1, #names do
		local name = names[at]
		local swatch = swatches[name]
		if swatch == nil then
			swatch = sty()
				:size(size, size):radius(theme:radius("full"))
				:bg(app.services.appearance:accentColour(name)):align("center"):justify("center")
			swatches[name] = swatch
		end
		local message = messages[name]
		if message == nil then
			message = { type = "accent", name = name }
			messages[name] = message
		end
		local body
		if values.accent == name then
			swatchIconProps.size, swatchIconProps.colour = theme:px(14), app.services.appearance:accentInk(name)
			body = ui.icon(ctx, swatchIconProps --[[@as beat.ui.IconProps]])
		else
			body = div()
		end
		accents[#accents + 1] = div():style(swatch):onClick(message):children(body)
	end
	return accents
end

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
	local names = app.services.appearance:names()
	for at = 1, #names do
		local name = names[at]
		local option = THEME_OPTIONS[at]
		if option == nil then
			local label = name == "auto" ? "Auto" : (name:sub(1, 1):upper() .. name:sub(2))
			option = { label = label, message = { type = "theme", name = name } }
			THEME_OPTIONS[at] = option
			THEME_LABELS[at] = label
			THEME_OPTION_NAMES[at] = name
		end
		option.selected = values.theme == name
	end
	local themeControl, themeWidth = segmentedControl(app, THEME_OPTIONS, stacked, inner)

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

	local accents = buildAccents(app, ctx, theme, accentNames, values, accentSize)
	local custom = styles.of(theme, "settingsCustom", customWidth) --[[@as { box: wonderland.StyleBuilder?, text: wonderland.StyleBuilder? }]]
	if custom.box == nil then
		custom.box = sty()
			:row():w(customWidth):h(theme:px(32)):radius(theme:radius("full")):bg("#000000")
			:border(theme:px(1), theme:color("border")):align("center"):justify("center")
		custom.text = theme:s():text(theme:type("sm")):weight("semibold"):fg("#f4f6f9")
	end
	local customButton = div()
		:style(assert(custom.box)):onClick(OPEN_ACCENT_PICKER)
		:children(text("Custom"):style(assert(custom.text)))
	accents[#accents + 1] = customButton
	local accentBox = styles.of(theme, "settingsAccentBox", accentWidth) --[[@as { style: wonderland.StyleBuilder?, gap: number? }]]
	if accentBox.style == nil or accentBox.gap ~= accentGap then
		accentBox.gap = accentGap
		accentBox.style = sty():row():w(accentWidth):h(theme:px(32)):gap(accentGap):align("center")
	end
	local accentControl = div():style(assert(accentBox.style)):children(accents)

	for at = 1, #SCALE_OPTIONS do
		local choice = SCALE_OPTIONS[at]
		choice.selected = values.uiScale == choice.message.value
	end
	local scaleControl, scaleWidth = segmentedControl(app, SCALE_OPTIONS, stacked, inner)

	local motionControl, motionWidth = settingsList.toggle(app, {
		on = values.reduceMotion,
		onClick = { type = "reduceMotion", value = not values.reduceMotion }
	})

	local appearanceRows = {
		settingsList.rowAt(
			app,
			rowSlot(1),
			column,
			"Theme",
			-- Only the automatic choice has a rule to explain; a named palette is its own answer.
			values.theme == "auto" ? "Day from 7:00 to 19:00, night otherwise" : nil,
			themeControl,
			themeWidth,
			theme:px(32)
		),
		settingsList.rowAt(app, rowSlot(2), column, "Accent", nil, accentControl, accentWidth, theme:px(32)),
		settingsList.rowAt(app, rowSlot(3), column, "Scale", nil, scaleControl, scaleWidth, theme:px(32)),
		settingsList.rowAt(
			app,
			rowSlot(4),
			column,
			"Reduce motion",
			"Fewer animations and transitions",
			motionControl,
			motionWidth,
			theme:px(26)
		)
	}
	local appearance, appearanceHeight = settingsList.group(app, { title = "Appearance", rows = appearanceRows, width = column })

	-- The phone shell has bottom tabs, so a sidebar width means nothing there.
	local sidebar, sidebarHeight
	if not ctx.mobile then
		-- A width is the option in force only while the sidebar is open: collapsing keeps the
		-- chosen width for the next expansion, but the Collapse option is then the one shown as
		-- chosen. (A single `and/or` here cannot say that: `or collapsed` makes every width
		-- option chosen as well once the sidebar is collapsed.)
		for at = 1, #SIDEBAR_OPTIONS do
			local choice = SIDEBAR_OPTIONS[at]
			if choice.width ~= nil then
				choice.selected = values.sidebarCollapsed ~= true and values.sidebarWidth == choice.width
			else
				choice.selected = values.sidebarCollapsed == true
			end
		end
		local sidebarControl, sidebarControlWidth = segmentedControl(app, SIDEBAR_OPTIONS, stacked, inner)
		sidebar, sidebarHeight = settingsList.group(app, {
			title = "Sidebar",
			rows = {
				settingsList.rowAt(app, rowSlot(5), column, "Width", nil, sidebarControl, sidebarControlWidth, theme:px(32))
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
				settingsList.rowAt(
					app,
					rowSlot(6),
					column,
					"Minimize to tray",
					"Where minimizing sends the window",
					trayButton,
					trayWidth,
					theme:px(26)
				)
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
	local libraryBox = styles.of(theme, "settingsLibraryBox", libraryControlWidth) --[[@as { style: wonderland.StyleBuilder?, gap: number? }]]
	if libraryBox.style == nil or libraryBox.gap ~= buttonGap then
		libraryBox.gap = buttonGap
		libraryBox.style = sty():row():w(libraryControlWidth):h(theme:px(32)):gap(buttonGap)
	end
	local libraryButtons = div()
		:style(assert(libraryBox.style))
		:children(
			ui.button(
				ctx,
				{
					label = "Choose folder…",
					onClick = CHOOSE_FOLDER,
					variant = "primary",
					height = theme:px(32),
					width = chooseWidth
				}
			),
			ui.button(ctx, { label = "Rescan", onClick = RESCAN, height = theme:px(32), width = rescanWidth })
		)
	local libraryRows = {
		settingsList.rowAt(
			app,
			rowSlot(7),
			column,
			"Music folder",
			values.root or "No folder chosen",
			libraryButtons,
			libraryControlWidth,
			theme:px(32)
		)
	}
	local scan = app.services.scan
	if scan.skipped > 0 then
		libraryRows[#libraryRows + 1] = settingsList.rowAt(
			app,
			rowSlot(8),
			column,
			format.count(scan.skipped, "file") .. " skipped",
			"Files the last scan could not read"
		)
		for at, failure in ipairs(scan.errors) do
			if at > 3 then break end
			libraryRows[#libraryRows + 1] = settingsList.rowAt(app, rowSlot(8 + at), column, path.basename(failure.path), failure.message)
		end
	end
	local library, libraryHeight = settingsList.group(app, { title = "Library", rows = libraryRows, width = column })

	local volumeWidth = theme:px(narrow ? 80 : 200)
	local percentWidth = theme:px(38)
	local audioControlWidth = volumeWidth + theme:px(10) + percentWidth
	local audioBox = styles.of(theme, "settingsAudioBox", audioControlWidth) --[[@as { style: wonderland.StyleBuilder?, percent: wonderland.StyleBuilder? }]]
	if audioBox.style == nil then
		audioBox.style = sty():row():w(audioControlWidth):h(theme:px(22)):gap(theme:px(10)):align("center")
		audioBox.percent = theme:s():w(percentWidth):text(theme:type("xs")):fg(theme:color("faint"))
	end
	local audioControl = div()
		:style(assert(audioBox.style))
		:children(
			volume.view(app, { width = volumeWidth, ui = ctx }),
			text(tostring(math.floor((values.isMuted ? 0 : values.volume) * 100)) .. "%"):style(audioBox.percent)
		)
	local audioRows = {
		settingsList.rowAt(app, rowSlot(12), column, "Volume", nil, audioControl, audioControlWidth, theme:px(22))
	}
	-- Only the phone has another app to take audio focus, or a media stream of its own to fall
	-- silent; the setting would mean nothing on a desktop.
	if platform.android then
		local otherAudio, otherAudioWidth = settingsList.toggle(app, {
			on = values.pauseForOtherAudio ~= false,
			onClick = { type = "pauseForOtherAudio", value = values.pauseForOtherAudio == false }
		})
		audioRows[#audioRows + 1] = settingsList.rowAt(
			app,
			rowSlot(13),
			column,
			"Pause for other audio",
			"When another app plays, or the volume is at zero",
			otherAudio,
			otherAudioWidth,
			theme:px(26)
		)
	end
	local audio, audioHeight = settingsList.group(app, {
		title = "Audio",
		rows = audioRows,
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
			settingsList.rowAt(
				app,
				rowSlot(14),
				column,
				"Account",
				lastfm:statusText(),
				lastfmButton,
				lastfmControlWidth,
				theme:px(28)
			),
			settingsList.rowAt(
				app,
				rowSlot(15),
				column,
				"Scrobbling",
				values.lastfmEnabled ? "Sending what you play to Last.fm" : "Paused",
				scrobbling,
				scrobblingWidth,
				theme:px(26)
			)
		},
		width = column
	})

	local pluginsRow = settingsList.rowAt(
		app,
		rowSlot(16),
		column,
		"Plugins",
		"Manage built-in and installed plugins",
		ui.icon(ctx, { name = "chevronRight", size = theme:px(18), colour = theme:color("muted") }),
		theme:px(18),
		theme:px(18),
		OPEN_PLUGINS
	)
	local pluginsGroup, pluginsHeight = settingsList.group(app, {
		title = "Plugins",
		rows = { pluginsRow },
		width = column
	})

	local updateService = app.services.update
	local channel = updateService:channel()
	for at = 1, #CHANNEL_OPTIONS do
		local choice = CHANNEL_OPTIONS[at]
		choice.selected = channel == choice.channel
	end
	local channelControl, channelWidth = segmentedControl(app, CHANNEL_OPTIONS, stacked, inner)

	local updateStatus = updateService.status
	local updateDescription
	local updateLabel
	local updateMessage
	---@type "primary"|"secondary"|"quiet"
	local updateVariant = "secondary"
	if updateStatus == "checking" then
		updateDescription = "Checking…"
		updateLabel = "Checking…"
		updateMessage = { type = "keep" }
		updateVariant = "quiet"
	elseif updateStatus == "downloading" then
		local percent = updateService.progress ~= nil and math.floor(updateService.progress * 100) or nil
		updateDescription = percent ~= nil and ("Downloading… " .. percent .. "%") or "Downloading…"
		updateLabel = "Downloading…"
		updateMessage = { type = "keep" }
		updateVariant = "quiet"
	elseif updateStatus == "ready" then
		updateDescription = "Restart to finish updating"
		updateLabel = "Restart"
		updateMessage = { type = "relaunchUpdate" }
		updateVariant = "primary"
	elseif updateStatus == "available" then
		local label = updateService.offer ~= nil and updateService.offer.label or "An update"
		updateDescription = label .. " is available"
		updateLabel = "Update"
		updateMessage = { type = "applyUpdate" }
		updateVariant = "primary"
	elseif updateStatus == "upToDate" then
		updateDescription = "Up to date"
		updateLabel = "Check"
		updateMessage = { type = "checkForUpdates" }
	elseif updateStatus == "failed" then
		updateDescription = "Could not check: " .. (updateService.error or "unknown error")
		updateLabel = "Check"
		updateMessage = { type = "checkForUpdates" }
	elseif updateStatus == "unsupported" then
		updateDescription = "Not available in this build"
		updateLabel = "Check"
		updateMessage = { type = "checkForUpdates" }
	else
		updateDescription = "Check for a new version"
		updateLabel = "Check"
		updateMessage = { type = "checkForUpdates" }
	end
	local updateButtonWidth = theme:px(narrow ? 104 : 112)
	local updateButton = ui.button(
		ctx,
		{
			label = updateLabel,
			onClick = updateMessage,
			variant = updateVariant,
			height = theme:px(28),
			width = updateButtonWidth
		}
	)
	local autoUpdates, autoUpdatesWidth = settingsList.toggle(app, {
		on = values.checkUpdates ~= false,
		onClick = { type = "checkUpdates", value = values.checkUpdates == false }
	})

	local versionBadge, versionBadgeWidth = settingsList.badge(app, version)
	local versionRow = settingsList.rowAt(app, rowSlot(17), column, "beat", nil, nil, nil, nil, nil, versionBadge, versionBadgeWidth)

	local githubWidth = theme:px(narrow ? 160 : 124)
	local issuesWidth = theme:px(narrow ? 160 : 92)
	local linksWidth = githubWidth + issuesWidth + buttonGap
	if linksWidth > inner then
		githubWidth = math.floor((inner - buttonGap) / 2)
		issuesWidth = inner - buttonGap - githubWidth
		linksWidth = inner
	end
	local linksBox = styles.of(theme, "settingsLinksBox", linksWidth) --[[@as { style: wonderland.StyleBuilder?, gap: number? }]]
	if linksBox.style == nil or linksBox.gap ~= buttonGap then
		linksBox.gap = buttonGap
		linksBox.style = sty():row():w(linksWidth):h(theme:px(32)):gap(buttonGap)
	end
	local links = div()
		:style(assert(linksBox.style))
		:children(
			ui.button(
				ctx,
				{
					label = "GitHub",
					onClick = GITHUB_ACTION,
					icon = "github",
					variant = "primary",
					height = theme:px(32),
					width = githubWidth
				}
			),
			ui.button(ctx, { label = "Issues", onClick = ISSUES_ACTION, height = theme:px(32), width = issuesWidth })
		)
	local about, aboutHeight = settingsList.group(app, {
		title = "About",
		rows = {
			versionRow,
			settingsList.rowAt(
				app,
				rowSlot(18),
				column,
				"Update channel",
				"Release is stable; Nightly is every new build",
				channelControl,
				channelWidth,
				theme:px(32)
			),
			settingsList.rowAt(
				app,
				rowSlot(19),
				column,
				"Updates",
				updateDescription,
				updateButton,
				updateButtonWidth,
				theme:px(28)
			),
			settingsList.rowAt(
				app,
				rowSlot(20),
				column,
				"Check automatically",
				"Look for a new build once a launch",
				autoUpdates,
				autoUpdatesWidth,
				theme:px(26)
			),
			settingsList.rowAt(
				app,
				rowSlot(21),
				column,
				"Project",
				"Source code and issue tracker",
				links,
				linksWidth,
				theme:px(32)
			)
		},
		width = column
	})

	local groupElements = { appearance }
	local groupHeights = { appearanceHeight }
	if sidebar ~= nil then
		groupElements[#groupElements + 1] = sidebar
		groupHeights[#groupHeights + 1] = sidebarHeight
	end
	if windowGroup ~= nil then
		groupElements[#groupElements + 1] = windowGroup
		groupHeights[#groupHeights + 1] = windowHeight
	end
	groupElements[#groupElements + 1] = library
	groupHeights[#groupHeights + 1] = libraryHeight
	groupElements[#groupElements + 1] = audio
	groupHeights[#groupHeights + 1] = audioHeight
	groupElements[#groupElements + 1] = lastfmGroup
	groupHeights[#groupHeights + 1] = lastfmHeight
	groupElements[#groupElements + 1] = pluginsGroup
	groupHeights[#groupHeights + 1] = pluginsHeight
	groupElements[#groupElements + 1] = about
	groupHeights[#groupHeights + 1] = aboutHeight

	local titleHeight = math.floor(theme:type("xxl") * 1.25)
	local gap = theme:px(28)
	local totalHeight = titleHeight
	for at = 1, #groupHeights do totalHeight += groupHeights[at] end
	totalHeight += gap * #groupElements

	app.services.scroll:setLimit(app:pageKey(), metrics.pageScrollLimit(app, window, totalHeight))

	local titleBox = styles.of(theme, "settingsTitle", column) --[[@as { style: wonderland.StyleBuilder? }]]
	if titleBox.style == nil then
		titleBox.style = theme:s():w(column):h(titleHeight):text(theme:type("xxl")):weight("bold"):fg(theme:color("text"))
	end
	local children = { text("Settings"):style(titleBox.style) }
	for at = 1, #groupElements do children[#children + 1] = groupElements[at] end

	local pageBox = styles.of(theme, "settingsColumn", totalHeight) --[[@as { style: wonderland.StyleBuilder?, column: number? }]]
	if pageBox.style == nil or pageBox.column ~= column then
		pageBox.column = column
		pageBox.style = sty():column():w(column):h(totalHeight):gap(gap)
	end
	local pageColumn = div():style(pageBox.style):children(children)
	if ctx.mobile then return pageColumn end
	return div():style(sty():row():wrel(1.0):h(totalHeight):justify("center")):children({ pageColumn })
end

return settings
