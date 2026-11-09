-- The public UI API a plugin builds its screens from. It is stable by version: a documented prop
-- or context field is part of the API, and breaking one is a major version.
--
-- Every component takes the UI context first and its props second:
--
--   local ui = require("beat-ui")
--   ui.button(ctx, { label = "Play", onClick = { type = "togglePlay" }, variant = "primary" })
--
-- `ctx` is the `beat.ui.Context` beat builds for a window and hands to a plugin's page or overlay
-- through `app:ui(window)`. beat-ui never requires `beat`: everything a component needs is in the
-- context.
local ui = {}

---@class beat.ui
---@field version string # The semver a plugin may write in its `requires`
---@field Context beat.ui.ContextModule
---@field button fun(ctx: beat.ui.Context, props: beat.ui.ButtonProps): wonderland.Element
---@field icon fun(ctx: beat.ui.Context, props: beat.ui.IconProps): wonderland.Element
---@field iconButton fun(ctx: beat.ui.Context, props: beat.ui.IconButtonProps): wonderland.Element
---@field field fun(ctx: beat.ui.Context, props: beat.ui.FieldProps): wonderland.Element
---@field section fun(ctx: beat.ui.Context, props: beat.ui.SectionProps): wonderland.Element
---@field emptyState fun(ctx: beat.ui.Context, props: beat.ui.EmptyStateProps): wonderland.Element
---@field checkbox fun(ctx: beat.ui.Context, props: beat.ui.CheckboxProps): wonderland.Element
---@field progressBar fun(ctx: beat.ui.Context, props: beat.ui.ProgressBarProps): wonderland.Element
---@field card fun(ctx: beat.ui.Context, props: beat.ui.CardProps): wonderland.Element
---@field listRow fun(ctx: beat.ui.Context, props: beat.ui.ListRowProps): wonderland.Element

ui.version = "0.1.0"
ui.Context = require("beat-ui.context")
ui.button = require("beat-ui.button").view
ui.icon = require("beat-ui.icon").view
ui.iconButton = require("beat-ui.icon_button").view
ui.field = require("beat-ui.field").view
ui.section = require("beat-ui.section").view
ui.emptyState = require("beat-ui.empty_state").view
ui.checkbox = require("beat-ui.checkbox").view
ui.progressBar = require("beat-ui.progress_bar").view
ui.card = require("beat-ui.card").view
ui.listRow = require("beat-ui.list_row").view

return ui
