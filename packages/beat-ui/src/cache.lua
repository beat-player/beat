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

--- The child slot at `key`, made on the way if it is not there yet.
---@param node beat.ui.CacheSlot
---@param key beat.ui.CacheKey
---@return beat.ui.CacheSlot
local function child(node, key)
	local found = node[key]
	if found == nil then
		found = {}
		node[key] = found
	end
	return found
end

--- The record `build` makes for one set of values, made once and kept in the context's cache.
--- `build` is a module-level function and the values it is handed are the ones the record depends
--- on, so asking for it again is a walk down the cache and no allocation.
---
--- The walk is spelled out for nought to eight keys rather than kept in a loop over `select`: a
--- component asks this on every frame, and the loop's vararg walk was interpreted at the root of
--- every trace that reached it. A list row asks with seven, so that branch is as important as the
--- shorter ones; the loop only serves a caller that asks with more keys than these.
---@param ctx beat.ui.Context
---@param build fun(ctx: beat.ui.Context, ...): any
---@param name string # What the component calls its own corner of the cache
---@param ... any # The values the record depends on, most general first
---@return any
function cache.of(ctx, build, name, ...)
	local root = ctx:cache() --[[@as beat.ui.CacheSlot]]
	local found = root[name] --[[@as beat.ui.CacheSlot?]]
	if found == nil then
		found = {}
		root[name] = found
	end
	---@cast found beat.ui.CacheSlot

	local n = select("#", ...)
	if n == 0 then
		local record = found[VALUE]
		if record == nil then
			record = build(ctx)
			found[VALUE] = record
		end
		return record
	elseif n == 1 then
		local a = select(1, ...) --[[@as beat.ui.CacheKey]]
		local slot = child(found, a)
		local record = slot[VALUE]
		if record == nil then
			record = build(ctx, a)
			slot[VALUE] = record
		end
		return record
	elseif n == 2 then
		local a, b = select(1, ...) --[[@as beat.ui.CacheKey]], select(2, ...) --[[@as beat.ui.CacheKey]]
		local slot = child(child(found, a), b)
		local record = slot[VALUE]
		if record == nil then
			record = build(ctx, a, b)
			slot[VALUE] = record
		end
		return record
	elseif n == 3 then
		local a, b, c = select(1, ...), select(2, ...), select(3, ...)
		local slot = child(child(child(found, a --[[@as beat.ui.CacheKey]]), b --[[@as beat.ui.CacheKey]]), c --[[@as beat.ui.CacheKey]])
		local record = slot[VALUE]
		if record == nil then
			record = build(ctx, a, b, c)
			slot[VALUE] = record
		end
		return record
	elseif n == 4 then
		local a, b, c, d = select(1, ...), select(2, ...), select(3, ...), select(4, ...)
		local slot = child(child(child(child(found, a --[[@as beat.ui.CacheKey]]), b --[[@as beat.ui.CacheKey]]), c --[[@as beat.ui.CacheKey]]), d --[[@as beat.ui.CacheKey]])
		local record = slot[VALUE]
		if record == nil then
			record = build(ctx, a, b, c, d)
			slot[VALUE] = record
		end
		return record
	elseif n == 5 then
		local a, b, c, d, e = select(1, ...), select(2, ...), select(3, ...), select(4, ...), select(5, ...)
		local slot = child(
			child(child(child(child(found, a --[[@as beat.ui.CacheKey]]), b --[[@as beat.ui.CacheKey]]), c --[[@as beat.ui.CacheKey]]), d --[[@as beat.ui.CacheKey]]),
			e --[[@as beat.ui.CacheKey]]
		)
		local record = slot[VALUE]
		if record == nil then
			record = build(ctx, a, b, c, d, e)
			slot[VALUE] = record
		end
		return record
	elseif n == 6 then
		local a, b, c, d, e, f = select(1, ...), select(2, ...), select(3, ...), select(4, ...), select(5, ...), select(6, ...)
		local slot = child(
			child(
				child(child(child(child(found, a --[[@as beat.ui.CacheKey]]), b --[[@as beat.ui.CacheKey]]), c --[[@as beat.ui.CacheKey]]), d --[[@as beat.ui.CacheKey]]),
				e --[[@as beat.ui.CacheKey]]
			),
			f --[[@as beat.ui.CacheKey]]
		)
		local record = slot[VALUE]
		if record == nil then
			record = build(ctx, a, b, c, d, e, f)
			slot[VALUE] = record
		end
		return record
	elseif n == 7 then
		local a, b, c, d, e, f, g = select(1, ...), select(2, ...), select(3, ...), select(4, ...), select(5, ...), select(6, ...), select(7, ...)
		local slot = child(found, a)
		slot = child(slot, b)
		slot = child(slot, c)
		slot = child(slot, d)
		slot = child(slot, e)
		slot = child(slot, f)
		slot = child(slot, g)
		local record = slot[VALUE]
		if record == nil then
			record = build(ctx, a, b, c, d, e, f, g)
			slot[VALUE] = record
		end
		return record
	elseif n == 8 then
		local a, b, c, d, e, f, g, h = select(1, ...), select(2, ...), select(3, ...), select(4, ...), select(5, ...), select(6, ...), select(7, ...), select(8, ...)
		local slot = child(found, a)
		slot = child(slot, b)
		slot = child(slot, c)
		slot = child(slot, d)
		slot = child(slot, e)
		slot = child(slot, f)
		slot = child(slot, g)
		slot = child(slot, h)
		local record = slot[VALUE]
		if record == nil then
			record = build(ctx, a, b, c, d, e, f, g, h)
			slot[VALUE] = record
		end
		return record
	end

	-- More keys than the fixed branches walk, kept working by walking the rest: a maker with a key
	-- per option would otherwise have to know this file's limit. The fixed branches above are the
	-- ones the screen asks on every frame; this one is for a caller that outgrows them.
	local slot = found --[[@as beat.ui.CacheSlot]]
	for at = 1, n do
		slot = child(slot, select(at, ...) --[[@as beat.ui.CacheKey]])
	end
	local record = slot[VALUE]
	if record == nil then
		record = build(ctx, ...)
		slot[VALUE] = record
	end
	return record
end

return cache
