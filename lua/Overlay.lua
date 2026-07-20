-- Pokedex-completion overlay for Pokemon Pinball: Ruby & Sapphire, for use
-- with BizHawk's mGBA core. See docs/ram-map.md for the addresses used here.
--
-- Canvas wraps the native 240x160 GBA screen with a side panel (right of the
-- screen, full canvas height -- takes the bottom-right corner) for
-- current-encounter info, and a bottom bar (below the screen, only as wide
-- as the screen itself) for persistent totals. Only shows info that isn't
-- already visible in the game's own UI.

dofile("Memory.lua")
dofile("Data.lua")

local GMAIN = 0x0200B0C0
local ADDR_POKEDEX_FLAGS = GMAIN + 0x74 -- [NUM_SPECIES], one byte per species

local PINBALL_GAME = 0x02000000
local ADDR_BOARD_STATE = PINBALL_GAME + 0x013
local ADDR_AREA = PINBALL_GAME + 0x035
local ADDR_CATCH_MODE_ARROWS = PINBALL_GAME + 0x73D
local ADDR_TOTAL_WEIGHT = PINBALL_GAME + 0x12E
local ADDR_SPECIES_WEIGHTS = PINBALL_GAME + 0x130 -- s16[25], cumulative; only [0..7] are meaningful in catch-em mode

local MAIN_BOARD_STATE_CATCH_EM_MODE = 4

-- gWildMonLocations: ROM data, [14 areas][2 arrow-states][8 slots] of u16
-- SPECIES_* values, SPECIES_NONE-padded. Area-major, then two-arrows row,
-- then three-arrows row. See docs/ram-map.md.
local ADDR_WILD_MON_LOCATIONS = 0x08055A84
local WILD_MON_SLOTS_PER_ROW = 8
local WILD_MON_ROW_BYTES = WILD_MON_SLOTS_PER_ROW * 2

-- gSpeciesInfo: ROM data, struct PokemonSpecies[NUM_SPECIES], 0x16 bytes each.
-- Address found empirically (not linker-annotated in source): hex-searched
-- ROM for "TREECKO   " (name field, offset 0x07) and subtracted the offset.
-- See docs/ram-map.md.
local ADDR_SPECIES_INFO = 0x086A3700
local SPECIES_INFO_ENTRY_BYTES = 0x16
local SPECIES_INFO_EVOLUTION_TARGET_OFFSET = 0x15

local NUM_SPECIES = #SpeciesNames

-- gCommonAndEggWeights (data/rom_2.s), indexed by pokedex flag (0=unseen,
-- 1=seen, 2=shared, 3=shared+seen, 4=caught). See docs/ram-map.md.
local COMMON_AND_EGG_WEIGHTS = { 10, 10, 15, 15, 2 }

-- The hardcoded rare-species set from BuildSpeciesWeightsForCatchEmMode
-- (src/main_board_catch_hatch_picker.c:176-185), species.h numbering.
local RARE_SPECIES = {
	[59] = true, -- Nosepass
	[114] = true, -- Skarmory
	[132] = true, -- Lileep
	[134] = true, -- Anorith
	[139] = true, -- Feebas
	[141] = true, -- Castform
	[144] = true, -- Kecleon
	[151] = true, -- Absol
	[160] = true, -- Wobbuffet
}

local SCREEN_WIDTH = 240
local SCREEN_HEIGHT = 160
local RIGHT_PAD = 120
local DOWN_PAD = 55
local LINE_HEIGHT = 14

client.SetGameExtraPadding(0, 0, RIGHT_PAD, DOWN_PAD)

local function readDexCaughtCount()
	local caught = 0
	for i = 0, NUM_SPECIES - 1 do
		if Memory.readbyte(ADDR_POKEDEX_FLAGS + i) == PokedexFlag.CAUGHT then
			caught = caught + 1
		end
	end
	return caught
end

local function speciesName(index)
	if index >= 0 and index < NUM_SPECIES then
		return SpeciesNames[index + 1]
	end
	return "-"
end

-- AreaNames disambiguates Ruby/Sapphire for data indexing, but the current
-- field is always visible in-game, so strip the suffix for display.
local function shortAreaName(name)
	local stripped = name:gsub(" %(Ruby%)", ""):gsub(" %(Sapphire%)", "")
	return stripped
end

local function isCaught(species)
	return Memory.readbyte(ADDR_POKEDEX_FLAGS + species) == PokedexFlag.CAUGHT
end

