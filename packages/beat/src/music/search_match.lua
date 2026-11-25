-- Whether a folded text answers a folded query, and how well. Every word of the query has to be
-- found in the text; a word is found exactly when the text holds it anywhere, and with a typo when
-- the text holds a library word within one edit of it (two for a word of eight letters or more). A
-- query word under four letters is only ever found exactly: "ab" is within one edit of half the
-- words in a library.
--
-- Typos are looked for once per query, not once per title: the library's distinct words are
-- compared with each query word, and what comes out near is a short list each title is then
-- searched for with plain `find`. The comparison runs in three ffi rows made when the file loads
-- and reads both words in place, so nothing is made per word compared.
local ffi = require("ffi")
local bit = require("bit")

local byte, find, min = string.byte, string.find, math.min
local band, bor, bnot, lshift = bit.band, bit.bor, bit.bnot, bit.lshift

local match = {}

-- Rows long enough for any word a query or a title is likely to hold; a longer word is only
-- compared exactly.
local MAX_WORD = 48
local rowA = ffi.new("int32_t[?]", MAX_WORD + 1)
local rowB = ffi.new("int32_t[?]", MAX_WORD + 1)
local rowC = ffi.new("int32_t[?]", MAX_WORD + 1)

-- The current query's words, and for each the library words near it. The tables are kept from
-- query to query and written over.
---@type string[]
local words = {}
---@type string[][]
local nearWords = {}
---@type number[]
local nearCounts = {}
local wordCount = 0

--- The letters a-z of a word, as bits.
---@param word string
---@return number
local function lettersOf(word)
	local letters = 0
	for at = 1, #word do
		local b = byte(word, at)
		if b >= 97 and b <= 122 then letters = bor(letters, lshift(1, b - 97)) end
	end
	return letters
end

--- Whether `a` is within `limit` edits of `b`: insertions, deletions, substitutions and swapped
--- neighbours. A row whose best cell is already past the limit ends the comparison.
---@param a string
---@param b string
---@param limit number
---@return boolean
local function near(a, b, limit)
	local aLength, bLength = #a, #b
	local before, previous, current = rowA, rowB, rowC
	for column = 0, bLength do previous[column] = column end
	for row = 1, aLength do
		local letter = byte(a, row)
		current[0] = row
		local best = row
		for column = 1, bLength do
			local other = byte(b, column)
			local value = min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + (letter == other and 0 or 1))
			if row > 1 and column > 1 and letter == byte(b, column - 1) and byte(a, row - 1) == other then
				value = min(value, before[column - 2] + 1)
			end
			current[column] = value
			best = min(best, value)
		end
		if best > limit then return false end
		before, previous, current = previous, current, before
	end
	return previous[bLength] <= limit
end

--- Fills `list` with the vocabulary's words within `limit` edits of `word`, and says how many. A
--- typo changes at most one letter of the set a word holds, so a word missing more of the query
--- word's letters than the edits allowed is passed over before any comparison.
---@param word string
---@param limit number
---@param vocabulary string[]
---@param letterSets number[]
---@param list string[]
---@return number
local function collectNear(word, limit, vocabulary, letterSets, list)
	local count = 0
	local length = #word
	local letters = lettersOf(word)
	for at = 1, #vocabulary do
		local candidate = vocabulary[at]
		local size = #candidate
		if size >= length - limit and size <= length + limit and size <= MAX_WORD then
			local missing = band(letters, bnot(letterSets[at]))
			local off = 0
			while missing ~= 0 and off <= limit do
				missing = band(missing, missing - 1)
				off = off + 1
			end
			if off <= limit and near(candidate, word, limit) then
				count = count + 1
				list[count] = candidate
			end
		end
	end
	return count
end

--- Cuts `needle` into the words the next `score` calls look for, and finds the library words each
--- may be a typo of.
---@param needle string # Folded: words of single spaces, none at either end
---@param vocabulary string[] # The library's distinct folded words
---@param letterSets number[] # Each vocabulary word's letters, as `lettersOf` makes them
function match.prepare(needle, vocabulary, letterSets)
	wordCount = 0
	local length = #needle
	local start = 1
	while start <= length do
		local stop = find(needle, " ", start, true) or (length + 1)
		local size = stop - start
		wordCount = wordCount + 1
		local word = needle:sub(start, stop - 1)
		words[wordCount] = word
		local list = nearWords[wordCount]
		if list == nil then
			list = {}
			nearWords[wordCount] = list
		end
		local limit = (size < 4 or size > MAX_WORD) and 0 or (size >= 8 and 2 or 1)
		nearCounts[wordCount] = limit == 0 and 0 or collectNear(word, limit, vocabulary, letterSets, list)
		start = stop + 1
	end
end

--- 2 when the text holds every word of the query as written, 1 when it holds them with typos, 0
--- when it does not hold them.
---@param text string?
---@return number
function match.score(text)
	if text == nil or wordCount == 0 then return 0 end
	local score = 2
	for at = 1, wordCount do
		if not find(text, words[at], 1, true) then
			local list, count = nearWords[at], nearCounts[at]
			local found = false
			for candidate = 1, count do
				if find(text, list[candidate], 1, true) then
					found = true
					break
				end
			end
			if not found then return 0 end
			score = 1
		end
	end
	return score
end

match.lettersOf = lettersOf

return match
