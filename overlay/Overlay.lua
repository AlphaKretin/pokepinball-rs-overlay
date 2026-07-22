-- Pokedex-completion overlay for Pokemon Pinball: Ruby & Sapphire, for use
-- with BizHawk's mGBA core. See docs/memory-map.md for the addresses used here.
--
-- Canvas wraps the native 240x160 GBA screen with a right panel (full
-- canvas height -- takes the bottom-right corner, field-wide egg-hatch
-- pool) and a region below the screen, only as wide as the screen itself
-- (current-encounter spawn pool). Only shows info that isn't already
-- visible in the game's own UI.
--
-- IMPORTANT: gui.draw* coordinates are relative to the *padded canvas's*
-- own top-left (0,0), not the game screen's -- client.SetGameExtraPadding
-- shifts the emulated screen itself right/down by (LEFT_PAD, TOP_PAD)
-- within that canvas, it doesn't move the drawing origin. Confirmed live in
-- BizHawk (LEFT_PAD used to be assumed screen-relative -- i.e. drawing the
-- left panel at negative x, and the right panel/bottom bar at x=0/
-- x=SCREEN_WIDTH -- which put the left panel entirely off-canvas and the
-- right panel drawing over the middle of the shifted game screen instead of
-- the actual padding area). GAME_X below is the correction: every
-- game-relative draw call needs to add it now that LEFT_PAD is nonzero.

dofile("Memory.lua")
dofile("Data.lua")
dofile("GfxExtract.lua")

-- Self-extracts area/portrait/egg-hatch icons straight from the loaded ROM
-- on first launch (no-op on every launch after) -- see GfxExtract.lua. Must
-- run before any gui.drawImage call below expects these files to exist.
GfxExtract.ensureAll()

local GMAIN = 0x0200B0C0
local ADDR_POKEDEX_FLAGS = GMAIN + 0x74 -- [NUM_SPECIES], one byte per species

local PINBALL_GAME = 0x02000000
local ADDR_AREA = PINBALL_GAME + 0x035
local ADDR_SELECTED_FIELD = GMAIN + 0x04 -- FIELD_RUBY=0 / FIELD_SAPPHIRE=1
local VALID_FIELDS = { [0] = true, [1] = true }

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
-- then three-arrows row. See docs/memory-map.md.
local ADDR_WILD_MON_LOCATIONS = 0x08055A84
local WILD_MON_SLOTS_PER_ROW = 8
local WILD_MON_ROW_BYTES = WILD_MON_SLOTS_PER_ROW * 2

-- gEggLocations: ROM data, [2 fields][26 slots] of u16 SPECIES_* values,
-- field-major (Ruby row, then Sapphire). Not linker-annotated in source
-- (src/data/egg_locations.h is plain C data, unlike gWildMonLocations'
-- data/mon_locations.inc) -- address found empirically, same approach as
-- ADDR_SPECIES_INFO below: hex-searched the ROM for the Ruby row's first 10
-- species IDs as a little-endian u16 sequence, found a unique match, then
-- confirmed the following 52 halfwords match both full field rows from the
-- decomp source exactly. See docs/memory-map.md and for the search itself.
--
-- Only slots 0-24 are real per-field spawns -- BuildSpeciesWeightsForEggMode
-- only loops `i < 25`, matching AREA_VISIT_COUNT_FORCES_RUIN-style ROM
-- lookahead elsewhere in this file. Slot 25 is Pichu, present in the data
-- but unused by that loop (Pichu is a separate forced-rare pick, not a
-- table-driven spawn) -- deliberately not read here, see the plan doc for
-- why Pichu/other forced-rare specials are out of scope for this feature.
local ADDR_EGG_LOCATIONS = 0x086A4A38
local EGG_LOCATIONS_ROW_SLOTS = 26
local EGG_LOCATIONS_ROW_BYTES = EGG_LOCATIONS_ROW_SLOTS * 2
local EGG_POOL_SIZE = 25

-- gSpeciesInfo: ROM data, struct PokemonSpecies[NUM_SPECIES]. Address found
-- empirically (not linker-annotated in source): hex-searched ROM for
-- "TREECKO   " (name field, offset 0x07) and subtracted the offset. Entry
-- stride is 0x18 (24), not the 0x16 (22) the struct's field offsets alone
-- would suggest -- agbcc pads the struct with 2 trailing bytes, confirmed
-- empirically by checking where species index 1 (Grovyle) actually lands.
-- See docs/memory-map.md.
local ADDR_SPECIES_INFO = 0x086A3700
local SPECIES_INFO_ENTRY_BYTES = 0x18
local SPECIES_INFO_EVOLUTION_TARGET_OFFSET = 0x15

-- PinballGame.evolvablePartySpecies[MAX_EVOLVABLE_PARTY_SIZE=16] / .size:
-- the queue of caught/hatched species currently awaiting Evolution Mode
-- (include/global.h:363/365). A species being caught (dex "C") doesn't mean
-- *this session's* catch is still sitting in this queue -- it may already
-- have evolved, or never have been queued this session at all. See
-- docs/memory-map.md's Evolution Mode section.
local ADDR_EVOLVABLE_PARTY_SPECIES = PINBALL_GAME + 0x270
local ADDR_EVOLVABLE_PARTY_SIZE = PINBALL_GAME + 0x281
local MAX_EVOLVABLE_PARTY_SIZE = 16