local function evolutionTarget(species)
	return Memory.readbyte(ADDR_SPECIES_INFO + species * SPECIES_INFO_ENTRY_BYTES + SPECIES_INFO_EVOLUTION_TARGET_OFFSET)
end

local function pokedexFlag(species)
	return Memory.readbyte(ADDR_POKEDEX_FLAGS + species)
end

local function commonAndEggWeight(species)
	return COMMON_AND_EGG_WEIGHTS[pokedexFlag(species) + 1]
end

-- Approximates BuildSpeciesWeightsForCatchEmMode's weight (see docs/ram-map.md)
-- with the adjustments it doesn't need for our purposes stripped out: no
-- E-Reader bonus doubling, no caughtMonCount==0 zeroing, no lastCatchSpecies
-- exclusion, and the Clamperl 3-way special case is skipped (treated as a
-- default species). Good enough to tell rare species apart from common ones
-- when the game's own live weights aren't available (i.e. outside catch mode).
local function baseWeight(species)
	if RARE_SPECIES[species] then
		if pokedexFlag(species) < PokedexFlag.SHARED then
			return 1
		end
		return 2
	end

	local weight = commonAndEggWeight(species)
	local current = species
	for _ = 1, 2 do
		local target = evolutionTarget(current)
		if target >= NUM_SPECIES then
			break
		end
		local evolutionWeight = commonAndEggWeight(target)
		if evolutionWeight > weight then
			weight = evolutionWeight
		end
		current = target
	end
	return weight
end

-- Mirrors the up-to-2-step evolution walk in BuildSpeciesWeightsForCatchEmMode
-- (not the Clamperl 3-way special case). True when species and every step of
-- its evolution line are already caught, i.e. it's stuck at minimum weight.
local function isEvolutionLineCaught(species)
	if not isCaught(species) then
		return false
	end
	local current = species
	for _ = 1, 2 do
		local target = evolutionTarget(current)
		if target >= NUM_SPECIES then
			break
		end
		if not isCaught(target) then
			return false
		end
		current = target
	end
	return true
end

