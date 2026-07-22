"""Extract the 13 area-location icons (gPortraitGenericGraphics /
gPortraitGenericPalettes) from the ROM into overlay/images/areas/*_icon.png.

Maintainer/verification tooling only -- overlay/GfxExtract.lua does this
live, in Lua, the first time the overlay runs, so end users don't need this
script. Kept for regenerating/diffing against GfxExtract.lua's own output if
the decode logic is ever in doubt. See docs/graphics-extraction.md for the
tile-format background, docs/memory-map.md for the RAM/ROM addresses involved,
and overlay/Data.lua's AreaIconFiles for how these files map back to AREA_*
indices in the overlay.

Usage: python scripts/extract_area_icons.py [path/to/rom.gba]
Defaults to the repo's own rom/ folder (gitignored, not committed) if no
path is given.
"""

import glob
import os
import sys

from scripts.gba_gfx import (
    assemble_metatile_image,
    load_rom,
    read_palette,
    rom_offset,
    save_png_rgb,
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_ROM_GLOB = os.path.join(REPO_ROOT, "rom", "*.gba")
OUT_DIR = os.path.join(REPO_ROOT, "overlay", "images", "areas")

GFX_ADDR = 0x0848D68C
PAL_ADDR = 0x081C00E4
BYTES_PER_PORTRAIT = 0x300
COLORS_PER_PAL = 16

# gAreaPortraitIndexes (data/rom_1.s:622-625) dedups Ruin Ruby/Sapphire (both
# -> portrait 12); every other area already has a distinct Ruby/Sapphire
# portrait, so this is a straight portrait-index -> filename list, not keyed
# by AREA_* index. Must match overlay/Data.lua's AreaIconFiles.
PORTRAIT_FILES = [
    "forest_ruby",
    "forest_sapphire",
    "plains_ruby",
    "plains_sapphire",
    "ocean_ruby",
    "ocean_sapphire",
    "cave_ruby",
    "cave_sapphire",
    "safari_zone",
    "volcano",
    "lake",
    "wilderness",
    "ruin",
]


def find_rom():
    matches = glob.glob(DEFAULT_ROM_GLOB)
    if not matches:
        raise SystemExit(
            f"No ROM found at {DEFAULT_ROM_GLOB} -- pass a path explicitly."
        )
    return matches[0]


def main():
    rom_path = sys.argv[1] if len(sys.argv) > 1 else find_rom()
    rom = load_rom(rom_path)

    os.makedirs(OUT_DIR, exist_ok=True)
    for portrait_idx, name in enumerate(PORTRAIT_FILES):
        gfx_off = rom_offset(GFX_ADDR) + portrait_idx * BYTES_PER_PORTRAIT
        data = rom[gfx_off : gfx_off + BYTES_PER_PORTRAIT]
        palette = read_palette(
            rom, PAL_ADDR + portrait_idx * COLORS_PER_PAL * 2, COLORS_PER_PAL
        )
        img = assemble_metatile_image(
            data, meta_wide=3, meta_tall=2, mwidth=2, mheight=2
        )
        out_path = os.path.join(OUT_DIR, f"{name}_icon.png")
        save_png_rgb(img, palette, out_path)
        print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