local NUM_SPECIES = #SpeciesNames

-- The last 4 species.h entries (Chikorita/Cyndaquil/Totodile/Aerodactyl) are
-- only reachable via e-Reader card scan or Pokedex data trade -- no in-game
-- path exists for them in single-player (see PickSpeciesForCatchEmMode's
-- specialMons[] build, which only adds them if their dex flag is already
-- nonzero -- nothing else ever sets it). Excluded from the displayed dex
-- total for that reason; still present/indexed in SpeciesNames as normal
-- (ROM-dictated positions), only DEX_DISPLAY_TOTAL below is affected.
local NUM_EREADER_ONLY_SPECIES = 4
local DEX_DISPLAY_TOTAL = NUM_SPECIES - NUM_EREADER_ONLY_SPECIES

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

-- Deferred edge-case specials:
-- Pichu (rare egg spawn), Latios/Latias (rare catch spawn, field-exclusive),
-- Groudon/Kyogre (bonus-game reward, field-exclusive), Rayquaza (bonus-game
-- reward, either field). species.h numbering, matches SpeciesNames order.
local SPECIES_PICHU = 154
local SPECIES_LATIAS = 195
local SPECIES_LATIOS = 196
local SPECIES_KYOGRE = 197
local SPECIES_GROUDON = 198
local SPECIES_RAYQUAZA = 199

-- caughtMonCount: PinballGame+0x5F0, u16, per-game-session catch count (not
-- a dex total) -- gates both Pichu and Latios/Latias's forced-rare rolls
-- (PickSpeciesForEggMode/PickSpeciesForCatchEmMode, both require >= 5).
local ADDR_CAUGHT_MON_COUNT = PINBALL_GAME + 0x5F0
local RARE_SPECIAL_MIN_CAUGHT_THIS_GAME = 5

-- gBoardConfig.caughtSpeciesCount: not reachable via PINBALL_GAME/GMAIN --
-- BoardConfig is its own fixed-address EWRAM struct (sym_ewram.txt:574),
-- holding a *pointer* to PinballGame (BoardConfig+0x0C), not the reverse.
-- Gates Latios/Latias's forced-rare roll (>= 100) -- no equivalent gate
-- exists for Pichu, confirmed against PickSpeciesForEggMode.
local ADDR_BOARD_CONFIG = 0x02031520
local ADDR_CAUGHT_SPECIES_COUNT = ADDR_BOARD_CONFIG + 0x08
local LATI_MIN_CAUGHT_SPECIES = 100

-- gMain.eReaderBonuses[EREADER_ENCOUNTER_RATE_UP_CARD]: GMAIN+0x07 (array
-- base) + index 1. Despite the name, unrelated to Rayquaza specifically --
-- it's the e-Reader "Encounter Rate Up" card flag, permanently set once
-- numCompletedBonusStages > 4 (any mix of bonus stages) or via the actual
-- card scan. Confirmed it swaps Latios/Latias's roll 1%->2% but Pichu's
-- 2%->1% -- opposite directions on the same flag, reads as an
-- inverted-constant bug rather than intent. Kept the "Rayquaza flag" name in
-- comments/UI since that's the working name Luna already uses for it.
local ADDR_ENCOUNTER_RATE_UP_FLAG = GMAIN + 0x08

local SCREEN_WIDTH = 240
local SCREEN_HEIGHT = 160
local LINE_HEIGHT = 14

