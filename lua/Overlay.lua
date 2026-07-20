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
local ADDR_SELECTED_FIELD = GMAIN + 0x04 -- FIELD_RUBY=0 / FIELD_SAPPHIRE=1

-- Travel mode ("go left" / "go right" between areas) resolves its two
-- destinations from PinballGame.areaRouletteNextSlot/FarSlot (indices into
-- gAreaRouletteTable below), not from the current area directly -- see
-- main_board_travel_mode.c:150-153 (left picks NextSlot, anything else picks
-- FarSlot). Both fields are recomputed on every spin/travel and hold valid
-- resting values at all other times, so no board-state staleness gate is
-- needed here (unlike currentSpecies/speciesWeights above).
local ADDR_AREA_ROULETTE_NEXT_SLOT = PINBALL_GAME + 0x033
local ADDR_AREA_ROULETTE_FAR_SLOT = PINBALL_GAME + 0x034

-- Counts travels since the last Ruin visit (reset to 0 at ball start and
-- after each Ruin landing). When this reads 5, the *next* travel is forced
-- to Ruin regardless of NextSlot/FarSlot or which side is hit -- see
-- AREA_ROULETTE_RUIN_SLOT below. The Ruin-override branch never writes
-- NextSlot/FarSlot, so they carry through a Ruin visit unchanged and the
-- travel after that resumes exactly where the skipped normal travel would
-- have left off.
local ADDR_AREA_VISIT_COUNT = PINBALL_GAME + 0x036
local AREA_VISIT_COUNT_FORCES_RUIN = 5

-- gAreaRouletteTable: ROM data, data/rom_1.s:11, abs 0x08055A68. Shape
-- [2 fields][7 slots] of s16 AREA_* values -- slots 0-5 are the normal
-- travel ring per field. Slot 6 is Ruin: reachable both via the e-reader
-- bonus card (as a roulette-spin starting area) AND, unconditionally, as
-- every 6th travel since the last Ruin visit (see AREA_VISIT_COUNT above),
-- independent of the card -- main_board_travel_mode.c:147-163.
local ADDR_AREA_ROULETTE_TABLE = 0x08055A68
local AREA_ROULETTE_TABLE_SLOTS = 7
local AREA_ROULETTE_RUIN_SLOT = 6

local MAIN_BOARD_STATE_CATCH_EM_MODE = 4

-- gWildMonLocations: ROM data, [14 areas][2 arrow-states][8 slots] of u16
-- SPECIES_* values, SPECIES_NONE-padded. Area-major, then two-arrows row,
-- then three-arrows row. See docs/ram-map.md.
local ADDR_WILD_MON_LOCATIONS = 0x08055A84
local WILD_MON_SLOTS_PER_ROW = 8
local WILD_MON_ROW_BYTES = WILD_MON_SLOTS_PER_ROW * 2

-- gSpeciesInfo: ROM data, struct PokemonSpecies[NUM_SPECIES]. Address found
-- empirically (not linker-annotated in source): hex-searched ROM for
-- "TREECKO   " (name field, offset 0x07) and subtracted the offset. Entry
-- stride is 0x18 (24), not the 0x16 (22) the struct's field offsets alone
-- would suggest -- agbcc pads the struct with 2 trailing bytes, confirmed
-- empirically by checking where species index 1 (Grovyle) actually lands.
-- See docs/ram-map.md.
local ADDR_SPECIES_INFO = 0x086A3700
local SPECIES_INFO_ENTRY_BYTES = 0x18
local SPECIES_INFO_EVOLUTION_TARGET_OFFSET = 0x15

local NUM_SPECIES = #SpeciesNames

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
local LINE_HEIGHT = 14

