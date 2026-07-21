-- One-off diagnostic: paste into BizHawk's Lua console (or run via the
-- script list) while a save is loaded. Not part of the overlay -- checks
-- whether the gSpeciesInfo address/stride from docs/ram-map.md is right,
-- and dumps the raw values behind a few suspicious overlay readings.

console.clear()

local ROM_BASE = 0x08000000
local EWRAM_BASE = 0x02000000

local ADDR_SPECIES_INFO = 0x086A3700
local ENTRY_BYTES = 0x18
local NAME_OFFSET = 0x07
local EVO_OFFSET = 0x15

local ADDR_POKEDEX_FLAGS = 0x0200B134

local function romByte(addr)
	return memory.read_u8(addr - ROM_BASE, "ROM")
end

local function romString(addr, len)
	local s = ""
	for i = 0, len - 1 do
		s = s .. string.char(romByte(addr + i))
	end
	return s
end

local function ewramByte(addr)
	return memory.read_u8(addr - EWRAM_BASE, "EWRAM")
end

-- Re-verify the table base/stride: species index 1 (Grovyle) should land
-- exactly one entry after Treecko if ADDR_SPECIES_INFO and ENTRY_BYTES are
-- both right.
local grovyleName = romString(ADDR_SPECIES_INFO + ENTRY_BYTES + NAME_OFFSET, 10)
console.log("Species 1 name (expect 'GROVYLE   '): [" .. grovyleName .. "]")

local checks = {
	{ id = 47, name = "Makuhita" },
	{ id = 48, name = "Hariyama" },
	{ id = 67, name = "Sableye" },
	{ id = 105, name = "Grimer" },
	{ id = 106, name = "Muk" },
}

console.log("")
console.log("name        id  evolutionTarget  pokedexFlag")
for _, c in ipairs(checks) do
	local evoTarget = romByte(ADDR_SPECIES_INFO + c.id * ENTRY_BYTES + EVO_OFFSET)
	local flag = ewramByte(ADDR_POKEDEX_FLAGS + c.id)
	console.log(string.format("%-10s  %-3d %-16d %d", c.name, c.id, evoTarget, flag))
end

console.log("")
console.log("pokedexFlag: 0=unseen 1=seen 2=shared 3=shared+seen 4=caught")
