-- The record a component builds from one set of props, kept so the next frame with those props
-- hands the same style builders over instead of interning the same ones again. A style is interned
-- by its values, so a builder kept from the previous frame is its own slot and costs nothing.
--
-- The values a style was built from are the key: a width, a state, a colour. They are style values,
-- which a screen holds for many frames -- a component's own geometry, not a number that follows the
-- pointer or the clock, which is what a canvas is for.
local cache = {}

--- One place in a cache: a table of the records at the keys walked to, keyed by the values a
--- record's styles depend on. `CacheKey` is a string (`"icon"`) or a number (a width).
---@alias beat.ui.CacheKey string|number
---@alias beat.ui.CacheSlot { [beat.ui.CacheKey]: any }

-- Where a record itself sits, under the keys: a key of its own, so a record of no fields is still
-- a record that is there.
local VALUE = true

--- The slot `name` and the keys given lead to, made on the way if it is not there yet.
---@param root beat.ui.CacheSlot
---@param name string
---@param ...
---@return beat.ui.CacheSlot
local function slotAt(root, name, ...)
	local found = root[name] or {}
	root[name] = found
	for at = 1, select("#", ...) do
		local key = select(at, ...) --[[@as beat.ui.CacheKey]]
		local nextFound = found[key] or {}
		found[key] = nextFound
		found = nextFound
	end
	return found
end

--- The record `build` makes for one set of values, made once and kept in the context's cache.
--- `build` is a module-level function and the values it is handed are the ones the record depends
--- on, so asking for it again is a walk down the cache and no allocation.
---@param ctx beat.ui.Context
---@param build fun(ctx: beat.ui.Context, ...): any
---@param name string # What the component calls its own corner of the cache
---@param ... any # The values the record depends on, most general first
---@return any
function cache.of(ctx, build, name, ...)
	local slot = slotAt(ctx:cache(), name, ...)
	local record = slot[VALUE]
	if record == nil then
		record = build(ctx, ...)
		slot[VALUE] = record
	end
	return record
end

return cache
