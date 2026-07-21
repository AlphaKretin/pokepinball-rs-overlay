"""
Static ROM-data reader. Unlike EWRAM, ROM content never changes during
play, so these tables are read once from the ROM file itself (not RAVBA's
live process memory) -- same spirit as lua/Data.lua's pre-baked tables,
just computed from the ROM instead of hand-transcribed.

Addresses/shapes/reasoning all come from lua/Overlay.lua (lines 52-99) and
docs/ram-map.md -- see those for *why* each address/stride is what it is;
this module just re-implements the same reads against the ROM file bytes
instead of BizHawk's memory.read* / an external process's ROM mapping.
"""

import glob
import os

from gba_gfx import load_rom, rom_offset

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ROM_GLOB = os.path.join(REPO_ROOT, "rom", "*.gba")

ADDR_AREA_ROULETTE_TABLE = 0x08055A68
AREA_ROULETTE_TABLE_SLOTS = 7
AREA_ROULETTE_RUIN_SLOT = 6

ADDR_WILD_MON_LOCATIONS = 0x08055A84
WILD_MON_SLOTS_PER_ROW = 8
WILD_MON_ROW_BYTES = WILD_MON_SLOTS_PER_ROW * 2

ADDR_EGG_LOCATIONS = 0x086A4A38
EGG_LOCATIONS_ROW_SLOTS = 26
EGG_LOCATIONS_ROW_BYTES = EGG_LOCATIONS_ROW_SLOTS * 2
EGG_POOL_SIZE = 25

ADDR_SPECIES_INFO = 0x086A3700
SPECIES_INFO_ENTRY_BYTES = 0x18
SPECIES_INFO_EVOLUTION_TARGET_OFFSET = 0x15


def find_rom():
    matches = glob.glob(DEFAULT_ROM_GLOB)
    if not matches:
        raise SystemExit(f"No ROM found at {DEFAULT_ROM_GLOB} -- pass a path explicitly.")
    return matches[0]


class RavbaRom:
    def __init__(self, path=None):
        self._rom = load_rom(path or find_rom())

    def _u8(self, addr):
        off = rom_offset(addr)
        return self._rom[off]

    def _u16(self, addr):
        off = rom_offset(addr)
        return self._rom[off] | (self._rom[off + 1] << 8)

    def evolution_target(self, species):
        return self._u8(
            ADDR_SPECIES_INFO
            + species * SPECIES_INFO_ENTRY_BYTES
            + SPECIES_INFO_EVOLUTION_TARGET_OFFSET
        )

    def area_roulette_area(self, field, slot):
        row_addr = ADDR_AREA_ROULETTE_TABLE + field * AREA_ROULETTE_TABLE_SLOTS * 2
        return self._u16(row_addr + slot * 2)

    def wild_mon_species(self, area, row_index, slot):
        row_addr = ADDR_WILD_MON_LOCATIONS + (area * 2 + row_index) * WILD_MON_ROW_BYTES
        return self._u16(row_addr + slot * 2)

    def egg_pool_species(self, field, slot):
        row_addr = ADDR_EGG_LOCATIONS + field * EGG_LOCATIONS_ROW_BYTES
        return self._u16(row_addr + slot * 2)
