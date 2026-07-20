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
local ADDR_AREA = PINBALL_GAME + 0x035
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
local CELL_H = PORTRAIT_H + CELL_GAP
local PORTRAIT_DIR = "images/portraits/"
local GRID_MAX_ROWS = 3 -- ceil(9 / GRID_COLUMNS); 9 is the real max pool size (area index 3)

-- Travel diagram (bottom of the side panel): current area's icon at
-- bottom-center, arrows fanning up-left/up-right to the two travel
-- destinations (see readTravelOptions), each icon captioned with its CD
-- progress. Icons are the same 48x32 native size as the spawn-pool
-- portraits, for the same no-lossy-resize reason. Top-row captions sit
-- above their icons (not below) so the arrows can run straight from the
-- bottom icon to the top icons without a caption in the way.
local AREA_ICON_DIR = "images/areas/"
local ARROW_GAP = 14 -- vertical space between the two icon rows
local TRAVEL_DIAGRAM_GAP = 4 -- above the diagram, below the spawn-pool grid
local TRAVEL_DIAGRAM_HEIGHT = LINE_HEIGHT + PORTRAIT_H + ARROW_GAP + PORTRAIT_H + LINE_HEIGHT

local PANEL_TOP_MARGIN, PANEL_BOTTOM_MARGIN = 4, 4

-- Canvas aspect ratio is a deliberate, durable project goal (~16:9 for the
-- full extended play area: native screen + panel) -- see CLAUDE.md. It's
-- been dropped twice now under the assumption it was just an arbitrary
-- one-off heuristic, so: when panel content needs more vertical room than
-- RIGHT_PAD currently supports at 16:9, widen RIGHT_PAD (not just
-- DOWN_PAD) so the canvas grows in both dimensions and stays ~16:9,
-- instead of stretching the panel tall and narrow.
local TARGET_ASPECT_W, TARGET_ASPECT_H = 16, 9

-- What the panel content actually needs, independent of the aspect-ratio
-- goal: grid width (fixed, 3 columns), and full panel height (worst-case
-- grid rows so the layout never shifts between areas, plus the diagram).
local CONTENT_MIN_RIGHT_PAD = GRID_COLUMNS * CELL_W + 8
local CONTENT_MIN_PANEL_HEIGHT = PANEL_TOP_MARGIN + GRID_MAX_ROWS * CELL_H
	+ TRAVEL_DIAGRAM_GAP + TRAVEL_DIAGRAM_HEIGHT + PANEL_BOTTOM_MARGIN

-- Widen RIGHT_PAD past the grid's own minimum only if a 16:9 canvas at
-- CONTENT_MIN_PANEL_HEIGHT would otherwise be narrower than the content
-- needs. Then DOWN_PAD is whatever keeps the *final* RIGHT_PAD at 16:9 --
-- by construction that's always >= CONTENT_MIN_PANEL_HEIGHT, so nothing
-- gets clipped.
local ratioRightPad = math.ceil(CONTENT_MIN_PANEL_HEIGHT * TARGET_ASPECT_W / TARGET_ASPECT_H) - SCREEN_WIDTH
local RIGHT_PAD = math.max(CONTENT_MIN_RIGHT_PAD, ratioRightPad)
local DOWN_PAD = math.ceil((SCREEN_WIDTH + RIGHT_PAD) * TARGET_ASPECT_H / TARGET_ASPECT_W) - SCREEN_HEIGHT

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

-- Species pool for an area, combined across both arrow-states.
local function readSpawnPool(area)
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
end

local function areaIconPath(areaIndex)
	return AREA_ICON_DIR .. AreaIconFiles[areaIndex + 1]
end

local function roundPx(v)
	return math.floor(v + 0.5)
end

-- Every coordinate is rounded to a pixel before gui.drawLine sees it, and
-- the two calls in drawTravelDiagram are fed exact integer mirror images of
-- each other rather than each computing its own geometry independently --
-- both matter for the pair to render as true reflections: at this
-- resolution, two arrows with the "same" geometry but computed separately
-- can each round their floats to a different pixel and end up visibly
-- lopsided.
local function drawArrow(x1, y1, x2, y2, color)
	x1, y1, x2, y2 = roundPx(x1), roundPx(y1), roundPx(x2), roundPx(y2)
	gui.drawLine(x1, y1, x2, y2, color)
	local dx, dy = x2 - x1, y2 - y1
	local len = math.sqrt(dx * dx + dy * dy)
	if len == 0 then
		return
	end
	local ux, uy = dx / len, dy / len
	local px, py = -uy, ux
	local headLen, headWidth = 5, 3
	local bx, by = x2 - ux * headLen, y2 - uy * headLen
	gui.drawLine(x2, y2, roundPx(bx + px * headWidth), roundPx(by + py * headWidth), color)
	gui.drawLine(x2, y2, roundPx(bx - px * headWidth), roundPx(by - py * headWidth), color)