-- Portrait grid for the spawn pool. Source images (lua/images/portraits/,
-- copied from the pinball decomp's graphics/mon_portraits) are 48x32, drawn
-- at native size -- any resize call here is a real, lossy downscale done in
-- software; BizHawk's window zoom afterwards just magnifies whatever pixels
-- we handed it; it can't recover detail a software resize already threw
-- away. So native size + BizHawk's own (nearest-neighbor) window zoom is
-- the only combination that stays crisp. 3 columns needs only 3 rows for
-- the real max pool size of 9 (checked against the ROM's gWildMonLocations
-- table), with room to spare below the grid for future features.
local PORTRAIT_W, PORTRAIT_H = 48, 32
local GRID_COLUMNS = 3
local CELL_GAP = 3
local CELL_W = PORTRAIT_W + CELL_GAP
local CELL_H = PORTRAIT_H + CELL_GAP + 8 -- +8 for optional pct text below
local PORTRAIT_DIR = "images/portraits/"

local RIGHT_PAD = GRID_COLUMNS * CELL_W + 8

-- DOWN_PAD is picked (not derived from grid content, which needs far less)
-- to keep the panel's overall shape close to the established ~16:9 target:
-- (SCREEN_WIDTH + RIGHT_PAD) / (SCREEN_HEIGHT + DOWN_PAD) ~= 16/9.
local DOWN_PAD = math.floor((SCREEN_WIDTH + RIGHT_PAD) * 9 / 16) - SCREEN_HEIGHT

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

-- Portrait filenames are the lowercase species name (spaces/apostrophes/dots
-- stripped) plus "_portrait.png", matching lua/images/portraits/.
local function portraitPath(name)
	local key = name:lower():gsub("[ '.]", "")
	return PORTRAIT_DIR .. key .. "_portrait.png"
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

-- The two areas travel mode would take you to from here: left picks the
-- adjacent ring slot, right skips one -- except when the next travel is the
-- forced 6th-since-Ruin one, where both sides land on Ruin regardless (see
-- AREA_VISIT_COUNT_FORCES_RUIN above). See ADDR_AREA_ROULETTE_NEXT_SLOT
-- comment for why NextSlot/FarSlot are read directly rather than recomputed.
local function readTravelOptions()
	local field = Memory.readbyte(ADDR_SELECTED_FIELD)
	local rowAddr = ADDR_AREA_ROULETTE_TABLE + field * AREA_ROULETTE_TABLE_SLOTS * 2

	if Memory.readbyte(ADDR_AREA_VISIT_COUNT) >= AREA_VISIT_COUNT_FORCES_RUIN then
		local ruinArea = Memory.readword(rowAddr + AREA_ROULETTE_RUIN_SLOT * 2)
		return ruinArea, ruinArea
	end

	local leftSlot = Memory.readbyte(ADDR_AREA_ROULETTE_NEXT_SLOT)
	local rightSlot = Memory.readbyte(ADDR_AREA_ROULETTE_FAR_SLOT)
	local leftArea = Memory.readword(rowAddr + leftSlot * 2)
	local rightArea = Memory.readword(rowAddr + rightSlot * 2)
	return leftArea, rightArea
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

-- Species pool for an area, combined across both arrow-states. When
-- withWeights is true (MAIN_BOARD_STATE_CATCH_EM_MODE), each entry also gets
-- the game's own live pick-chance % from PinballGame.speciesWeights[], only
-- for species in the currently-active arrows row (the inactive row isn't
-- selectable right now, so a % for it would be meaningless).
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
			rare = RARE_SPECIES[entry.species] or false,
			pct = withWeights and pctBySpecies[entry.species] or nil,
		}
	end
	return pool
end

-- A colored border around a caught species' portrait, instead of a
-- translucent dim overlay: dimming (even with a wide alpha gap between the
-- two states) read as barely-different at a glance against portraits with
-- such varied source brightness/color, and the most visible part of it
-- turned out to be the 1px undimmed edge left at the portrait's border --
-- which is the tell that a deliberate, saturated border reads far more
-- clearly than tinting the whole image ever did. Green once the whole
-- evolution line is caught (D, no longer worth pursuing); orange while
-- just this species is caught but the line isn't finished (C); black
-- (currently invisible against the panel's own black background, but
-- explicit so it'll show correctly if that background ever changes) when
-- not caught at all.
local BORDER_COLOR_LINE_CAUGHT = 0xFF34C759
local BORDER_COLOR_CAUGHT = 0xFFFF9500
local BORDER_COLOR_UNCAUGHT = 0xFF000000

-- gui.drawRectangle's width/height are corner-to-corner (the right/bottom
-- border line lands at x+width, y+height), not a pixel count the way
-- drawImage's w/h are -- so this only needs +1, not +2, to sit flush
-- against a portrait occupying columns/rows [x, x+w) / [y, y+h).
local function drawPortraitBorder(x, y, w, h, color)
	gui.drawRectangle(x - 1, y - 1, w + 1, h + 1, color, nil)
end

-- Corner flags are plain solid-color squares, not icons or digits: at this
-- pixel budget, shapes/glyphs don't read cleanly -- an "ellipse" this small
-- rendered as a square anyway, and drawText numerals were illegible.
-- Colors are chosen so none of the three collide with each other.
local MARKER_SIZE = 8
local RARE_MARKER_COLOR = 0xFFFFD700 -- gold
local TWO_EXCLUSIVE_MARKER_COLOR = 0xFF2E9BFF -- blue
local THREE_EXCLUSIVE_MARKER_COLOR = 0xFFFF3B30 -- red

