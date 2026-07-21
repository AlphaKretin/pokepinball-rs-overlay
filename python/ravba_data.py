"""
Static lookup tables, ported from lua/Data.lua (which itself is transcribed
from reference/pokepinballrs constants headers), plus the hardcoded
constants from lua/Overlay.lua that aren't RAM-derived (rare-species set,
edge-case special species IDs). Keep in sync with those two files if the
ROM's own indices ever change (they shouldn't).
"""

# include/constants/species.h SPECIES_* (0-204), 0-indexed here (unlike the
# Lua version's 1-indexed table).
SPECIES_NAMES = [
    "Treecko", "Grovyle", "Sceptile", "Torchic", "Combusken", "Blaziken",
    "Mudkip", "Marshtomp", "Swampert", "Poochyena", "Mightyena", "Zigzagoon",
    "Linoone", "Wurmple", "Silcoon", "Beautifly", "Cascoon", "Dustox",
    "Lotad", "Lombre", "Ludicolo", "Seedot", "Nuzleaf", "Shiftry", "Taillow",
    "Swellow", "Wingull", "Pelipper", "Ralts", "Kirlia", "Gardevoir",
    "Surskit", "Masquerain", "Shroomish", "Breloom", "Slakoth", "Vigoroth",
    "Slaking", "Abra", "Kadabra", "Alakazam", "Nincada", "Ninjask",
    "Shedinja", "Whismur", "Loudred", "Exploud", "Makuhita", "Hariyama",
    "Goldeen", "Seaking", "Magikarp", "Gyarados", "Azurill", "Marill",
    "Azumarill", "Geodude", "Graveler", "Golem", "Nosepass", "Skitty",
    "Delcatty", "Zubat", "Golbat", "Crobat", "Tentacool", "Tentacruel",
    "Sableye", "Mawile", "Aron", "Lairon", "Aggron", "Machop", "Machoke",
    "Machamp", "Meditite", "Medicham", "Electrike", "Manectric", "Plusle",
    "Minun", "Magnemite", "Magneton", "Voltorb", "Electrode", "Volbeat",
    "Illumise", "Oddish", "Gloom", "Vileplume", "Bellossom", "Doduo",
    "Dodrio", "Roselia", "Gulpin", "Swalot", "Carvanha", "Sharpedo",
    "Wailmer", "Wailord", "Numel", "Camerupt", "Slugma", "Magcargo",
    "Torkoal", "Grimer", "Muk", "Koffing", "Weezing", "Spoink", "Grumpig",
    "Sandshrew", "Sandslash", "Spinda", "Skarmory", "Trapinch", "Vibrava",
    "Flygon", "Cacnea", "Cacturne", "Swablu", "Altaria", "Zangoose",
    "Seviper", "Lunatone", "Solrock", "Barboach", "Whiscash", "Corphish",
    "Crawdaunt", "Baltoy", "Claydol", "Lileep", "Cradily", "Anorith",
    "Armaldo", "Igglybuff", "Jigglypuff", "Wigglytuff", "Feebas", "Milotic",
    "Castform", "Staryu", "Starmie", "Kecleon", "Shuppet", "Banette",
    "Duskull", "Dusclops", "Tropius", "Chimecho", "Absol", "Vulpix",
    "Ninetales", "Pichu", "Pikachu", "Raichu", "Psyduck", "Golduck",
    "Wynaut", "Wobbuffet", "Natu", "Xatu", "Girafarig", "Phanpy", "Donphan",
    "Pinsir", "Heracross", "Rhyhorn", "Rhydon", "Snorunt", "Glalie",
    "Spheal", "Sealeo", "Walrein", "Clamperl", "Huntail", "Gorebyss",
    "Relicanth", "Corsola", "Chinchou", "Lanturn", "Luvdisc", "Horsea",
    "Seadra", "Kingdra", "Bagon", "Shelgon", "Salamence", "Beldum",
    "Metang", "Metagross", "Regirock", "Regice", "Registeel", "Latias",
    "Latios", "Kyogre", "Groudon", "Rayquaza", "Jirachi", "Chikorita",
    "Cyndaquil", "Totodile", "Aerodactyl",
]

NUM_SPECIES = len(SPECIES_NAMES)

# include/constants/areas.h AREA_* (0-13)
AREA_NAMES = [
    "Forest (Ruby)", "Forest (Sapphire)",
    "Plains (Ruby)", "Plains (Sapphire)",
    "Ocean (Ruby)", "Ocean (Sapphire)",
    "Cave (Ruby)", "Cave (Sapphire)",
    "Safari Zone",
    "Volcano",
    "Lake",
    "Wilderness",
    "Ruin (Ruby)", "Ruin (Sapphire)",
]

# gAreaPortraitIndexes: area index -> location icon filename, in
# lua/images/areas/ (Ruin Ruby/Sapphire share one asset).
AREA_ICON_FILES = [
    "forest_ruby_icon.png", "forest_sapphire_icon.png",
    "plains_ruby_icon.png", "plains_sapphire_icon.png",
    "ocean_ruby_icon.png", "ocean_sapphire_icon.png",
    "cave_ruby_icon.png", "cave_sapphire_icon.png",
    "safari_zone_icon.png", "volcano_icon.png", "lake_icon.png",
    "wilderness_icon.png", "ruin_icon.png", "ruin_icon.png",
]

FIELD_NAMES = ["Ruby", "Sapphire"]

# include/constants/variables.h pokedex flag values
POKEDEX_FLAG_NONE = 0
POKEDEX_FLAG_SEEN = 1
POKEDEX_FLAG_SHARED = 2
POKEDEX_FLAG_SHARED_AND_SEEN = 3
POKEDEX_FLAG_CAUGHT = 4

# The last 4 species.h entries are only reachable via e-Reader card scan or
# Pokedex data trade -- no in-game path exists for them in single-player.
# Excluded from the displayed dex total (see Overlay.lua lines 113-121).
NUM_EREADER_ONLY_SPECIES = 4
DEX_DISPLAY_TOTAL = NUM_SPECIES - NUM_EREADER_ONLY_SPECIES

# The hardcoded rare-species set from BuildSpeciesWeightsForCatchEmMode
# (src/main_board_catch_hatch_picker.c:176-185), species.h numbering.
RARE_SPECIES = {
    59,  # Nosepass
    114,  # Skarmory
    132,  # Lileep
    134,  # Anorith
    139,  # Feebas
    141,  # Castform
    144,  # Kecleon
    151,  # Absol
    160,  # Wobbuffet
}

# Deferred edge-case specials (Overlay.lua lines 141-146), species.h numbering.
SPECIES_PICHU = 154
SPECIES_LATIAS = 195
SPECIES_LATIOS = 196
SPECIES_KYOGRE = 197
SPECIES_GROUDON = 198
SPECIES_RAYQUAZA = 199

RARE_SPECIAL_MIN_CAUGHT_THIS_GAME = 5
LATI_MIN_CAUGHT_SPECIES = 100


def species_name(index):
    if 0 <= index < NUM_SPECIES:
        return SPECIES_NAMES[index]
    return "-"


def image_key(name):
    return "".join(c for c in name.lower() if c not in " '.")


def portrait_path(name):
    return f"portraits/{image_key(name)}_portrait.png"


def egg_icon_path(name):
    return f"egg_hatch/{image_key(name)}_hatch.png"


def area_icon_path(area_index):
    if 0 <= area_index < len(AREA_ICON_FILES):
        return f"areas/{AREA_ICON_FILES[area_index]}"
    return None