-- Portrait grid for the spawn pool. Source images (images/portraits/,
-- self-extracted from ROM by GfxExtract.lua) are 48x32, drawn
-- at native size -- any resize call here is a real, lossy downscale done in
-- software; BizHawk's window zoom afterwards just magnifies whatever pixels
-- we handed it; it can't recover detail a software resize already threw
-- away. So native size + BizHawk's own (nearest-neighbor) window zoom is
-- the only combination that stays crisp.
local PORTRAIT_W, PORTRAIT_H = 48, 32
-- 4 columns, not 3: per-area distinct pool sizes are 4, 7, 8, or 9 (checked
-- against the ROM's gWildMonLocations table). At 3 columns, 5 of 14 areas
-- (the three 7-pools and two 4-pools) got a lonely single-portrait final
-- row; at 4, only the one true 9-outlier (Plains Sapphire, no natural
-- "odd one out" species to special-case away) would wrap to a partial 3rd
-- row, and 8 areas land exactly at a zero-slack 8 (2 full rows). That one
-- 9-case is handled by widening its last row to 5 instead of adding a 3rd
-- row (see spawnGridCell) -- worst-case row reserve (GRID_MAX_ROWS below)
-- is therefore 2, not 3, saving a full row's height off the panel that
-- reserve drives for every area, not just the 9-case.
local GRID_COLUMNS = 4
local CELL_GAP = 3
local CELL_W = PORTRAIT_W + CELL_GAP
local CELL_H = PORTRAIT_H + CELL_GAP
local PORTRAIT_DIR = "images/portraits/"
local GRID_MAX_ROWS = 2 -- see spawnGridCell -- the 9-case widens its last row instead of adding a 3rd

-- Travel diagram (bottom of the right flange, beside the spawn-pool grid
-- below the screen): current area's icon at bottom-center, arrows fanning
-- up-left/up-right to the two travel destinations (see readTravelOptions),
-- each icon captioned with its CD progress as a small fraction beside it
-- (see drawCdStack), not above/below it. Icons are the same 48x32 native
-- size as the spawn-pool portraits, for the same no-lossy-resize reason.
-- Drawn at its own natural content width (see TRAVEL_DIAGRAM_WIDTH below),
-- not stretched to fill the flange
local AREA_ICON_DIR = "images/areas/"
local ARROW_GAP = 14 -- vertical space between the two icon rows
-- No LINE_HEIGHT rows above/below the icons anymore -- CD counts are a
-- tight fraction beside each icon instead of a caption above/below it (see
-- drawCdStack), which is what made the diagram taller than the "two rows
-- of icons" concept alone would suggest.
local TRAVEL_DIAGRAM_HEIGHT = PORTRAIT_H + ARROW_GAP + PORTRAIT_H
-- Natural width: two PORTRAIT_W icons plus a gap wide enough for the
-- fanned arrows between them to read clearly -- matches the width the
-- diagram used to get for free back when the right flange's content-min
-- was itself grid-driven (3-column spawn grid), before that content moved
-- elsewhere.
local TRAVEL_DIAGRAM_WIDTH = 2 * PORTRAIT_W + 57
-- Real measured metrics for gui.drawText's default font (Luna measured
-- these live in BizHawk, at 1x scale): a digit glyph's own visible pixels
-- are 9px tall, but they don't start right at the y passed to drawText --
-- there's a further 3px gap above the glyph before its visible pixels
-- begin. Confirmed via the fraction line: with the naive "row height =
-- glyph height" model, the numerator-to-line gap measured 2px live while
-- the line-to-denominator gap measured 5px, a 3px mismatch consistent with
-- exactly one glyph's worth of this offset applying to the denominator's
-- draw call but not being accounted for. This offset is a BizHawk
-- drawText-positioning detail, not padding baked into the font itself
-- (confirmed no such padding exists vertically, unlike the horizontal
-- monospacing case CD_CHAR_WIDTH accounts for).
local CD_GLYPH_HEIGHT = 9
local CD_GLYPH_Y_OFFSET = 3
-- Desired visible gap between a glyph's own pixels and the fraction line,
-- the same on both sides.
local CD_STACK_LINE_GAP = 2
-- Per-character advance for BizHawk's default gui.drawText font -- same
-- font LINE_HEIGHT was originally tuned against. Used to size each
-- fraction to its actual digit count (rather than a fixed reserved box)
-- so the gap to the icon comes out the same on both sides regardless of
-- whether it's showing "9/14" or "13/14" -- a fixed-width reservation on
-- one side only (an earlier version of this) made that side's text
-- overflow into the icon on wide numbers while the other side's gap
-- stayed loose. May need live tuning against the font's actual advance.
local CD_CHAR_WIDTH = 10
local CD_STACK_GAP = 2 -- gap between an icon's edge and its fraction

