-- The update a check found: what it is, what is installed, and the two ways out of the dialog.
-- The service owns the download and the restart; this only says what they are doing. A phone
-- closes the dialog once its browser has the APK, because the system's installer takes it from
-- there; a desktop stays open to show the download and then asks for the restart that swaps the
-- executable.
local wonderland = require("wonderland")
local ui = require("beat-ui")
local platform = require("beat.platform")

local div, text, sty = wonderland.div, wonderland.text, wonderland.sty

---@class beat.UpdateOverlayState: beat.OverlayState

---@class beat.UpdateOverlay: beat.OverlaySurface
local update = {}

---@param app beat.App
---@param _params table
---@return beat.UpdateOverlayState
function update.new(app, _params)
	return {}
end

---@param app beat.App
---@param overlay beat.OverlayInstance<beat.UpdateOverlayState>
---@param message beat.Message
function update.update(app, overlay, message)
	-- On a phone the download belongs to the browser and the dialog has done its work. Closing it
	-- here and letting the message through means the service still opens the link without a second
	-- message kind or a dialog left over the settings page.
	if message.type == "applyUpdate" and platform.android then
		app:close("update")
	end
	return false
end

---@param progress number?
local function downloadText(progress)
	if progress == nil then return "Downloading…" end
	return "Downloading… " .. math.floor(progress * 100) .. "%"
end

---@param app beat.App
---@param _overlay beat.OverlayInstance<beat.UpdateOverlayState>
---@param window wonderland.RenderWindow
function update.view(app, _overlay, window)
	local service = app.services.update
	local theme = app.services.appearance.theme
	local ctx = app:ui(window)
	local panelWidth = ctx:panelWidth(380)
	local pad = theme:px(20)
	local gap = theme:px(14)
	local titleHeight = theme:px(26)
	local lineHeight = theme:px(18)
	local buttonHeight = theme:px(38)
	local status = service.status
	local offer = service.offer

	local detail
	local actions
	if status == "downloading" then
		detail = downloadText(service.progress)
	elseif status == "ready" then
		detail = "Restart beat to finish"
		actions = div()
			:style(sty():row():wrel(1.0):h(buttonHeight):gap(theme:px(8)):align("center"):justify("end"))
			:children({
				ui.button(
					ctx,
					{
						label = "Restart",
						onClick = { type = "relaunchUpdate" },
						variant = "primary",
						height = theme:px(36),
						width = theme:px(96)
					}
				)
			})
	else
		detail = "You have " .. service.installedVersion
		actions = div()
			:style(sty():row():wrel(1.0):h(buttonHeight):gap(theme:px(8)):align("center"):justify("end"))
			:children({
				ui.button(
					ctx,
					{ label = "Later", onClick = { type = "dismiss" }, variant = "quiet", height = theme:px(36), width = theme:px(84) }
				),
				ui.button(
					ctx,
					{ label = "Update", onClick = { type = "applyUpdate" }, variant = "primary", height = theme:px(36), width = theme:px(96) }
				)
			})
	end

	local children = {
		text("Update available")
			:style(theme:s():wrel(1.0):h(titleHeight):text(theme:type("lg")):weight("bold"):fg(theme:color("text"))),
		text(offer ~= nil and (offer.label .. " is ready to install.") or "An update is ready to install.")
			:style(theme:s():wrel(1.0):h(lineHeight):text(theme:type("sm")):fg(theme:color("muted")):ellipsis()),
		text(detail):style(theme:s():wrel(1.0):h(lineHeight):text(theme:type("sm")):fg(theme:color("muted")):ellipsis())
	}
	if actions ~= nil then children[#children + 1] = actions end

	local gaps = #children - 1
	local panelHeight = pad * 2 + titleHeight + lineHeight * 2 + (actions ~= nil and buttonHeight or 0) + gap * gaps
	local panel = div()
		:style(
			sty()
				:w(panelWidth):h(panelHeight):column():pad(pad):gap(gap):radius(theme:radius("lg"))
				:bg(theme:color("elevated")):border(theme:px(1), theme:color("border"))
				:shadow(0, theme:px(16), theme:px(42), "#00000080")
		):onClick({ type = "keep" })
		:children(children)

	return div()
		:style(sty():fill():offset(0, 0):z(120):column():align("center"):justify("center"):bg(theme:color("overlay")))
		:onClick({ type = "dismiss" }):children({ panel })
end

return update
