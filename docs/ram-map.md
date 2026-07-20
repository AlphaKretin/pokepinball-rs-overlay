# RAM map

Our own annotated reference for RAM structures relevant to TAS tooling,
derived from the [`pret/pokepinballrs`](https://github.com/pret/pokepinballrs)
decompilation (kept at `reference/pokepinballrs/`, gitignored). Struct/field
offsets are taken from that project's own inline comments, which it treats as
verified via matching-build decompilation — addresses below should be
reliable, not speculative, unless flagged otherwise.

`gPinballGameState` (the runtime `struct PinballGame` instance) is the base
for most in-game state, at EWRAM `0x02000000` (`sym_ewram.txt:1`).
`gMain` (`struct Main`) holds system-level state, at EWRAM `0x0200B0C0`
(`sym_ewram.txt:101`).

## Ball physics

`struct BallState`, defined `include/global.h:93-112`. Two live instances at
`PinballGame.ballStates[2]` (offset `0x1334`); active pointers
`PinballGame.ball` (`0x132C`, primary) and `PinballGame.secondaryBall`
(`0x1330`, multiball). Ball 1 base: `0x02001334`.

| Field | Offset (from ball base) | Notes |
|---|---|---|
| `ballHidden` | `0x00` | whether ball is currently drawn/active |
| `spinAcceleration` | `0x04` | |
| `spinSpeed` / `prevSpinSpeed` | `0x06` / `0x08` | sprite roll speed |
| `spinAngle` / `prevSpinAngle` | `0x0A` / `0x0C` | sprite roll angle |
| `positionQ0` | `0x10` | `Vector16`, integer screen-space-ish position |
| `velocity` | `0x30` | `Vector16` |
| `positionQ8` / `prevPositionQ8` | `0x34` / `0x3C` | `Vector32`, true simulated position in Q24.8 fixed point — this is the one to read for physics |

Related fields directly on `PinballGame` (base `0x02000000`):

| Field | Offset | Notes |
|---|---|---|
| `gravityStrengthIndex` | `0x01E` | |
| `ballFrozenState` | `0x01F` | |
| `ballInLaunchChute` | `0x020` | |
| `collisionResponseType` / `collisionSurfaceType` | `0x022` / `0x023` | |
| `ballCatchState` | `0x025` | |
| `flipper[2]` | `0x13BC` | `struct FlipperState`, per-side flipper position/collision; struct defined `include/global.h:116-128` |
| `activeBallIndex` | `0x066` | which of the two ball slots is primary (multiball) |

Full struct layout with inline offset comments: `include/global.h:130-880`.

## RNG

- State: `gMain.rngValue` (`int`, `include/main.h:85`) — absolute `0x0200B108`.
- Advance: `Random()`, `src/main.c:179-183` — a textbook LCG:
  ```c
  u32 Random(void)
  {
      gMain.rngValue = 1103515245 * gMain.rngValue + 12345;
      return gMain.rngValue & 0xFFFF;
  }
  ```
- `gMain.systemFrameCount` (offset `0x4C`, abs `0x0200B10C`) increments once
  per frame in `MainLoopIter()` (`src/main.c:286`) — but this is **not** a
  1:1 proxy for RNG advancement.

**Important**: `Random()` is called ad hoc, scattered across ~25 gameplay
source files, only when a specific entity/mode needs a value that frame — the
number of calls per frame varies with active board/entity logic. There's also
explicit reseeding, not just advancing:
- Frame-count "catch-up" burn: `numRngAdvances = gMain.systemFrameCount % 16`
  then that many `Random()` calls (`src/all_board_pinball_game_main.c:51-53`,
  `src/spheal_process3.c:42-46`).
- Direct reseed from frame count: `gMain.rngValue = gMain.systemFrameCount`
  (seen alongside the burn-in above, e.g. `spheal_process3.c`).
- `GetTimeAdjustedRandom()` (`src/main_board_catch_hatch_picker.c:133-136`):
  `Random() + gMain.systemFrameCount + gMain.fieldFrameCount` — mixes RNG
  output with two separate frame counters. `fieldFrameCount` (offset `0x50`,
  abs `0x0200B110`) is a per-field/board frame counter distinct from
  `systemFrameCount`.

**Implication for TAS RNG manipulation**: frame-perfect prediction needs
per-board-state `Random()` call-count tracking, not just frame counting. The
eliilek TASVideos submission's "RNG advances once per frame" description is a
simplification — true for some contexts, not universally.

**Open / to verify experimentally**: whether `rngValue`/`systemFrameCount`/
`fieldFrameCount` survive savestate load or the pause menu (matters a lot for
TAS determinism — untested so far). Not all ~40 `Random()` call sites have
been audited for reseed edge cases; only the two patterns above are confirmed.

## Pokédex / catch state

Two arrays exist — don't conflate them:

- **Authoritative, SRAM-persisted**: `gMain_saveData.pokedexFlags[NUM_SPECIES]`
  (`struct SaveData`, `include/main.h:23-34`, field `include/main.h:25`),
  embedded in `gMain` at offset `0x74` → abs `0x0200B134` (cross-checked
  against `sym_ewram.txt:106`). Values (`include/variables.h:13-16`):
  `SPECIES_SEEN=1`, `SPECIES_SHARED=2`, `SPECIES_SHARED_AND_SEEN=3`,
  `SPECIES_CAUGHT=4`. Updated via `SaveFile_SetPokedexFlags(species, flag)`
  (`src/save.c:98-119`), which also recomputes the SRAM checksum.
- **UI scratch copy only, not live source of truth**: `gPokedexFlags[]`
  (abs `0x0202A1C0`, `sym_ewram.txt:368`) — loaded from save via
  `LoadPokedexFlagsFromSave()`, used by `src/pokedex.c` and for link-cable
  trading (`gPokedexFlagExchangeBuffer`).
- Display-only totals, recomputed each time the dex UI opens:
  `gPokedexNumSeen` (abs `0x0202BEB8`), `gPokedexNumOwned`
  (abs `0x0201A514`).
- `PinballGame.caughtMonCount` (offset `0x5F0`) — caught count for the
  *current session*, not total dex progress.
- `CheckAllPokemonCaught()` (`src/pokedex.c:185` call site) — drives the
  link-cable trade icon. **Body not yet read** — exact completion definition
  (all species vs. some subset) needs verification before we build a
  completion tracker off it.

## Stage / biome / current spawn

- `gMain.selectedField` / `gMain.tempField` (offset `0x04` / `0x05`, abs
  `0x0200B0C4` / `0x0200B0C5`) — Ruby (`FIELD_RUBY=0`) or Sapphire
  (`FIELD_SAPPHIRE=1`), see `include/constants/fields.h:4-6`.
- `PinballGame.area` (offset `0x035`, abs `0x02000035`) — which of 14
  sub-areas (`include/constants/areas.h:4-18`, e.g. `AREA_FOREST_RUBY=0`,
  `AREA_CAVE_SAPPHIRE=7`, `AREA_RUIN_SAPPHIRE=13`). Chosen by a roulette:
  `areaRouletteSlotIndex` / `areaRouletteNextSlot` / `areaRouletteFarSlot`
  (offsets `0x032`-`0x034`), set in `src/main_board_intro_mode.c:25` via
  `(Random() + gMain.systemFrameCount) % 6`.
- `PinballGame.currentSpecies` (offset `0x598`, abs `0x02000598`) — currently
  spawned/catchable species. Also `lastCatchSpecies` (`0x59C`),
  `lastEggSpecies` (`0x59E`).
- Spawn selection logic, `src/main_board_catch_hatch_picker.c`:
  - `BuildSpeciesWeightsForCatchEmMode()` (line 156) builds a cumulative
    weight table `PinballGame.speciesWeights[25]` (offset `0x130`) from
    `gWildMonLocations[area][threeArrows][i]`, weighted by dex progress via
    `gCommonAndEggWeights[pokedexFlags[species]]` — so late-game catches skew
    toward species we haven't caught yet. Special-cased for rare species and
    e-Reader cards.
  - `PickSpeciesForCatchEmMode()` (line 252) rolls
    `GetTimeAdjustedRandom() % totalWeight` and walks `speciesWeights[]`
    (lines 342-346) to pick. Hidden branch for rare species
    (Aerodactyl/Chikorita/Totodile/Cyndaquil/Latios-or-Latias) when
    `rand == 0 && caughtMonCount >= 5`.
- `PinballGame.boardState` / `nextBoardState` / `boardSubState`
  (offsets `0x013`-`0x017`) — dispatches which board-process is running.
  Relevant values (`include/constants/board/main_board.h:15-25`):
  `MAIN_BOARD_STATE_CATCH_EM_MODE=4`, `MAIN_BOARD_STATE_EGG_HATCH_MODE=5`,
  `MAIN_BOARD_STATE_EVO_MODE=6`, `MAIN_BOARD_STATE_TRAVEL_MODE=7`,
  `MAIN_BOARD_STATE_JIRACHI_CATCH_MODE=8`.

**Important**: `currentSpecies` is never cleared/reset by the game — a
full-repo grep of `src/` found no assignment to `SPECIES_NONE`/0 in a "clear"
context, only overwrites when a new species is picked (catch, hatch,
evolution, legendary encounters). It holds stale data (defaults to species 0
"Treecko" before the first pick, then whatever was last shown) whenever no
catchable Pokémon is actually on display. To know whether it's currently
meaningful, gate on `boardState` being one of the three values above — don't
read `currentSpecies` unconditionally.

**Open / to verify**: contents of `gWildMonLocations` (species-per-area table)
and `gCommonAndEggWeights` (rarity weight table) — these are data tables, not
single variables; not yet read. They matter for predicting/manipulating
spawns.

## Score / HUD

All on `PinballGame` (base `0x02000000`), lower priority than the above:

| Field | Offset | Notes |
|---|---|---|
| `scoreLo` / `scoreHi` | `0x044` / `0x048` | u32; `scoreLo` counts to 99,999,999 then overflows into `scoreHi` |
| `numLives` | `0x030` | s8, ball count/lives remaining |
| `ballSpeed` | `0x031` | |
| `coins` | `0x192` | Sapphire pond mini-currency |
| `bonusMultiplier` | `0x62F` | |
| `bonusSubtotal` / `bonusCategoryScore` / `totalBonusScore` | `0x630` / `0x634` / `0x544` | bonus-stage scoring |

## Wild spawn pool (static ROM data)

`gWildMonLocations`: ROM, `data/mon_locations.inc:1`, abs `0x08055A84`.
Shape `[AREA_COUNT=14][2][8]` of `u16` `SPECIES_*` values (`species.h`
numbering, `SPECIES_NONE`-padded when a row has fewer than 8 entries).
Area-major, then a "two arrows" row (index 0, used whenever `catchModeArrows`
is 0/1/2), then a "three arrows" row (index 1, used only when all three GET
arrows are lit). `catchModeArrows`: `PinballGame` offset `0x73D`.

Row address: `0x08055A84 + (area * 2 + (threeArrowsLit and 1 or 0)) * 16`.

This is the structural pool — which species can possibly spawn, not weighted
by how likely each one is. Actual pick probability is computed by
`BuildSpeciesWeightsForCatchEmMode()` (`src/main_board_catch_hatch_picker.c:156-249`)
into `PinballGame.totalWeight` (offset `0x12E`, s16) and
`PinballGame.speciesWeights[25]` (offset `0x130`, s16 array, **cumulative**
sum — only indices `[0..7]` are meaningful for catch-em mode, aligned
1:1 with the same `gWildMonLocations[area][threeArrows][i]` slot order used
for the pool above; the rest of the 25-entry buffer is reused by
`BuildSpeciesWeightsForEggMode()` for unrelated data). Per-slot weight is
`speciesWeights[i] - speciesWeights[i-1]` (with `speciesWeights[-1] = 0`);
percent chance is `weight / totalWeight * 100`.

The weighting itself factors in dex-progress (`gCommonAndEggWeights` =
`{10, 10, 15, 15, 2}` for unseen/seen/shared/shared+seen/caught,
`data/rom_2.s:4276-4277`), a hardcoded rare-species set with E-Reader-bonus
doubling, a `Clamperl` evolution-branch special case, a generic
evolution-chain max-weight lookup, and a no-repeat rule against
`lastCatchSpecies` — not reimplemented in Lua, we read the game's own
computed result instead. That result is **only valid while
`boardState == 4`** (`MAIN_BOARD_STATE_CATCH_EM_MODE`) — the overlay gates on
this before reading `speciesWeights`/`totalWeight`, same staleness pattern as
the `currentSpecies` fix. Outside that state the pool is still shown, just
without percentages.

There's also a separate hidden legendary/bonus-species branch (Chikorita,
Cyndaquil, Totodile, Aerodactyl, Latios-or-Latias) in
`PickSpeciesForCatchEmMode()` (lines 282-333) that bypasses
`gWildMonLocations` entirely — roughly 1-in-50/1-in-100 odds, gated behind
`caughtMonCount >= 5` and a `gBoardConfig` species-caught-count threshold not
yet located. Not reflected in the pool listing.

