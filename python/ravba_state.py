"""
Live game-state reads, ported from lua/Overlay.lua's address constants
(lines 25-171) and read-logic functions (lines 358-646). Combines
RavbaMemory (live EWRAM) + RavbaRom (static ROM tables) + ravba_data
(static species/area tables). See Overlay.lua's own comments for *why*
each address/rule is what it is -- not re-derived here, just re-implemented
against the same addresses/logic.
"""

from dataclasses import dataclass

import ravba_data as data
import ravba_rom as rom_module

GMAIN = 0x0200B0C0
ADDR_POKEDEX_FLAGS = GMAIN + 0x74

PINBALL_GAME = 0x02000000
ADDR_AREA = PINBALL_GAME + 0x035
ADDR_SELECTED_FIELD = GMAIN + 0x04

ADDR_AREA_ROULETTE_NEXT_SLOT = PINBALL_GAME + 0x033
ADDR_AREA_ROULETTE_FAR_SLOT = PINBALL_GAME + 0x034

ADDR_AREA_VISIT_COUNT = PINBALL_GAME + 0x036
AREA_VISIT_COUNT_FORCES_RUIN = 5

ADDR_EVOLVABLE_PARTY_SPECIES = PINBALL_GAME + 0x270
ADDR_EVOLVABLE_PARTY_SIZE = PINBALL_GAME + 0x281
MAX_EVOLVABLE_PARTY_SIZE = 16

ADDR_CAUGHT_MON_COUNT = PINBALL_GAME + 0x5F0

ADDR_BOARD_CONFIG = 0x02031520
ADDR_CAUGHT_SPECIES_COUNT = ADDR_BOARD_CONFIG + 0x08

ADDR_ENCOUNTER_RATE_UP_FLAG = GMAIN + 0x08


@dataclass
class PortraitEntry:
    name: str
    caught: bool
    line_caught: bool
    pending_evolution: bool = False
    exclusive: str = "-"
    rare: bool = False
    eligible: bool = False


