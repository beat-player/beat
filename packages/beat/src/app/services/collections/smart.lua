-- The playlists the app always has: ways through the library the listener never had to make.
-- Each is a real playlist with a negative id, so opening, playing and shuffling one goes through
-- the same page and the same playback messages as a playlist they made. Nothing about one is
-- written down -- a built-in list is worked out again from the library and what has been played
-- whenever either changes.
local Smart = {}

---@class beat.SmartPlaylistDefinition
---@field id number
---@field name string
---@field subtitle string # How the list chooses its tracks, shown on its page
---@field tracks fun(taxonomy: beat.Taxonomy, library: beat.Library): beat.Track[]

--- One track's place in an ordering, with the numbers the comparator reads.
---@class beat.SmartPlaylistEntry
---@field track beat.Track
---@field at number # Library order, so equal plays keep the album's own order
---@field count number
---@field last number

--- Most plays first. A tie is broken by the later play, so a song just heard comes before one
--- heard as often years ago, and the library's order settles the rest.
---@param a beat.SmartPlaylistEntry
---@param b beat.SmartPlaylistEntry
local function mostPlayedFirst(a, b)
	if a.count ~= b.count then return a.count > b.count end
	if a.last ~= b.last then return a.last > b.last end
	return a.at < b.at
end

--- Fewest plays first, unplayed tracks included: the list is for finding what has not had a
--- chance yet, not only what has had one.
---@param a beat.SmartPlaylistEntry
---@param b beat.SmartPlaylistEntry
local function leastPlayedFirst(a, b)
	if a.count ~= b.count then return a.count < b.count end
	if a.last ~= b.last then return a.last < b.last end
	return a.at < b.at
end

--- The last started song first.
---@param a beat.SmartPlaylistEntry
---@param b beat.SmartPlaylistEntry
local function recentlyPlayedFirst(a, b)
	if a.last ~= b.last then return a.last > b.last end
	return a.at < b.at
end

---@param entries beat.SmartPlaylistEntry[]
---@param less fun(a: beat.SmartPlaylistEntry, b: beat.SmartPlaylistEntry): boolean
---@return beat.Track[]
local function sortedTracks(entries, less)
	table.sort(entries, less)
	local tracks = {}
	for at, entry in ipairs(entries) do tracks[at] = entry.track end
	return tracks
end

---@type beat.SmartPlaylistDefinition[]
local definitions = {
	{
		id = -1,
		name = "Most played",
		subtitle = "What you have heard most",
		tracks = function(taxonomy, library)
			local entries = {}
			for at, track in ipairs(library.tracks) do
				local metric = taxonomy:trackMetric(track)
				if metric ~= nil and metric.count > 0 then
					entries[#entries + 1] = { track = track, at = at, count = metric.count, last = metric.last }
				end
			end
			return sortedTracks(entries, mostPlayedFirst)
		end
	},
	{
		id = -2,
		name = "Least played",
		subtitle = "Songs heard the least, unplayed ones too",
		tracks = function(taxonomy, library)
			local entries = {}
			for at, track in ipairs(library.tracks) do
				local metric = taxonomy:trackMetric(track)
				entries[#entries + 1] = {
					track = track,
					at = at,
					count = metric ~= nil and metric.count or 0,
					last = metric ~= nil and metric.last or 0
				}
			end
			return sortedTracks(entries, leastPlayedFirst)
		end
	},
	{
		id = -3,
		name = "Recently played",
		subtitle = "The last songs you started",
		tracks = function(taxonomy, library)
			local entries = {}
			for at, track in ipairs(library.tracks) do
				local metric = taxonomy:trackMetric(track)
				if metric ~= nil and metric.last > 0 then
					entries[#entries + 1] = { track = track, at = at, count = metric.count, last = metric.last }
				end
			end
			return sortedTracks(entries, recentlyPlayedFirst)
		end
	},
	{
		id = -4,
		name = "Recently added",
		subtitle = "The newest files in your library",
		tracks = function(_, library)
			-- The library adds as the scan finds, and its cache keeps that order, so the end of
			-- the list is the newest music there is.
			local tracks = {}
			for at = #library.tracks, 1, -1 do tracks[#tracks + 1] = library.tracks[at] end
			return tracks
		end
	},
	{
		id = -5,
		name = "Never played",
		subtitle = "Everything still unheard",
		tracks = function(taxonomy, library)
			local tracks = {}
			for _, track in ipairs(library.tracks) do
				local metric = taxonomy:trackMetric(track)
				if metric == nil or metric.count <= 0 then tracks[#tracks + 1] = track end
			end
			return tracks
		end
	}
}

--- The playlists a page, a sidebar or a queue can ask for. The same table is handed out every
--- time: a playlist is a message target, not a thing to copy.
---@type beat.Playlist[]
local playlists = {}

---@type table<number, beat.Playlist>
local playlistById = {}

---@type table<number, beat.SmartPlaylistDefinition>
local definitionById = {}

for _, definition in ipairs(definitions) do
	definitionById[definition.id] = definition
	local playlist = {
		id = definition.id,
		name = definition.name,
		smart = true,
		tagIds = {},
		match = "all",
		manual = false,
		updatedAt = 0,
		builtin = true
	}
	playlists[#playlists + 1] = playlist
	playlistById[playlist.id] = playlist
end

--- Every built-in list, in the order the page shows them.
---@return beat.Playlist[]
function Smart.all()
	return playlists
end

--- A built-in playlist by its negative id, or nil for an id that belongs to the library's own
--- playlists.
---@param playlistId any
---@return beat.Playlist?
function Smart.byId(playlistId)
	if type(playlistId) ~= "number" then return nil end
	return playlistById[playlistId]
end

--- What a built-in playlist holds right now, in its own order.
---@param playlistId number
---@param taxonomy beat.Taxonomy
---@param library beat.Library
---@return beat.Track[]
function Smart.tracks(playlistId, taxonomy, library)
	local definition = definitionById[playlistId]
	if definition == nil then return {} end
	return definition.tracks(taxonomy, library)
end

--- The sentence under a built-in playlist's name on its page.
---@param playlist beat.Playlist
---@return string?
function Smart.subtitle(playlist)
	local definition = definitionById[playlist.id]
	return definition ~= nil and definition.subtitle or nil
end

return Smart