-- Egg-hatch grid (right panel): field-wide (not area-scoped, see
-- egg-hatch-panel plan). Icons self-extracted from ROM by GfxExtract.lua --
-- 24x24 native size (frame 0 of each species' hatch-animation sprite), same no-lossy-resize
-- reasoning as the portrait grid. Exactly 25 real per-field egg spawns
-- (EGG_POOL_SIZE) makes a clean 5x5 grid with no leftover slot -- Pichu
-- (the table's 26th, unused slot) is deliberately excluded, see the plan.
local EGG_ICON_W, EGG_ICON_H = 24, 24
local EGG_GRID_COLUMNS = 5
local EGG_CELL_GAP = 3
local EGG_CELL_W = EGG_ICON_W + EGG_CELL_GAP
local EGG_CELL_H = EGG_ICON_H + EGG_CELL_GAP
local EGG_ICON_DIR = "images/egg_hatch/"
local EGG_GRID_ROWS = math.ceil(EGG_POOL_SIZE / EGG_GRID_COLUMNS)

-- Edge-case specials column (right panel, right of the egg grid/travel
-- diagram content. Same --native 48x32 portraits as the spawn grid 
-- (already present in images/portraits/ for all 6 species involved), 
-- stacked in one column rather than a grid since there are only 4 entries.
local SPECIAL_CELL_GAP = 3
local SPECIAL_CELL_H = PORTRAIT_H + SPECIAL_CELL_GAP
local SPECIAL_COLUMN_GAP = 4 -- gap between the egg/travel content and this column

local PANEL_TOP_MARGIN, PANEL_BOTTOM_MARGIN = 4, 4

local TARGET_ASPECT_W, TARGET_ASPECT_H = 16, 9

-- What each region's content actually needs, independent of the
-- aspect-ratio goal. Right flange holds the egg-hatch grid (top-anchored)
-- plus the dex-caught line and the travel diagram (bottom-anchored, beside
-- the spawn-pool grid which sits below the screen at the same height).
-- Egg grid's more compact, square shape suits the flange's top far better
-- than the spawn grid used to. 
-- Unchanged from before the specials column was added: the column doesn't
-- need its own content-min term. It's top-anchored right next to the egg
-- grid (SPECIAL_COLUMN_X further down, based on the egg grid's own width,
-- not this max) and, confirmed live, already fits within the width this
-- term already reserves for the wider of the two existing terms (the travel
-- diagram) plus the ~37px of 16:9 ratio slack -- no extra width needed.
local CONTENT_MIN_RIGHT_PAD = math.max(EGG_GRID_COLUMNS * EGG_CELL_W + 8, TRAVEL_DIAGRAM_WIDTH + 8)
-- Similarly unaffected: the column's own height (4 * SPECIAL_CELL_H = 137,
-- + margins = 145) is less than the egg grid's (143)... close, but even the
-- 2px difference doesn't matter -- minCanvasHeight below is always governed
-- by the below-screen region (246) either way. Kept as a plain single term,
-- not maxed against the column, to match "no new content-min term" above.
local CONTENT_MIN_RIGHT_PANEL_HEIGHT = PANEL_TOP_MARGIN + EGG_GRID_ROWS * EGG_CELL_H + PANEL_BOTTOM_MARGIN
-- Dex-caught line isn't factored in above: it sits between the egg grid's
-- bottom and SCREEN_HEIGHT, and that gap (SCREEN_HEIGHT - the egg content
-- height above) is already >= one text line without needing its own
-- content-min term -- see drawEggPanel.
local CONTENT_MIN_SPAWN_HEIGHT = PANEL_TOP_MARGIN + GRID_MAX_ROWS * CELL_H + PANEL_BOTTOM_MARGIN
local CONTENT_MIN_TRAVEL_HEIGHT = PANEL_TOP_MARGIN + TRAVEL_DIAGRAM_HEIGHT + PANEL_BOTTOM_MARGIN
-- Spawn grid and travel diagram sit side by side in the same y-band (both
-- below SCREEN_HEIGHT), so whichever needs more height governs, same
-- reasoning as the two-flange max used to use.
local CONTENT_MIN_BELOW_SCREEN_HEIGHT = math.max(CONTENT_MIN_SPAWN_HEIGHT, CONTENT_MIN_TRAVEL_HEIGHT)
-- No separate below-screen width minimum: its widest possible row (the
-- merged 5-wide 9-case row, see spawnGridCell) is (GRID_COLUMNS + 1) *
-- CELL_W + 8 = 263px, which pokes past SCREEN_WIDTH but always lands well
-- within CONTENT_MIN_RIGHT_PAD's own canvas-width budget below (once
-- combined with SCREEN_WIDTH) -- deliberate, see drawSpawnPanel.

-- The right flange and the below-screen region no longer share one
-- height-max the way two side flanges would -- below-screen's height is
-- additive with the screen's own height instead, so the two candidates for
-- minCanvasHeight are "right flange's own corner-to-corner height" and
-- "screen height + spawn-grid/travel-diagram's height stacked beneath it".
local minCanvasHeight = math.max(CONTENT_MIN_RIGHT_PANEL_HEIGHT,
	SCREEN_HEIGHT + CONTENT_MIN_BELOW_SCREEN_HEIGHT)
local minCanvasWidth = SCREEN_WIDTH + CONTENT_MIN_RIGHT_PAD
local widthForRatio = math.ceil(minCanvasHeight * TARGET_ASPECT_W / TARGET_ASPECT_H)
local finalWidth = math.max(minCanvasWidth, widthForRatio)
local finalHeight = math.ceil(finalWidth * TARGET_ASPECT_H / TARGET_ASPECT_W)

-- Only one side flange now, so any ratio-driven width slack goes entirely
-- to RIGHT_PAD -- no split needed.
local RIGHT_PAD = CONTENT_MIN_RIGHT_PAD + (finalWidth - minCanvasWidth)
local DOWN_PAD = finalHeight - SCREEN_HEIGHT

-- No panel has needed top padding so far -- named rather than inlined as a
-- literal 0 in SetGameExtraPadding/GAME_Y below since that's very much not
-- expected to stay true (a top flange is already under consideration).
local UP_PAD = 0

client.SetGameExtraPadding(0, UP_PAD, RIGHT_PAD, DOWN_PAD)

-- Where the actual game screen sits within the padded canvas -- see the
-- IMPORTANT note up top. GAME_X is 0 now that there's no left flange, but
-- kept named (not inlined) since every game-relative draw call already
-- expects to add it.
local GAME_X, GAME_Y = 0, UP_PAD

-- x for the specials column -- see CONTENT_MIN_RIGHT_PAD above, same
-- leading gap/margin the egg grid itself uses.
local SPECIAL_COLUMN_X = GAME_X + SCREEN_WIDTH + 4 + EGG_GRID_COLUMNS * EGG_CELL_W + SPECIAL_COLUMN_GAP

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

-- Shared by portraitPath/eggIconPath: species names -> filename-safe keys
-- (lowercase, spaces/apostrophes/dots stripped).
local function imageKey(name)
	return name:lower():gsub("[ '.]", "")
end

-- Matches images/portraits/ (GfxExtract.lua).
local function portraitPath(name)
	return PORTRAIT_DIR .. imageKey(name) .. "_portrait.png"
end

-- Matches images/egg_hatch/ (GfxExtract.lua).
local function eggIconPath(name)
	return EGG_ICON_DIR .. imageKey(name) .. "_hatch.png"
end

local function isCaught(species)
	return Memory.readbyte(ADDR_POKEDEX_FLAGS + species) == PokedexFlag.CAUGHT
end

-- See ADDR_CAUGHT_MON_COUNT/ADDR_CAUGHT_SPECIES_COUNT above for the
-- eligibility conditions this mirrors.
local function isPichuEligible()
	return Memory.readword(ADDR_CAUGHT_MON_COUNT) >= RARE_SPECIAL_MIN_CAUGHT_THIS_GAME
end

local function isLatiEligible()
	return Memory.readword(ADDR_CAUGHT_MON_COUNT) >= RARE_SPECIAL_MIN_CAUGHT_THIS_GAME
		and Memory.readword(ADDR_CAUGHT_SPECIES_COUNT) >= LATI_MIN_CAUGHT_SPECIES
end

local function isEncounterRateUp()
	return Memory.readbyte(ADDR_ENCOUNTER_RATE_UP_FLAG) ~= 0
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

-- Species currently sitting in the evolvable-party queue (awaiting Evolution
-- Mode), as a set for fast membership checks.
local function readEvolvablePartySet()
	local size = Memory.readbyte(ADDR_EVOLVABLE_PARTY_SIZE)
	local set = {}
	for i = 0, math.min(size, MAX_EVOLVABLE_PARTY_SIZE) - 1 do
		set[Memory.readbyte(ADDR_EVOLVABLE_PARTY_SPECIES + i)] = true
	end
	return set
end

-- True when species, or any step of its evolution line (same up-to-2-hop
-- walk as isEvolutionLineCaught), is currently queued for Evolution Mode --
-- i.e. catching is done, all that's left is playing evo mode to finish the
-- line. Distinct from "caught" (dex flag, permanent) since the queue is
-- session-scoped: a species can be caught from a prior session/ball with
-- nothing queued right now, or already evolved out of the queue.
local function isPendingEvolution(species, queueSet)
	if queueSet[species] then
		return true
	end
	local current = species
	for _ = 1, 2 do
		local target = evolutionTarget(current)
		if target >= NUM_SPECIES then
			break
		end
		if queueSet[target] then
			return true
		end
		current = target
	end
	return false
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

-- How many species you'd still need to obtain (by catch or evolution) to
-- get everything catchable in this area to CD: every base species
-- catchable here plus every step of each one's evolution line, vs. how many
-- of those are already caught.
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
local function readSpawnPool(area, queueSet)
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
			pendingEvolution = isPendingEvolution(entry.species, queueSet),
			rare = RARE_SPECIES[entry.species] or false,
		}
	end
	return pool
