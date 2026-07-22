# Sprite/icon graphics: format and extraction

All sprite/icon graphics the overlay displays (area icons, species portraits,
egg-hatch sprites) are decoded live from the ROM by `overlay/GfxExtract.lua`
the first time the overlay runs — see the README's Images section and
`docs/memory-map.md`'s "Sprite/icon graphics" section for the concrete
addresses/formulas. This doc covers the _format_ background: the tile
layouts, why they're not a naive raster read, and how each was confirmed —
plus the offline Python tooling `GfxExtract.lua` was ported from and
verified against.

## Format

- **Pixels**: GBA 4bpp indexed tiles, 8x8 px, 32 bytes/tile, low nibble =
  left pixel of each byte pair.
- **Palette**: BGR555 (`u16`, 5 bits each B/G/R, high bit unused).
- **Nothing here is LZ77/RLE-compressed** — every asset below is a plain
  `.incbin`-style raw blob in ROM (confirmed for all three types before
  porting the decoder to Lua), so extraction is pure byte-offset arithmetic,
  no decompression step.

### Area icons and species portraits: "metatile" tile order

A naive row-major raster read of the tiles produces a visibly scrambled
image (recognizable fragments, wrong positions). The actual layout is pret's
own "metatile" scheme, the same one described in
`reference/pokepinballrs/graphics/mon_portraits/mon_portraits_gfx.json`
(`mwidth: 2, mheight: 2, width: 6` — a 48x32 image is 3x2 metatiles, each
metatile a 2x2 block of tiles, metatiles stored row-major, tiles within a
metatile also row-major). Both area icons and species portraits are DMA'd
into VRAM identically at runtime (flat `0x300`-byte copy per icon/portrait,
see `src/all_board_portrait_display.c`), so the same arrangement applies to
both.

**How this was confirmed**, since `gPortraitGenericGraphics` (the area
icons) has no already-decoded reference image to check against: decoded
Treecko's portrait (species index 0, `gMonPortraitsGroup0_Gfx` @
`0x084C596C`) straight from the ROM using this same metatile scheme, and
compared the result against the known-correct portrait already in the repo
at the time. A plain raster-order decode of the same bytes produces a
scrambled, unrecognizable image; the metatile-order decode reproduces the
correct Treecko silhouette. Only then was the scheme applied to the area
icons (which had no independent ground truth to check against at the time)
— each of the 13 was still eyeballed afterward to confirm it matches its
area (forest == trees, volcano == lava mountains, ruin == temple, etc.)
before trusting the extraction.

**Portrait palette addressing has an extra gotcha the gfx side doesn't**:
each palette group has a 16th trailing "silhouette" entry the gfx groups
don't (see `docs/memory-map.md`), so a flat `species * 0x20` formula silently
reads the _previous_ species' colors starting at species index 15. Caught
by pixel-diffing decoded output against every portrait already in the repo,
not just a couple of samples — the bug only showed up once species crossed
a group boundary, so a small sample would have missed it.

### Egg-hatch sprites: 4 composited OBJs, not a flat raster

Unlike the metatile case above, egg-hatch sprite frames are genuinely _not_
storable as one rectangular tile grid: a 24x24 sprite isn't a valid single
GBA OBJ size, so the game composites each frame at runtime from 4 separate
OBJs (`gCatchCreatureOamFramesets`, `src/main_board_to_be_split.c:1698-1723`),
all reading from one fixed 9-tile (`0x120`-byte) block:

| OBJ | Tiles                | Size  | Screen offset |
| --- | -------------------- | ----- | ------------- |
| 0   | 0-3 (2x2, row-major) | 16x16 | (0,0)         |
| 1   | 4-5                  | 8x16  | (16,0)        |
| 2   | 6-7                  | 16x8  | (0,16)        |
| 3   | 8                    | 8x8   | (16,16)       |

**How this was found**: decoding the naive flat-3x3-raster order first and
pixel-diffing against a known-good reference showed a very specific
signature — the bottom third of the image matched perfectly, but the top
two-thirds didn't, and the mismatched region wasn't clean tile-sized blocks
(which a simple tile-order swap would produce). That pattern is what pointed
at "the tiles are right, the _grouping_ into a rectangle is wrong" rather
than a wrong address — confirmed by reading the actual OAM setup code
instead of guessing further permutations. Palette index 0 is transparent
(green chroma-key, standard GBA sprite convention).

## Offline Python tooling (maintainer/verification use only)

Not needed to use the overlay — `GfxExtract.lua` handles extraction live.
Kept for re-verifying the decode logic if it's ever in doubt (e.g. after
discovering the ROM has a regional variant, or if the decompilation project
renumbers something):

- `scripts/gba_gfx.py` — the from-scratch GBA 4bpp-tile/BGR555-palette
  decoder + minimal PNG writer `GfxExtract.lua`'s Lua port is based on. No
  third-party dependencies (no Pillow) — deliberate, since a minimal
  indexed-color PNG writer is a small enough amount of code that pulling in
  a whole imaging library wasn't worth it just for this.
- `scripts/extract_area_icons.py` — regenerates `overlay/images/areas/*.png`
  from a ROM using `gba_gfx.py`, for comparison against `GfxExtract.lua`'s
  own output if the two are ever suspected to disagree. Reads whichever
  `.gba` file it finds under `rom/` (gitignored) unless a path is given
  explicitly.

  ```
  python scripts/extract_area_icons.py
  ```

- `scripts/extract_egg_hatch_icons.py` — a _different, now-superseded_
  method: rather than decoding raw ROM tile data, it crops frame 0 out of
  `reference/pokepinballrs/graphics/mon_hatch_sprites/*.png` (pret's decomp
  ships these as already-rendered per-species sheets, 5x3 grid of 24x24
  animation frames) and re-keys the green chroma-key background to real
  alpha transparency. This predates working out the `gDexAnimationIx`/OAM
  addressing above and isn't what `GfxExtract.lua` uses — kept only because
  it's a working independent cross-check of the final pixel output (it
  doesn't touch raw ROM tile data at all, so it can't share a bug with the
  ROM-address-based path). Uses Pillow, unlike `gba_gfx.py` — reprocessing
  an already-real PNG doesn't benefit from reimplementing a PNG parser by
  hand the way decoding raw tile data does.

## If more unsplit graphics show up

Any other still-unsplit graphics (check for a bare
`.incbin "baserom.gba", <offset>, <size>` in `reference/pokepinballrs/data/`
with no per-asset `.4bpp`/`.png` breakdown) can reuse
`scripts/gba_gfx.py`'s `assemble_metatile_image` directly — just confirm the
`mwidth`/`mheight`/`width` (i.e. `meta_wide`/`meta_tall`) parameters against
a known image first, the way Treecko was used above, rather than assuming
the same 2x2 scheme holds for a different asset's dimensions. If it turns
out not to be a flat rectangular tile grid at all (like the egg-hatch case),
go straight to reading the actual OAM/display setup code rather than trying
to guess a tile permutation by trial and error — that's what worked here.