class GameState:
    def __init__(self, mem, rom):
        self.mem = mem
        self.rom = rom

    # -- Direct reads --------------------------------------------------

    def is_caught(self, species):
        return self.mem.read_u8(ADDR_POKEDEX_FLAGS + species) == data.POKEDEX_FLAG_CAUGHT

    def read_dex_caught_count(self):
        return sum(1 for i in range(data.NUM_SPECIES) if self.is_caught(i))

    def is_pichu_eligible(self):
        return self.mem.read_u16(ADDR_CAUGHT_MON_COUNT) >= data.RARE_SPECIAL_MIN_CAUGHT_THIS_GAME

    def is_lati_eligible(self):
        return (
            self.mem.read_u16(ADDR_CAUGHT_MON_COUNT) >= data.RARE_SPECIAL_MIN_CAUGHT_THIS_GAME
            and self.mem.read_u16(ADDR_CAUGHT_SPECIES_COUNT) >= data.LATI_MIN_CAUGHT_SPECIES
        )

    def is_encounter_rate_up(self):
        return self.mem.read_u8(ADDR_ENCOUNTER_RATE_UP_FLAG) != 0

    def current_area(self):
        return self.mem.read_u8(ADDR_AREA)

    def current_field(self):
        return self.mem.read_u8(ADDR_SELECTED_FIELD)

    # -- Evolution-line logic -------------------------------------------

    def is_evolution_line_caught(self, species):
        if not self.is_caught(species):
            return False
        current = species
        for _ in range(2):
            target = self.rom.evolution_target(current)
            if target >= data.NUM_SPECIES:
                break
            if not self.is_caught(target):
                return False
            current = target
        return True

    def read_evolvable_party_set(self):
        size = self.mem.read_u8(ADDR_EVOLVABLE_PARTY_SIZE)
        result = set()
        for i in range(min(size, MAX_EVOLVABLE_PARTY_SIZE)):
            result.add(self.mem.read_u8(ADDR_EVOLVABLE_PARTY_SPECIES + i))
        return result

    def is_pending_evolution(self, species, queue_set):
        if species in queue_set:
            return True
        current = species
        for _ in range(2):
            target = self.rom.evolution_target(current)
            if target >= data.NUM_SPECIES:
                break
            if target in queue_set:
                return True
            current = target
        return False

    def expand_with_evolutions(self, species_list):
        seen = set()
        expanded = []

        def add_unique(species):
            if species not in seen:
                seen.add(species)
                expanded.append(species)

        for species in species_list:
            add_unique(species)
            current = species
            for _ in range(2):
                target = self.rom.evolution_target(current)
                if target >= data.NUM_SPECIES:
                    break
                add_unique(target)
                current = target
        return expanded

    # -- Area / travel ---------------------------------------------------

    def read_area_species_rows(self, area):
        by_species = {}
        result = []
        for row_index in range(2):
            for slot in range(rom_module.WILD_MON_SLOTS_PER_ROW):
                species = self.rom.wild_mon_species(area, row_index, slot)
                if species >= data.NUM_SPECIES:
                    continue
                entry = by_species.get(species)
                if entry is None:
                    entry = {"species": species, "in_two_arrows": False, "in_three_arrows": False}
                    by_species[species] = entry
                    result.append(entry)
                if row_index == 0:
                    entry["in_two_arrows"] = True
                else:
                    entry["in_three_arrows"] = True
        return result

    def read_area_species_set(self, area):
        return [entry["species"] for entry in self.read_area_species_rows(area)]

    def read_area_cd_progress(self, area):
        expanded = self.expand_with_evolutions(self.read_area_species_set(area))
        caught_count = sum(1 for species in expanded if self.is_caught(species))
        return caught_count, len(expanded)

    def read_travel_options(self):
        field = self.current_field()

        if self.mem.read_u8(ADDR_AREA_VISIT_COUNT) >= AREA_VISIT_COUNT_FORCES_RUIN:
            ruin_area = self.rom.area_roulette_area(field, rom_module.AREA_ROULETTE_RUIN_SLOT)
            return ruin_area, ruin_area

        left_slot = self.mem.read_u8(ADDR_AREA_ROULETTE_NEXT_SLOT)
        right_slot = self.mem.read_u8(ADDR_AREA_ROULETTE_FAR_SLOT)
        left_area = self.rom.area_roulette_area(field, left_slot)
        right_area = self.rom.area_roulette_area(field, right_slot)
        return left_area, right_area

    # -- Pool building ---------------------------------------------------

    def read_spawn_pool(self, area, queue_set):
        pool = []
        for entry in self.read_area_species_rows(area):
            species = entry["species"]
            if entry["in_two_arrows"] and not entry["in_three_arrows"]:
                exclusive = "2"
            elif entry["in_three_arrows"] and not entry["in_two_arrows"]:
                exclusive = "3"
            else:
                exclusive = "-"
            pool.append(
                PortraitEntry(
                    name=data.species_name(species),
                    caught=self.is_caught(species),
                    line_caught=self.is_evolution_line_caught(species),
                    pending_evolution=self.is_pending_evolution(species, queue_set),
                    exclusive=exclusive,
                    rare=species in data.RARE_SPECIES,
                )
            )
        return pool

    def read_egg_pool(self, field, queue_set):
        pool = []
        for slot in range(rom_module.EGG_POOL_SIZE):
            species = self.rom.egg_pool_species(field, slot)
            pool.append(
                PortraitEntry(
                    name=data.species_name(species),
                    caught=self.is_caught(species),
                    line_caught=self.is_evolution_line_caught(species),
                    pending_evolution=self.is_pending_evolution(species, queue_set),
                )
            )
        return pool

    def read_specials(self, field):
        lati_species = data.SPECIES_LATIOS if field == 0 else data.SPECIES_LATIAS
        groudon_kyogre_species = data.SPECIES_GROUDON if field == 0 else data.SPECIES_KYOGRE

        def make(species, eligible):
            return PortraitEntry(
                name=data.species_name(species),
                caught=self.is_caught(species),
                line_caught=self.is_evolution_line_caught(species),
                eligible=eligible,
            )

        return [
            make(data.SPECIES_PICHU, self.is_pichu_eligible()),
            make(lati_species, self.is_lati_eligible()),
            make(groudon_kyogre_species, False),
            make(data.SPECIES_RAYQUAZA, False),
        ]