end

-- The 25 real egg-hatch spawns for the current field (see
-- ADDR_EGG_LOCATIONS above) -- unlike readSpawnPool, there's no arrow-state
-- to dedup across (one flat row per field) and no exclusive/rare markers
-- (neither concept applies to egg mode -- checked, no RARE_SPECIES entry
-- appears in either field's egg list).
local function readEggPool(field, queueSet)
	local pool = {}
	if not VALID_FIELDS[field] then
		return pool
	end
	local rowAddr = ADDR_EGG_LOCATIONS + field * EGG_LOCATIONS_ROW_BYTES
	for slot = 0, EGG_POOL_SIZE - 1 do
		local species = Memory.readword(rowAddr + slot * 2)
		pool[#pool + 1] = {
			name = speciesName(species),
			caught = isCaught(species),
			lineCaught = isEvolutionLineCaught(species),
			pendingEvolution = isPendingEvolution(species, queueSet),
		}
	end
	return pool
end

-- The 4 deferred edge-case specials: Pichu, field-appropriate Lati(as/os),
-- field-appropriate Groudon/Kyogre, Rayquaza. Fixed order/field selection,
-- not table-driven like readSpawnPool/readEggPool since there are only 4
-- entries and 2 of them are field-conditional single picks rather than a
-- ROM-data row.
local function readSpecials(field)
	local latiSpecies = (field == 0) and SPECIES_LATIOS or SPECIES_LATIAS
	local groudonKyogreSpecies = (field == 0) and SPECIES_GROUDON or SPECIES_KYOGRE
	return {
		{
			name = speciesName(SPECIES_PICHU),
			caught = isCaught(SPECIES_PICHU),
			lineCaught = isEvolutionLineCaught(SPECIES_PICHU),
			eligible = isPichuEligible(),
		},
		{
			name = speciesName(latiSpecies),
			caught = isCaught(latiSpecies),
			lineCaught = isEvolutionLineCaught(latiSpecies),
			eligible = isLatiEligible(),
		},
		{
			name = speciesName(groudonKyogreSpecies),
			caught = isCaught(groudonKyogreSpecies),
			lineCaught = isEvolutionLineCaught(groudonKyogreSpecies),
			eligible = false,
		},
		{
			name = speciesName(SPECIES_RAYQUAZA),
			caught = isCaught(SPECIES_RAYQUAZA),
			lineCaught = isEvolutionLineCaught(SPECIES_RAYQUAZA),
			eligible = false,
		},
	}
end

-- A colored border around a caught species' portrait, instead of a
-- translucent dim overlay: dimming (even with a wide alpha gap between the
-- two states) read as barely-different at a glance against portraits with
-- such varied source brightness/color, and the most visible part of it
-- turned out to be the 1px undimmed edge left at the portrait's border --
-- which is the tell that a deliberate, saturated border reads far more
-- clearly than tinting the whole image ever did. Green once the whole
-- evolution line is caught (D, no longer worth pursuing); purple when the
-- line isn't finished but this species (or an evolution of it) is sitting
-- in the current evolvable-party queue, i.e. no more catching needed here,
-- just play Evolution Mode (C+ -- takes precedence over C but not D, since
-- the dex "caught" flag alone can't tell you whether *this session's* catch
-- is still queued to evolve); orange while just caught with nothing queued
-- (C); black (currently invisible against the panel's own black background,
-- but explicit so it'll show correctly if that background ever changes)
-- when not caught at all.
local BORDER_COLOR_LINE_CAUGHT = 0xFF34C759
local BORDER_COLOR_PENDING_EVOLUTION = 0xFFFF2D95
local BORDER_COLOR_CAUGHT = 0xFFFF9500
local BORDER_COLOR_UNCAUGHT = 0xFF000000

-- Shared by drawPortraitCell/drawEggHatchCell: D > C+ > C > uncaught.
local function borderColorFor(entry)
	if not entry.caught then
		return BORDER_COLOR_UNCAUGHT
	end
	if entry.lineCaught then
		return BORDER_COLOR_LINE_CAUGHT
	end
	if entry.pendingEvolution then
		return BORDER_COLOR_PENDING_EVOLUTION
	end
	return BORDER_COLOR_CAUGHT
end

-- Specials-only tier, one step below "caught" (see readSpecials): a species
-- with no evolution target already lands on BORDER_COLOR_LINE_CAUGHT the
-- moment it's caught (isEvolutionLineCaught == isCaught for a species with
-- no further evolution -- confirmed, no code changes needed in
-- borderColorFor itself), so this only adds a distinct color for "not
-- caught yet, but eligible to spawn/roll for" -- Pichu and Lati only, see
-- readSpecials; Groudon/Kyogre/Rayquaza have eligible always false so this
-- tier never shows for them.
local BORDER_COLOR_ELIGIBLE = 0xFFAF52DE

local function specialBorderColorFor(entry)
	if not entry.caught and entry.eligible then
		return BORDER_COLOR_ELIGIBLE
	end
	return borderColorFor(entry)
end

-- gui.drawRectangle's width/height are corner-to-corner (the right/bottom
-- border line lands at x+width, y+height), not a pixel count the way
-- drawImage's w/h are -- so this only needs +1, not +2, to sit flush
-- against a portrait occupying columns/rows [x, x+w) / [y, y+h).
local function drawPortraitBorder(x, y, w, h, color)
	gui.drawRectangle(x - 1, y - 1, w + 1, h + 1, color, nil)