local function drawMarker(x, y, color)
	gui.drawRectangle(x, y, MARKER_SIZE, MARKER_SIZE, "black", color)
end

local function drawPortraitCell(x, y, entry)
	gui.drawImage(portraitPath(entry.name), x, y, PORTRAIT_W, PORTRAIT_H)

	local borderColor = BORDER_COLOR_UNCAUGHT
	if entry.caught then
		borderColor = entry.lineCaught and BORDER_COLOR_LINE_CAUGHT or BORDER_COLOR_CAUGHT
	end
	drawPortraitBorder(x, y, PORTRAIT_W, PORTRAIT_H, borderColor)

	local exclusiveColor = nil
	if entry.exclusive == "2" then
		exclusiveColor = TWO_EXCLUSIVE_MARKER_COLOR
	elseif entry.exclusive == "3" then
		exclusiveColor = THREE_EXCLUSIVE_MARKER_COLOR
	end

	-- Both markers default to the top-left corner, since a species being
	-- both rare and arrow-exclusive never actually happens in this game's
	-- data (checked against the ROM directly). Only fall back to top-right
	-- for the rare one in the case that it somehow does, so they don't
	-- overlap.
	if entry.rare and exclusiveColor then
		drawMarker(x - 2, y - 2, RARE_MARKER_COLOR)
		drawMarker(x + PORTRAIT_W - MARKER_SIZE + 2, y - 2, exclusiveColor)
	elseif entry.rare then
		-- R: rare, still worth flagging as a former/current priority target
		-- even once caught -- there's no need to hide it once caught the
		-- way the C mark does, since it's not competing for the same corner.
		drawMarker(x - 2, y - 2, RARE_MARKER_COLOR)
	elseif exclusiveColor then
		drawMarker(x - 2, y - 2, exclusiveColor)
	end

	if entry.pct then
		gui.drawText(x, y + PORTRAIT_H, string.format("%.0f%%", entry.pct), "white", nil, 7)
	end
end

-- Right of the game screen, extending down to cover the bottom-right
-- corner: current-encounter info.
local function drawSidePanel(area, areaCdCount, areaTotal, pool, leftArea, leftCdCount, leftTotal, rightArea, rightCdCount, rightTotal)
	local x, y = SCREEN_WIDTH + 4, 4
	local panelHeight = SCREEN_HEIGHT + DOWN_PAD

	gui.drawRectangle(SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight, "white", "black")

	gui.drawText(x, y, shortAreaName(area) .. " " .. areaCdCount .. "/" .. areaTotal, "white")
	y = y + LINE_HEIGHT * 1.5

	local rows = 0
	for i, entry in ipairs(pool) do
		local col = (i - 1) % GRID_COLUMNS
		local row = math.floor((i - 1) / GRID_COLUMNS)
		rows = math.max(rows, row + 1)
		local cellX = x + col * CELL_W
		local cellY = y + row * CELL_H
		drawPortraitCell(cellX, cellY, entry)
	end
	y = y + rows * CELL_H + LINE_HEIGHT * 0.5

	-- Travel destinations, below the grid: which area you'd land in going
	-- left vs. right from here, plus each one's own CD progress, so you can
	-- tell at a glance which direction is worth heading toward.
	gui.drawText(x, y, "<- " .. shortAreaName(leftArea) .. " " .. leftCdCount .. "/" .. leftTotal, "white")
	y = y + LINE_HEIGHT
	gui.drawText(x, y, "-> " .. shortAreaName(rightArea) .. " " .. rightCdCount .. "/" .. rightTotal, "white")
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

	local leftAreaIndex, rightAreaIndex = readTravelOptions()
	local leftArea = AreaNames[leftAreaIndex + 1] or "?"
	local rightArea = AreaNames[rightAreaIndex + 1] or "?"
	local leftCdCount, leftTotal = readAreaCdProgress(leftAreaIndex)
	local rightCdCount, rightTotal = readAreaCdProgress(rightAreaIndex)

	drawSidePanel(area, areaCdCount, areaTotal, pool, leftArea, leftCdCount, leftTotal, rightArea, rightCdCount, rightTotal)
	drawBottomBar(caught)
end

while true do
	drawOverlay()
	emu.frameadvance()
end