-- Every species that can spawn in an area, across both arrow-states, each
-- tagged with which row(s) it appears in (three-arrows rows are a superset
-- of the two-arrows rows in practice, but this doesn't assume that -- it
-- just unions both, deduplicated).
local function readAreaSpeciesRows(area)
	local bySpecies = {}
	local list = {}
	for rowIndex = 0, 1 do
		local rowAddr = ADDR_WILD_MON_LOCATIONS + (area * 2 + rowIndex) * WILD_MON_ROW_BYTES
		for slot = 0, WILD_MON_SLOTS_PER_ROW - 1 do
			local species = Memory.readword(rowAddr + slot * 2)
			if species < NUM_SPECIES then
				local entry = bySpecies[species]
				if not entry then
					entry = { species = species, inTwoArrows = false, inThreeArrows = false }
					bySpecies[species] = entry
					list[#list + 1] = entry
				end
				if rowIndex == 0 then
					entry.inTwoArrows = true
				else
					entry.inThreeArrows = true
				end
			end
		end
	end
	return list
end

local function readAreaSpeciesSet(area)
	local list = {}
	for _, entry in ipairs(readAreaSpeciesRows(area)) do
		list[#list + 1] = entry.species
	end
	return list
end

-- Every species in speciesList, plus every step of each one's evolution line
-- (up to 2 hops, matching the game's own lookahead depth), deduplicated.
local function expandWithEvolutions(speciesList)
	local seenSpecies = {}
	local expanded = {}
	local function addUnique(species)
		if not seenSpecies[species] then
			seenSpecies[species] = true
			expanded[#expanded + 1] = species
		end
	end
	for _, species in ipairs(speciesList) do
		addUnique(species)
		local current = species
		for _ = 1, 2 do
			local target = evolutionTarget(current)
			if target >= NUM_SPECIES then
				break
			end
			addUnique(target)
			current = target
		end
	end
	return expanded
end

-- How many species you'd still need to obtain (by catch or evolution) to get
-- everything catchable in this area to CD: every base species catchable here
-- plus every step of each one's evolution line, vs. how many of those are
-- already caught.
local function readAreaCdProgress(area)
	local expanded = expandWithEvolutions(readAreaSpeciesSet(area))
	local caughtCount = 0
	for _, species in ipairs(expanded) do
		if isCaught(species) then
			caughtCount = caughtCount + 1
		end
	end
	return caughtCount, #expanded
end

-- Species pool for an area, combined across both arrow-states.
--   - withWeights true: shows the game's own live pick-chance % from
--     PinballGame.speciesWeights[] (only valid while boardState is
--     MAIN_BOARD_STATE_CATCH_EM_MODE -- see docs/ram-map.md), only for
--     species in the currently-active arrows row (the inactive row isn't
--     selectable right now, so a % for it would be meaningless).
--   - withWeights false: no live data available, so shows our own
--     baseWeight() approximation instead -- as a raw weight, not a %, since
--     it's not normalized against a specific row's total the way the game's
--     real pick chance is. Shown for every species regardless of row, since
--     baseWeight() doesn't depend on which row is active.
local function readSpawnPool(area, threeArrowsLit, withWeights)
	local pctBySpecies = {}
	if withWeights then
		local activeRowIndex = threeArrowsLit and 1 or 0
		local activeRowAddr = ADDR_WILD_MON_LOCATIONS + (area * 2 + activeRowIndex) * WILD_MON_ROW_BYTES
		local totalWeight = Memory.readword(ADDR_TOTAL_WEIGHT)
		local prevCumWeight = 0
		for slot = 0, WILD_MON_SLOTS_PER_ROW - 1 do
			local species = Memory.readword(activeRowAddr + slot * 2)
			local cumWeight = Memory.readword(ADDR_SPECIES_WEIGHTS + slot * 2)
			if totalWeight > 0 and species < NUM_SPECIES then
				pctBySpecies[species] = (cumWeight - prevCumWeight) / totalWeight * 100
			end
			prevCumWeight = cumWeight
		end
	end

	local pool = {}
	for _, entry in ipairs(readAreaSpeciesRows(area)) do
		local exclusive = "-"
		if entry.inTwoArrows and not entry.inThreeArrows then
			exclusive = "2"
		elseif entry.inThreeArrows and not entry.inTwoArrows then
			exclusive = "3"
		end
		pool[#pool + 1] = {
			name = speciesName(entry.species),
			exclusive = exclusive,
			caught = isCaught(entry.species),
			lineCaught = isEvolutionLineCaught(entry.species),
			pct = withWeights and pctBySpecies[entry.species] or nil,
			weight = (not withWeights) and baseWeight(entry.species) or nil,
		}
	end
	return pool
end

-- Right of the game screen, extending down to cover the bottom-right
-- corner: current-encounter info.
local function drawSidePanel(area, areaCdCount, areaTotal, pool)
	local x, y = SCREEN_WIDTH + 4, 4
	local panelHeight = SCREEN_HEIGHT + DOWN_PAD

	gui.drawRectangle(SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight, "white", "black")

	gui.drawText(x, y, shortAreaName(area) .. " " .. areaCdCount .. "/" .. areaTotal, "white")
	y = y + LINE_HEIGHT * 1.5

	gui.drawText(x, y, "Possible spawns:", "white")
	y = y + LINE_HEIGHT
	for _, entry in ipairs(pool) do
		local marks = entry.exclusive .. (entry.caught and "C" or "-") .. (entry.lineCaught and "D" or "-")
		local line = marks .. " " .. entry.name
		if entry.pct then
			line = line .. string.format(" (%.1f%%)", entry.pct)
		elseif entry.weight then
			line = line .. " (" .. entry.weight .. ")"
		end
		gui.drawText(x, y, line, "white")
		y = y + LINE_HEIGHT
	end
end

-- Below the game screen only (side panel claims the corner): persistent
-- totals not otherwise shown in-game.
local function drawBottomBar(caught)
	local y = SCREEN_HEIGHT + 4

	gui.drawRectangle(0, SCREEN_HEIGHT, SCREEN_WIDTH, DOWN_PAD, "white", "black")

	gui.drawText(4, y, "Dex caught: " .. caught .. "/" .. NUM_SPECIES, "white")
end

local function drawOverlay()
	local areaIndex = Memory.readbyte(ADDR_AREA)
	local area = AreaNames[areaIndex + 1] or "?"
	local threeArrowsLit = Memory.readbyte(ADDR_CATCH_MODE_ARROWS) == 3
	local inCatchEmMode = Memory.readbyte(ADDR_BOARD_STATE) == MAIN_BOARD_STATE_CATCH_EM_MODE
	local pool = readSpawnPool(areaIndex, threeArrowsLit, inCatchEmMode)
	local areaCdCount, areaTotal = readAreaCdProgress(areaIndex)
	local caught = readDexCaughtCount()

	drawSidePanel(area, areaCdCount, areaTotal, pool)
	drawBottomBar(caught)
end

while true do
	drawOverlay()
	emu.frameadvance()
end
