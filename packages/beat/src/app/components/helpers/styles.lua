-- Where a component keeps the styles it builds, so a frame hands the same builders over again
-- instead of making and interning them anew: a view is built on every pointer move. The table
-- belongs to the theme as it draws now (`Theme:cache`), so a new theme, scale or crossfade step
-- starts empty. A cached builder is never changed after it is stored.
local styles = {}

--- The styles one component keeps for one key: a width, a size, or nothing. The caller fills it
--- the first time it sees it empty, and reads it from then on.
---@param theme beat.Theme
---@param name string
---@param key any?
---@return table<string, any>
function styles.of(theme, name, key)
	---@type table<any, table<any, table<string, any>>>
	local cache = theme:cache()
	local byKey = cache[name]
	if byKey == nil then
		byKey = {}
		cache[name] = byKey
	end
	key = key == nil and 0 or key
	local found = byKey[key]
	if found == nil then
		found = {}
		byKey[key] = found
	end
	return found
end

return styles
