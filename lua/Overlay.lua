-- Pokedex-completion overlay for Pokemon Pinball: Ruby & Sapphire, for use
-- with BizHawk's mGBA core. See docs/ram-map.md for the addresses used here.

dofile("Memory.lua")
dofile("Data.lua")

local GMAIN = 0x0200B0C0
local ADDR_SELECTED_FIELD = GMAIN + 0x04
local ADDR_POKEDEX_FLAGS = GMAIN + 0x74 -- [NUM_SPECIES], one byte per species

local PINBALL_GAME = 0x02000000
local ADDR_BOARD_STATE = PINBALL_GAME + 0x013
local ADDR_AREA = PINBALL_GAME + 0x035
local ADDR_CURRENT_SPECIES = PINBALL_GAME + 0x598
local ADDR_CAUGHT_MON_COUNT = PINBALL_GAME + 0x5F0

-- currentSpecies is never cleared by the game -- it just holds whatever was
-- last picked. Only trust it while boardState says a species is actually on
-- display (see docs/ram-map.md).
local SPECIES_DISPLAY_BOARD_STATES = {
	[4] = true, -- MAIN_BOARD_STATE_CATCH_EM_MODE
	[5] = true, -- MAIN_BOARD_STATE_EGG_HATCH_MODE
	[8] = true, -- MAIN_BOARD_STATE_JIRACHI_CATCH_MODE
}

local NUM_SPECIES = #SpeciesNames

local RIGHT_PAD = 160
client.SetGameExtraPadding(0, 0, RIGHT_PAD, 0)

local function readPokedexCounts()
	local seen, caught = 0, 0
	for i = 0, NUM_SPECIES - 1 do
		local flag = Memory.readbyte(ADDR_POKEDEX_FLAGS + i)
		if flag == PokedexFlag.CAUGHT then
			caught = caught + 1
			seen = seen + 1
		elseif flag ~= PokedexFlag.NONE then
			seen = seen + 1
		end
	end
	return seen, caught
end

local function speciesName(index)
	if index >= 0 and index < NUM_SPECIES then
		return SpeciesNames[index + 1]
	end
	return "-"
end

local function drawPanel()
	local x, y = 242, 4
	local lineHeight = 14

	local field = FieldNames[Memory.readbyte(ADDR_SELECTED_FIELD) + 1] or "?"
	local area = AreaNames[Memory.readbyte(ADDR_AREA) + 1] or "?"
	local boardState = Memory.readbyte(ADDR_BOARD_STATE)
	local current = "-"
	if SPECIES_DISPLAY_BOARD_STATES[boardState] then
		current = speciesName(Memory.readword(ADDR_CURRENT_SPECIES))
	end
	local caughtThisGame = Memory.readword(ADDR_CAUGHT_MON_COUNT)
	local seen, caught = readPokedexCounts()

	gui.drawRectangle(238, 0, RIGHT_PAD - 2, 100, "white", "black")

	gui.drawText(x, y, "Field: " .. field, "white")
	y = y + lineHeight
	gui.drawText(x, y, "Area: " .. area, "white")
	y = y + lineHeight
	gui.drawText(x, y, "Spawned: " .. current, "white")
	y = y + lineHeight
	gui.drawText(x, y, "Caught this game: " .. caughtThisGame, "white")
	y = y + lineHeight * 1.5
	gui.drawText(x, y, "Dex seen: " .. seen .. "/" .. NUM_SPECIES, "white")
	y = y + lineHeight
	gui.drawText(x, y, "Dex caught: " .. caught .. "/" .. NUM_SPECIES, "white")
end

while true do
	drawPanel()
	emu.frameadvance()
end