end

-- gui.drawImage errors out (aborting the whole overlay frame) on a missing
-- file rather than silently no-oping, same as pygame.image.load on the
-- Python side -- guard the same way: catch it, warn once via console.log,
-- and skip drawing that cell instead of taking the whole overlay down.
local warnedMissingImages = {}
local function safeDrawImage(path, x, y, w, h)
	if not path then
		return
	end
	local ok, err = pcall(gui.drawImage, path, x, y, w, h)
	if not ok and not warnedMissingImages[path] then
		warnedMissingImages[path] = true
		console.log("Overlay: missing image " .. path .. " (" .. tostring(err) .. ")")
	end
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
	safeDrawImage(portraitPath(entry.name), x, y, PORTRAIT_W, PORTRAIT_H)
	drawPortraitBorder(x, y, PORTRAIT_W, PORTRAIT_H, borderColorFor(entry))

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

-- No exclusive/rare markers here (that concept doesn't apply to this
-- column) -- just the eligible/caught/line-caught border
-- (specialBorderColorFor). The rate-up flag gets one shared icon next to
-- the dex-caught line instead of a per-mon marker -- see drawEggPanel.
local function drawSpecialCell(x, y, entry)
	safeDrawImage(portraitPath(entry.name), x, y, PORTRAIT_W, PORTRAIT_H)
	drawPortraitBorder(x, y, PORTRAIT_W, PORTRAIT_H, specialBorderColorFor(entry))
end

local function areaIconPath(areaIndex)
	local fileName = AreaIconFiles[areaIndex + 1]
	if not fileName then
		return nil
	end
	return AREA_ICON_DIR .. fileName
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

