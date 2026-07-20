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

local NUM_SPECIES = #SpeciesNames

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

-- Species pool for a given area + arrows state, from ROM (gWildMonLocations).
-- When withWeights is true, also reads the live cumulative weight table
-- (PinballGame.speciesWeights[], only valid while boardState is
-- MAIN_BOARD_STATE_CATCH_EM_MODE -- see docs/ram-map.md) and pairs each
-- species with its % chance of being picked next.
local function readSpawnPool(area, threeArrowsLit, withWeights)
	local rowIndex = threeArrowsLit and 1 or 0
	local rowAddr = ADDR_WILD_MON_LOCATIONS + (area * 2 + rowIndex) * WILD_MON_ROW_BYTES
	local totalWeight = withWeights and Memory.readword(ADDR_TOTAL_WEIGHT) or nil

	local pool = {}
	local prevCumWeight = 0
	for slot = 0, WILD_MON_SLOTS_PER_ROW - 1 do
		local species = Memory.readword(rowAddr + slot * 2)
		local pct = nil
		if withWeights then
			local cumWeight = Memory.readword(ADDR_SPECIES_WEIGHTS + slot * 2)
			if totalWeight and totalWeight > 0 then
				pct = (cumWeight - prevCumWeight) / totalWeight * 100
			end
			prevCumWeight = cumWeight
		end
		if species < NUM_SPECIES then
			pool[#pool + 1] = { name = speciesName(species), pct = pct }
		end
	end
	return pool
end

-- Right of the game screen, extending down to cover the bottom-right
-- corner: current-encounter info.
local function drawSidePanel(area, pool)
	local x, y = SCREEN_WIDTH + 4, 4
	local panelHeight = SCREEN_HEIGHT + DOWN_PAD

	gui.drawRectangle(SCREEN_WIDTH, 0, RIGHT_PAD, panelHeight, "white", "black")

	gui.drawText(x, y, shortAreaName(area), "white")
	y = y + LINE_HEIGHT * 1.5

	gui.drawText(x, y, "Possible spawns:", "white")
	y = y + LINE_HEIGHT
	for _, entry in ipairs(pool) do
		local line = entry.name
		if entry.pct then
			line = line .. string.format(" (%.1f%%)", entry.pct)
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
	local caught = readDexCaughtCount()

	drawSidePanel(area, pool)
	drawBottomBar(caught)
end

while true do
	drawOverlay()
	emu.frameadvance()
end
