# Extracting graphics not yet split by the decomp

Most sprite/portrait graphics used by the overlay (e.g. species portraits,
`lua/images/portraits/`) were copied straight from
`reference/pokepinballrs/graphics/mon_portraits/*.png` — pret's decomp has
already split those into individual PNGs as part of its own build process.

Not everything is split yet, though. Area-location icons
(`gPortraitGenericGraphics`) are still a raw, undivided blob:

```
gPortraitGenericGraphics:: @ 0x0848D68C
    .incbin "baserom.gba", 0x48D68C, 0x2700
```

(`data/rom_1.s:1343-1344`) — one flat 0x2700-byte `.incbin` straight from
the ROM binary, not `.incbin`s of individual per-icon `.4bpp` files the way
`gMonPortraitsGroup0_Gfx` is (`data/graphics/mon_portraits.inc:1-2`). When
this happens, there's no PNG to copy — the tile data has to be decoded
ourselves. `python/gba_gfx.py` + `python/extract_area_icons.py` do this for
the 13 area icons now in `lua/images/areas/`.

## Format

- **Pixels**: GBA 4bpp indexed tiles, 8x8 px, 32 bytes/tile, low nibble =
  left pixel of each byte pair.
- **Palette**: BGR555 (`u16`, 5 bits each B/G/R, high bit unused).
- **Tile arrangement — the part that isn't obvious**: a naive row-major
  raster read of the tiles produces a visibly scrambled image (recognizable
  fragments, wrong positions). The actual layout is pret's own "metatile"
  scheme, the same one described in
  `reference/pokepinballrs/graphics/mon_portraits/mon_portraits_gfx.json`
  (`mwidth: 2, mheight: 2, width: 6` — a 48x32 image is 3x2 metatiles, each
  metatile a 2x2 block of tiles, metatiles stored row-major, tiles within a
  metatile also row-major). Both the mon portraits and area icons are DMA'd
  into VRAM identically at runtime (flat 0x300-byte copy per icon/portrait,
  see `src/all_board_portrait_display.c`), so the same arrangement applies
  to both, and area icons decode correctly with the identical scheme.

**How this was confirmed**, since gPortraitGenericGraphics has no
already-decoded reference image to check against: decoded Treecko's
portrait (species index 0, `gMonPortraitsGroup0_Gfx` @ `0x084C596C`) straight
from the ROM using this same metatile scheme, and compared the result
against the known-correct `treecko_portrait.png` already in the repo. A
plain raster-order decode of the same bytes produces a scrambled,
unrecognizable image; the metatile-order decode reproduces the correct
Treecko silhouette. Only then was the scheme applied to the area icons
(which have no independent ground truth to check against) — each of the 13
was still eyeballed afterward to confirm it matches its area (forest ==
trees, volcano == lava mountains, ruin == temple, etc.) before trusting the
extraction.

## Regenerating

```
python python/extract_area_icons.py
```

Reads whichever `.gba` file it finds under `rom/` (gitignored, not
committed — see the repo's own README) unless a path is given explicitly.
Writes into `lua/images/areas/`, overwriting existing files. Should be a
no-op against a clean ROM (byte-identical output) — this only needs
re-running if the extraction logic itself changes, not routinely.

## If this comes up again

Any other still-unsplit graphics (check for a bare
`.incbin "baserom.gba", <offset>, <size>` in `reference/pokepinballrs/data/`
with no per-asset `.4bpp`/`.png` breakdown) can reuse `python/gba_gfx.py`'s
`assemble_metatile_image` directly — just confirm the `mwidth`/`mheight`/
`width` (i.e. `meta_wide`/`meta_tall`) parameters against a known image
first, the way Treecko was used above, rather than assuming the same 2x2
scheme holds for a different asset's dimensions.
