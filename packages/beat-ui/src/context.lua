-- The small picture of the screen a component is made for. It is the whole of what beat-ui knows
-- about the app: a theme, the window's box, the page's content width, whether this is a phone, and
-- where keyboard focus is. beat builds one per window and hands it to every component; a plugin
-- gets the same object from `app:ui(window)`, so a component added by a plugin and one drawn by beat
-- read exactly the same values.
--
-- Colour tokens: bg, sidebar, surface, elevated, hover, active, text, muted, faint, border,
-- overlay, scrim, skeleton, sheen, danger, success, warning, accent, accentInk.
-- Type names: xs, sm, base, md, lg, xl, xxl, hero.
-- Radius names: sm, md, lg, xl, hero, full.
-- Space and pixel sizes are scaled by the theme's UI scale before they are returned.

--- The theme as beat-ui uses it. `beat.Theme` is the implementation beat passes; a test may pass
--- anything with these methods. The tokens and names are the ones documented above.
---@class beat.ui.Theme
---@field name string
---@field accent string
---@field isDark boolean
---@field accentColour string
---@field accentInk string
---@field fontFamily string
---@field scale number
---@field color fun(self: beat.ui.Theme, token: string, alpha: number?): string
---@field px fun(self: beat.ui.Theme, value: number): number
---@field space fun(self: beat.ui.Theme, value: number): number
---@field type fun(self: beat.ui.Theme, name: string): number
---@field radius fun(self: beat.ui.Theme, name: string): number
---@field s fun(self: beat.ui.Theme): wonderland.StyleBuilder

--- What a context is made from. beat fills this in from the live app; a test may make one by hand.
---@class beat.ui.ContextValues
---@field theme beat.ui.Theme
---@field assets wonderland.Assets? # Loaded pictures and fonts, or nil on a headless screen
---@field width number # The window's width
---@field height number # The window's height
---@field contentWidth number # The width a page has inside the shell and its gutters
---@field contentHeight number # The height a page has between the shell's bars, which is what its scroll limit is measured against
---@field mobile boolean # Whether the window is below the phone breakpoint
---@field focusedId string? # The focus id the layout has, when something is focused

--- The values every component reads. Fields are updated only by beat when it builds a context; a
--- component treats them as read-only.
---@class beat.ui.Context
---@field theme beat.ui.Theme
---@field assets wonderland.Assets?
---@field width number
---@field height number
---@field contentWidth number
---@field contentHeight number
---@field mobile boolean
---@field focusedId string?
---@field accentInk string # Text that reads on the accent colour
---@field color fun(self: beat.ui.Context, token: string, alpha: number?): string
---@field px fun(self: beat.ui.Context, value: number): number
---@field space fun(self: beat.ui.Context, value: number): number
---@field type fun(self: beat.ui.Context, name: string): number
---@field radius fun(self: beat.ui.Context, name: string): number
---@field s fun(self: beat.ui.Context): wonderland.StyleBuilder
---@field focused fun(self: beat.ui.Context, name: string): boolean
---@field panelWidth fun(self: beat.ui.Context, max: number): number
local Context = {}
Context.__index = Context

---@class beat.ui.ContextModule
---@field new fun(values: beat.ui.ContextValues): beat.ui.Context

---@param values beat.ui.ContextValues
---@return beat.ui.Context
function Context.new(values)
	assert(values ~= nil and values.theme ~= nil, "a UI context needs a theme")
	return setmetatable(
		{
			theme = values.theme,
			assets = values.assets,
			width = values.width,
			height = values.height,
			contentWidth = values.contentWidth,
			contentHeight = values.contentHeight,
			mobile = values.mobile == true,
			focusedId = values.focusedId,
			accentInk = values.theme.accentInk
		},
		Context
	)
end

---@param token string # A colour token, or a colour literal the theme passes through
---@param alpha number? # 0..1; omitted, the token's own alpha
---@return string
function Context:color(token, alpha)
	return self.theme:color(token, alpha)
end

---@param value number # Unscaled pixels
---@return number
function Context:px(value)
	return self.theme:px(value)
end

---@param value number # Unscaled spacing
---@return number
function Context:space(value)
	return self.theme:space(value)
end

---@param name string # A type name from the list above
---@return number
function Context:type(name)
	return self.theme:type(name)
end

---@param name string # A radius name from the list above
---@return number
function Context:radius(name)
	return self.theme:radius(name)
end

--- A text style builder in the theme's family: `ctx:s():text(ctx:type("sm")):fg(ctx:color("text"))`.
---@return wonderland.StyleBuilder
function Context:s()
	return self.theme:s()
end

--- Whether the layout has keyboard focus on the field with this id.
---@param name string
---@return boolean
function Context:focused(name)
	return self.focusedId == name
end

--- A floating panel's width: never wider than the window less its gutter.
---@param max number # The panel's preferred width in unscaled pixels
---@return number
function Context:panelWidth(max)
	local gutter = self.theme:space(self.mobile and 16 or 24)
	return math.min(self.theme:px(max), self.width - gutter * 2)
end

return Context