end

-- Caption above, icon below -- so the arrow arriving from below can run
-- straight into the icon's bottom edge with nothing in between.
local function drawDestinationIcon(x, y, areaIndex, cdCount, total)
	gui.drawText(x, y, cdCount .. "/" .. total, "white")
	gui.drawImage(areaIconPath(areaIndex), x, y + LINE_HEIGHT, PORTRAIT_W, PORTRAIT_H)
end

-- Current area's icon at bottom-center, captioned below it; arrows fan
-- up-left/up-right from points 1/5 and 4/5 along its top edge (not its
-- center -- two arrows sharing one origin point read as a single split
-- arrow rather than a pair) to the two travel destinations
-- (readTravelOptions), icons at the arrow tips.
local ARROW_START_INSET = PORTRAIT_W / 5

local function drawTravelDiagram(x, y, width, areaIndex, areaCdCount, areaTotal,
	leftAreaIndex, leftCdCount, leftTotal, rightAreaIndex, rightCdCount, rightTotal)
	local leftX = x
	local rightX = x + width - PORTRAIT_W
	local centerX = x + (width - PORTRAIT_W) / 2
	local topIconY = y + LINE_HEIGHT
	local bottomIconY = topIconY + PORTRAIT_H + ARROW_GAP

	drawDestinationIcon(leftX, y, leftAreaIndex, leftCdCount, leftTotal)
	drawDestinationIcon(rightX, y, rightAreaIndex, rightCdCount, rightTotal)
	gui.drawImage(areaIconPath(areaIndex), centerX, bottomIconY, PORTRAIT_W, PORTRAIT_H)
	gui.drawText(centerX, bottomIconY + PORTRAIT_H, areaCdCount .. "/" .. areaTotal, "white")

	-- Right arrow's true geometry, rounded once; the left arrow is its
	-- exact mirror about the diagram's vertical axis, not a separate
	-- computation -- see drawArrow.
	local axisX = roundPx(centerX + PORTRAIT_W / 2)
	local startY = roundPx(bottomIconY)
	local endY = roundPx(topIconY + PORTRAIT_H)
	local rightStartX = roundPx(centerX + PORTRAIT_W - ARROW_START_INSET)
	local rightEndX = roundPx(rightX + PORTRAIT_W / 2)

	drawArrow(rightStartX, startY, rightEndX, endY, "white")
	drawArrow(2 * axisX - rightStartX, startY, 2 * axisX - rightEndX, endY, "white")
end

-- Right of the game screen, extending down to cover the bottom-right
-- corner: current-encounter info. No area-name header -- the travel
-- diagram's own current-area icon already shows which area this is.
local function drawSidePanel(areaIndex, areaCdCount, areaTotal, pool,
	leftAreaIndex, leftCdCount, leftTotal, rightAreaIndex, rightCdCount, rightTotal)
	local x, y = SCREEN_WIDTH + 4, 4
	local panelHeight = SCREEN_HEIGHT + DOWN_PAD

	gui.drawRectangle(SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight, "white", "black")

	local rows = 0
	for i, entry in ipairs(pool) do
		local col = (i - 1) % GRID_COLUMNS
		local row = math.floor((i - 1) / GRID_COLUMNS)
		rows = math.max(rows, row + 1)
		local cellX = x + col * CELL_W
		local cellY = y + row * CELL_H
		drawPortraitCell(cellX, cellY, entry)
	end
	y = y + rows * CELL_H + TRAVEL_DIAGRAM_GAP

	drawTravelDiagram(x, y, RIGHT_PAD - 8, areaIndex, areaCdCount, areaTotal,
		leftAreaIndex, leftCdCount, leftTotal, rightAreaIndex, rightCdCount, rightTotal)
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
	local pool = readSpawnPool(areaIndex)
	local areaCdCount, areaTotal = readAreaCdProgress(areaIndex)
	local caught = readDexCaughtCount()

	local leftAreaIndex, rightAreaIndex = readTravelOptions()
	local leftCdCount, leftTotal = readAreaCdProgress(leftAreaIndex)
	local rightCdCount, rightTotal = readAreaCdProgress(rightAreaIndex)

	drawSidePanel(areaIndex, areaCdCount, areaTotal, pool,
		leftAreaIndex, leftCdCount, leftTotal, rightAreaIndex, rightCdCount, rightTotal)
	drawBottomBar(caught)
end

while true do
	drawOverlay()
	emu.frameadvance()
end