-- Caught/total for a travel-diagram icon, as a tight fraction (count over
-- total, separated by a real drawn line rather than "--" text) beside the
-- icon instead of a caption above/below it -- see CD_GLYPH_HEIGHT.
-- onRight places the fraction to the icon's right (against its left edge),
-- otherwise to its left (against its right edge). Sized to the wider of
-- the two numbers (via CD_CHAR_WIDTH) rather than a fixed reserved box, so
-- the narrower number centers over the wider one and the gap to the icon
-- comes out the same regardless of digit count on either side.
local function drawCdStack(iconX, iconY, onRight, cdCount, total)
	local caughtStr, totalStr = tostring(cdCount), tostring(total)
	local caughtWidth, totalWidth = #caughtStr * CD_CHAR_WIDTH, #totalStr * CD_CHAR_WIDTH
	local stackWidth = math.max(caughtWidth, totalWidth)
	local blockX = onRight and (iconX + PORTRAIT_W + CD_STACK_GAP) or (iconX - CD_STACK_GAP - stackWidth)

	-- Drawn-anchor-to-visible-bottom span (2 glyphs + 2 line gaps + one
	-- glyph's worth of CD_GLYPH_Y_OFFSET, see denomY below) -- used only to
	-- vertically center the whole fraction within the icon's height.
	local stackHeight = 2 * CD_GLYPH_HEIGHT + 2 * CD_STACK_LINE_GAP + CD_GLYPH_Y_OFFSET
	local textY = iconY + (PORTRAIT_H - stackHeight) / 2
	local lineY = roundPx(textY + CD_GLYPH_Y_OFFSET + CD_GLYPH_HEIGHT + CD_STACK_LINE_GAP)
	-- denomY is drawn CD_GLYPH_Y_OFFSET earlier than a naive "lineY + gap"
	-- would suggest, to cancel out that same offset applying again to the
	-- denominator's own draw call -- see CD_GLYPH_Y_OFFSET.
	local denomY = lineY + CD_STACK_LINE_GAP - CD_GLYPH_Y_OFFSET

	gui.drawText(blockX + (stackWidth - caughtWidth) / 2, textY, caughtStr, "white")
	gui.drawLine(blockX, lineY, blockX + stackWidth, lineY, "white")
	gui.drawText(blockX + (stackWidth - totalWidth) / 2, denomY, totalStr, "white")
end

-- Current area's icon at bottom-center; arrows fan up-left/up-right from
-- points 1/5 and 4/5 along its top edge (not its center -- two arrows
-- sharing one origin point read as a single split arrow rather than a
-- pair) to the two travel destinations (readTravelOptions), icons at the
-- arrow tips. Each icon's CD stack sits on its "inside" edge (facing the
-- diagram's center) -- out of the arrows' way, since they fan from the
-- bottom icon's top edge, not its sides, so the bottom icon's stack can
-- also safely go on its right without crossing them.
local ARROW_START_INSET = PORTRAIT_W / 5

local function drawTravelDiagram(x, y, width, areaIndex, areaCdCount, areaTotal,
	leftAreaIndex, leftCdCount, leftTotal, rightAreaIndex, rightCdCount, rightTotal)
	local leftX = x
	local rightX = x + width - PORTRAIT_W
	local centerX = x + (width - PORTRAIT_W) / 2
	local topIconY = y
	local bottomIconY = topIconY + PORTRAIT_H + ARROW_GAP

	safeDrawImage(areaIconPath(leftAreaIndex), leftX, topIconY, PORTRAIT_W, PORTRAIT_H)
	safeDrawImage(areaIconPath(rightAreaIndex), rightX, topIconY, PORTRAIT_W, PORTRAIT_H)
	safeDrawImage(areaIconPath(areaIndex), centerX, bottomIconY, PORTRAIT_W, PORTRAIT_H)

	drawCdStack(leftX, topIconY, true, leftCdCount, leftTotal)
	drawCdStack(rightX, topIconY, false, rightCdCount, rightTotal)
	drawCdStack(centerX, bottomIconY, true, areaCdCount, areaTotal)

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

-- No exclusive/rare markers here (see readEggPool) -- just the caught/
-- line-caught border, same colors/meaning as drawPortraitCell.
local function drawEggHatchCell(x, y, entry)
	safeDrawImage(eggIconPath(entry.name), x, y, EGG_ICON_W, EGG_ICON_H)
	drawPortraitBorder(x, y, EGG_ICON_W, EGG_ICON_H, borderColorFor(entry))
end

-- Right of the game screen, extending down to cover the bottom-right
-- corner: field-wide egg-hatch pool (readEggPool, top-anchored) -- unlike
-- the spawn-pool grid this never changes with travel, only with a
-- Ruby/Sapphire field switch -- plus the dex-caught line just below it, and
-- the travel diagram bottom-anchored beside the spawn-pool grid (which sits
-- below the screen, see drawSpawnPanel).
local function drawEggPanel(pool, specials, caught, rateUp, areaIndex, areaCdCount, areaTotal,
	leftAreaIndex, leftCdCount, leftTotal, rightAreaIndex, rightCdCount, rightTotal)
	local panelHeight = SCREEN_HEIGHT + DOWN_PAD
	gui.drawRectangle(GAME_X + SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight, "white", "black")

	local x, y = GAME_X + SCREEN_WIDTH + 4, 4
	for i, entry in ipairs(pool) do
		if entry.name ~= "-" then
			local col = (i - 1) % EGG_GRID_COLUMNS
			local row = math.floor((i - 1) / EGG_GRID_COLUMNS)
			local cellX = x + col * EGG_CELL_W
			local cellY = y + row * EGG_CELL_H
			drawEggHatchCell(cellX, cellY, entry)
		end
	end

	-- Sits in the gap between the egg grid's bottom and SCREEN_HEIGHT --
	-- see the CONTENT_MIN_RIGHT_PAD comment for why that gap is always big
	-- enough for one text line without its own content-min term.
	local dexText = "Dex caught: " .. caught .. "/" .. DEX_DISPLAY_TOTAL
	local dexTextY = GAME_Y + SCREEN_HEIGHT - LINE_HEIGHT - PANEL_BOTTOM_MARGIN
	gui.drawText(x, dexTextY, dexText, "white")

	-- Single shared indicator for the rate-up flag -- one global toggle, not
	-- a per-mon property, so it doesn't belong on the Pichu/Lati portraits
	-- themselves. Gold, same as RARE_MARKER_COLOR (this flag raises rare-mon
	-- odds, same "worth prioritizing" meaning), not a dedicated color.
	-- Player is expected to already know what it means, same as the C/D
	-- border colors elsewhere.
	if rateUp then
		local markerX = x + #dexText * CD_CHAR_WIDTH + 6
		local markerY = dexTextY + (LINE_HEIGHT - MARKER_SIZE) / 2
		drawMarker(markerX, markerY, RARE_MARKER_COLOR)
	end

	local diagramY = GAME_Y + SCREEN_HEIGHT + PANEL_TOP_MARGIN
	drawTravelDiagram(x, diagramY, TRAVEL_DIAGRAM_WIDTH, areaIndex, areaCdCount, areaTotal,
		leftAreaIndex, leftCdCount, leftTotal, rightAreaIndex, rightCdCount, rightTotal)

	for i, entry in ipairs(specials) do
		drawSpecialCell(SPECIAL_COLUMN_X, y + (i - 1) * SPECIAL_CELL_H, entry)
	end
end

-- Row/col for spawn-pool grid cell i (1-indexed) of a poolSize-entry pool at
-- the given column count. Normally a fixed GRID_COLUMNS-wide grid, except:
-- if the last row would hold exactly one lonely portrait (poolSize mod
-- columns == 1, e.g. the real 9-pool at 4 columns), that portrait is merged
-- into the previous row instead -- one row of columns+1 beats reserving a
-- whole extra row's height for a single cell. Only ever affects the very
-- last row, so every other row still packs at the fixed column count.
local function spawnGridCell(i, poolSize, columns)
	local rows = math.ceil(poolSize / columns)
	local lastRowStart = (rows - 1) * columns
	if poolSize - lastRowStart == 1 and rows > 1 then
		rows = rows - 1
		lastRowStart = lastRowStart - columns
	end
	local idx = i - 1
	if idx >= lastRowStart then
		return rows - 1, idx - lastRowStart
	end
	return math.floor(idx / columns), idx % columns
end

-- The merged last row (see spawnGridCell) can run one cell wider than
-- GRID_COLUMNS, which pokes past the panel's own background rectangle into
-- the egg panel's -- deliberate, not a bug: there's plenty of canvas width
-- there (RIGHT_PAD's ratio-driven slack always exceeds one cell), and the
-- border between the two panels isn't meant to stay a hard visual wall
-- long-term anyway. It only overlaps the egg panel's *background*, not its
-- content -- the travel diagram (the only thing drawn low enough in that
-- panel to be at risk) only places its bottom-row icon at TRAVEL_DIAGRAM_
-- WIDTH's horizontal center, well clear of the flange's left edge where the
-- overflow cell lands.
local function drawSpawnPanel(pool)
	gui.drawRectangle(GAME_X, GAME_Y + SCREEN_HEIGHT, SCREEN_WIDTH, DOWN_PAD, "white", "black")

	local x, y = GAME_X + 4, GAME_Y + SCREEN_HEIGHT + 4
	for i, entry in ipairs(pool) do
		local row, col = spawnGridCell(i, #pool, GRID_COLUMNS)
		local cellX = x + col * CELL_W
		local cellY = y + row * CELL_H
		drawPortraitCell(cellX, cellY, entry)
	end
end

local function drawOverlay()
	local areaIndex = Memory.readbyte(ADDR_AREA)
	local field = Memory.readbyte(ADDR_SELECTED_FIELD)
	local queueSet = readEvolvablePartySet()
	local pool = readSpawnPool(areaIndex, queueSet)
	local eggPool = readEggPool(field, queueSet)
	local specials = readSpecials(field)
	local rateUp = isEncounterRateUp()
	local areaCdCount, areaTotal = readAreaCdProgress(areaIndex)
	local caught = readDexCaughtCount()

	local leftAreaIndex, rightAreaIndex = readTravelOptions()
	local leftCdCount, leftTotal = readAreaCdProgress(leftAreaIndex)
	local rightCdCount, rightTotal = readAreaCdProgress(rightAreaIndex)

	drawEggPanel(eggPool, specials, caught, rateUp, areaIndex, areaCdCount, areaTotal,
		leftAreaIndex, leftCdCount, leftTotal, rightAreaIndex, rightCdCount, rightTotal)
	drawSpawnPanel(pool)
end

while true do
	drawOverlay()
	emu.frameadvance()
end
