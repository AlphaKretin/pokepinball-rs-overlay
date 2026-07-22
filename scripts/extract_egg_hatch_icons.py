"""Extract egg-hatch icons for overlay/Overlay.lua's egg-pool panel.

Maintainer/verification tooling only, and a *different* method than the one
actually used live -- overlay/GfxExtract.lua decodes these straight from ROM
tile data at runtime (see docs/memory-map.md's gDexAnimationIx addressing).
This script instead crops frame 0 out of pret's decomp's already-rendered
reference/pokepinballrs/graphics/mon_hatch_sprites/*.png sheets -- no ROM
decoding needed here, just a crop + transparency pass. Each source PNG is a
5x3 grid of 24x24 animation frames (the mon popping out of its egg); frame 0
(top-left) is a clean static sprite of the mon itself, confirmed by direct
visual inspection. Kept as an independent cross-check of GfxExtract.lua's
output, since it doesn't touch raw ROM tile data at all and so can't share a
bug with the ROM-address-based path.

Uses Pillow, unlike gba_gfx.py's from-scratch decoder/writer -- these are
already real PNGs to crop and re-key, not raw GBA tile data to assemble, so
reimplementing a PNG reader here would just be reinventing Pillow.

Transparency: each source PNG is palette-indexed with index 0 reserved as
the background (GBA sprite convention) -- confirmed as (0, 230, 0) green for
every species used here. Keyed by palette *index*, not the RGB value, so
this stays correct even where the exact background color differs (e.g.
pichu_2_hatch.png, which isn't part of this extraction, uses a different
index-0 color).

Usage: python scripts/extract_egg_hatch_icons.py
"""

import os

from PIL import Image

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(
    REPO_ROOT, "reference", "pokepinballrs", "graphics", "mon_hatch_sprites"
)
OUT_DIR = os.path.join(REPO_ROOT, "overlay", "images", "egg_hatch")

FRAME_W, FRAME_H = 24, 24

# The 31 species referenced by gEggLocations across both fields (Ruby ∪
# Sapphire, deduped, Pichu excluded -- Pichu/other forced-rare specials are
# deliberately out of scope for this feature, see the plan doc). Overlay.lua
# reads only whichever 25 apply to the currently-selected field at a time;
# this list exists just so extraction covers every species either field
# might need.
EGG_SPECIES = [
    "wurmple",
    "lotad",
    "seedot",
    "ralts",
    "surskit",
    "shroomish",
    "whismur",
    "azurill",
    "skitty",
    "zubat",
    "aron",
    "plusle",
    "minun",
    "oddish",
    "gulpin",
    "spoink",
    "sandshrew",
    "spinda",
    "trapinch",
    "igglybuff",
    "shuppet",
    "chimecho",
    "wynaut",
    "natu",
    "phanpy",
    "snorunt",
    "spheal",
    "corsola",
    "chinchou",
    "horsea",
    "bagon",
]


def extract_one(name):
    src_path = os.path.join(SRC_DIR, f"{name}_hatch.png")
    img = Image.open(src_path)
    assert img.mode == "P", f"{src_path}: expected palette mode, got {img.mode}"

    frame = img.crop((0, 0, FRAME_W, FRAME_H))
    indices = list(frame.getdata())

    rgba = frame.convert("RGBA")
    pixels = rgba.load()
    for i, idx in enumerate(indices):
        if idx == 0:
            x, y = i % FRAME_W, i // FRAME_W
            r, g, b, _ = pixels[x, y]
            pixels[x, y] = (r, g, b, 0)

    out_path = os.path.join(OUT_DIR, f"{name}_hatch.png")
    rgba.save(out_path)
    return out_path


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    for name in EGG_SPECIES:
        out_path = extract_one(name)
        print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