## Species evolution data (static ROM data)

`gSpeciesInfo`: ROM, `struct PokemonSpecies` (`include/types.h:74-84`) array of
`NUM_SPECIES` (205) entries, `0x16` (22) bytes each, `species.h` numbering.
`evolutionTarget` field at struct offset `0x15` (u8; a value `>= SPECIES_NONE`
(205) means "no further evolution").

Unlike `gWildMonLocations`, this is defined as plain C data
(`src/data/species.h`), not hand-placed asm, so its source has no `@ 0x08...`
address comment — pret's own repo doesn't give us this address without an
actual linked build. **Found empirically instead**: BizHawk's Hex Editor,
ROM domain, searching for the ASCII string `TREECKO   ` (name field, space-padded
to 10 chars, struct offset `0x07` — see `src/data/species.h:5`) landed at file
offset `0x6A3707`. Subtracting the `0x07` field offset gives the table base as
a raw file offset (`0x6A3700`); adding the GBA ROM base (`0x08000000`) gives
the real address: **`0x086A3700`**. Verified only against `SPECIES_TREECKO`
(index 0) — not cross-checked against a second species, so if anything reads
wrong here first, re-verify the entry stride (`0x16`) and base by hex-searching
a second name (e.g. `GROVYLE   `, expect it at `0x086A3700 + 0x16`).

## Known gaps

Things not yet confirmed from source reading — either need more digging in
`reference/pokepinballrs/` or need to be checked experimentally via BizHawk
RAM watch:

1. `CheckAllPokemonCaught()` completion definition.
2. `gWildMonLocations` / `gCommonAndEggWeights` data table contents.
3. Whether RNG/frame-counter state survives savestate load or pause — load a
   savestate mid-game and watch `0x0200B108`/`0x0200B10C`/`0x0200B110` for any
   discontinuity.
4. Full audit of `Random()` call sites (~40 total, only 2 reseed patterns
   confirmed so far) for exhaustive per-board-state RNG prediction.
5. `sym_bss.txt` / `sym_common.txt` not yet checked for IWRAM-resident hot
   copies of any of the above.
