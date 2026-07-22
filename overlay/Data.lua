-- Static lookup tables, transcribed from reference/pokepinballrs constants
-- headers. Keep these in sync with that repo if it ever renumbers anything
-- (it shouldn't -- these indices are dictated by the ROM itself).

-- include/constants/species.h SPECIES_* (0-204). Lua tables are 1-indexed,
-- so species index N is SpeciesNames[N + 1].
SpeciesNames = {
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
}

-- include/constants/areas.h AREA_* (0-13)
AreaNames = {
	"Forest (Ruby)", "Forest (Sapphire)",
	"Plains (Ruby)", "Plains (Sapphire)",
	"Ocean (Ruby)", "Ocean (Sapphire)",
	"Cave (Ruby)", "Cave (Sapphire)",
	"Safari Zone",
	"Volcano",
	"Lake",
	"Wilderness",
	"Ruin (Ruby)", "Ruin (Sapphire)",
}

-- gAreaPortraitIndexes (data/rom_1.s:622-625): area index -> location icon.
-- Ruin Ruby/Sapphire share one asset (the game reuses the same portrait for
-- both); every other area already has a distinct Ruby/Sapphire icon. Files
-- extracted from the ROM's gPortraitGenericGraphics/gPortraitGenericPalettes
-- (0x0848D68C / 0x081C00E4) into images/areas/ -- see docs/memory-map.md.
AreaIconFiles = {
	"forest_ruby_icon.png", "forest_sapphire_icon.png",
	"plains_ruby_icon.png", "plains_sapphire_icon.png",
	"ocean_ruby_icon.png", "ocean_sapphire_icon.png",
	"cave_ruby_icon.png", "cave_sapphire_icon.png",
	"safari_zone_icon.png", "volcano_icon.png", "lake_icon.png",
	"wilderness_icon.png", "ruin_icon.png", "ruin_icon.png",
}

-- gMain.selectedField / tempField
FieldNames = { "Ruby", "Sapphire" }

-- include/constants/variables.h pokedex flag values
PokedexFlag = {
	NONE = 0,
	SEEN = 1,
	SHARED = 2,
	SHARED_AND_SEEN = 3,
	CAUGHT = 4,
}
