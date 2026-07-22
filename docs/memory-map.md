# Memory map

Our own annotated reference for the RAM/ROM structures `overlay/` actually
reads, derived from the
[`pret/pokepinballrs`](https://github.com/pret/pokepinballrs) decompilation. Struct/field offsets are
taken from that project's own inline comments, which it treats as verified
via matching-build decompilation — addresses below should be reliable, not
speculative, unless flagged otherwise.

**See also**: [RetroAchievements' code notes for this
game](https://retroachievements.org/codenotes.php?g=789) — a separate,
community-maintained address list, useful as a second source or for anything
not covered here. This doc isn't a copy of it and doesn't attempt to track it
1:1; it's scoped to what this overlay specifically reads, sourced from the
decompilation above rather than transcribed from RA.

`gPinballGameState` (the runtime `struct PinballGame` instance) is the base
for most in-game state, at EWRAM `0x02000000` (`sym_ewram.txt:1`).
`gMain` (`struct Main`) holds system-level state, at EWRAM `0x0200B0C0`
(`sym_ewram.txt:101`).

## Ball physics

`struct BallState`, defined `include/global.h:93-112`. Two live instances at
`PinballGame.ballStates[2]` (offset `0x1334`); active pointers
`PinballGame.ball` (`0x132C`, primary) and `PinballGame.secondaryBall`
(`0x1330`, multiball). Ball 1 base: `0x02001334`.

| Field                           | Offset (from ball base) | Notes                                                                                          |
| ------------------------------- | ----------------------- | ---------------------------------------------------------------------------------------------- |
| `ballHidden`                    | `0x00`                  | whether ball is currently drawn/active                                                         |
| `spinAcceleration`              | `0x04`                  |                                                                                                |
| `spinSpeed` / `prevSpinSpeed`   | `0x06` / `0x08`         | sprite roll speed                                                                              |
| `spinAngle` / `prevSpinAngle`   | `0x0A` / `0x0C`         | sprite roll angle                                                                              |
| `positionQ0`                    | `0x10`                  | `Vector16`, integer screen-space-ish position                                                  |
| `velocity`                      | `0x30`                  | `Vector16`                                                                                     |
| `positionQ8` / `prevPositionQ8` | `0x34` / `0x3C`         | `Vector32`, true simulated position in Q24.8 fixed point — this is the one to read for physics |

Related fields directly on `PinballGame` (base `0x02000000`):

| Field                                            | Offset            | Notes                                                                                                 |
| ------------------------------------------------ | ----------------- | ----------------------------------------------------------------------------------------------------- |
| `gravityStrengthIndex`                           | `0x01E`           |                                                                                                       |
| `ballFrozenState`                                | `0x01F`           |                                                                                                       |
| `ballInLaunchChute`                              | `0x020`           |                                                                                                       |
| `collisionResponseType` / `collisionSurfaceType` | `0x022` / `0x023` |                                                                                                       |
| `ballCatchState`                                 | `0x025`           |                                                                                                       |
| `flipper[2]`                                     | `0x13BC`          | `struct FlipperState`, per-side flipper position/collision; struct defined `include/global.h:116-128` |
| `activeBallIndex`                                | `0x066`           | which of the two ball slots is primary (multiball)                                                    |

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

**Implication for RNG prediction/manipulation**: frame-perfect prediction
needs per-board-state `Random()` call-count tracking, not just frame
counting. The eliilek TASVideos submission's "RNG advances once per frame"
description is a simplification — true for some contexts, not universally.

**Open / to verify experimentally**: whether `rngValue`/`systemFrameCount`/
`fieldFrameCount` survive savestate load or the pause menu — untested so
far. Not all ~40 `Random()` call sites have been audited for reseed edge
cases; only the two patterns above are confirmed.

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
  _current session_, not total dex progress.
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

`gWildMonLocations` (species-per-area table) has been read successfully since
`overlay/panels/NormalBoardPanel.lua`'s `readAreaSpeciesRows` (spawn-pool grid
display, working since one of the repo's earliest commits) — address/shape
confirmed correct in practice, not just in theory. `gCommonAndEggWeights`
(rarity weight table) is still unread by any code in this repo.

## Travel mode (area-to-area movement)

`PinballGame.areaRouletteSlotIndex` / `areaRouletteNextSlot` / `areaRouletteFarSlot`
(offsets `0x032`/`0x033`/`0x034`) index into `gAreaRouletteTable` (ROM,
`data/rom_1.s:11`, abs `0x08055A68`, shape `s16[2 fields][7 slots]`, row
stride 14 bytes) to resolve `PinballGame.area`. Slots 0-5 per field are the
normal 6-area travel ring. Slot 6 is Ruin — **not** e-reader-exclusive: it's
also the guaranteed, deterministic destination of every 6th travel since the
last Ruin visit (see `areaVisitCount` below), independent of the e-reader
card. The card only affects which area the roulette _starts_ you on.

`UpdateTravelMode()` (`src/main_board_travel_mode.c:143-163`) resolves the
destination a travel-mode launch lands on:

```c
if (areaVisitCount < 5)
{
    if (travelRolloverTriggerHitZone == TRAVEL_ROLLOVER_TRIGGER_HIT_ZONE_LEFT)
        areaRouletteSlotIndex = areaRouletteNextSlot;  // "go left"
    else
        areaRouletteSlotIndex = areaRouletteFarSlot;   // "go right" (skips one)
    // ...NextSlot/FarSlot advance, areaVisitCount++
}
else
{
    areaRouletteSlotIndex = 6;  // Ruin, unconditionally -- hit zone ignored
    areaVisitCount = 0;
}
```

So on any travel where `areaVisitCount < 5`, the current left/right
destinations are just `gAreaRouletteTable[selectedField][areaRouletteNextSlot]`
(left) and `gAreaRouletteTable[selectedField][areaRouletteFarSlot]` (right).
`NextSlot`/`FarSlot` are recomputed on every area-roulette spin
(`main_board_intro_mode.c:209-211`, at the start of a ball) and every ring
travel (`main_board_travel_mode.c:155-156`), and hold valid resting values
the rest of the time — unlike `currentSpecies`/`speciesWeights`, no
board-state staleness gate is needed to read them.

Ruin's override branch (`areaVisitCount >= 5`) never writes `NextSlot`/
`FarSlot` — they carry through a Ruin visit unchanged, so the travel after
Ruin resumes with exactly the same two ring destinations the forced travel
skipped.

## Menu state / bonus stages

Confirmed against `reference/pokepinballrs/` source only — **not yet
live-verified in BizHawk**, unlike most of the rest of this doc. Verify
against live RAM once each state below is actually reachable, same as any
other source-derived-only entry.

- `gMain.mainState` (offset `0x02`, abs `0x0200B0C2`,
  `include/main.h:39`) — top-level screen dispatch. Values
  (`include/constants/global.h:4-15`): `STATE_INTRO=0`, `STATE_TITLE=1`
  (main menu), `STATE_GAME_MAIN=2`, `STATE_GAME_IDLE=3`, `STATE_OPTIONS=4`,
  `STATE_POKEDEX=5`, `STATE_SAVE_ERASE=6`, `STATE_EREADER=7`,
  `STATE_SCORES_MAIN=8`, `STATE_SCORES_IDLE=9`, `STATE_FIELD_SELECT=10`,
  `STATE_BONUS_FIELD_SELECT=11`. Only `STATE_GAME_MAIN`/`STATE_GAME_IDLE`
  mean a board (normal or bonus) is actually loaded and playable —
  `PinballGame.area`/wild-mon-table reads are only meaningful then, gated
  further by `selectedField` below.
- `gMain.selectedField` (offset `0x04`, already documented above for its
  Ruby/Sapphire values) extends to bonus fields
  (`include/constants/fields.h:4-14`): `FIELD_DUSCLOPS=2`, `FIELD_KECLEON=3`,
  `FIELD_KYOGRE=4`, `FIELD_GROUDON=5`, `FIELD_RAYQUAZA=6`, `FIELD_SPHEAL=7`,
  `MAIN_FIELD_COUNT=2`. Confirmed the authoritative board-type dispatch key
  in `src/all_board_pinball_game_main.c` (e.g. lines 93-100, 176-253,
  401-475). Also confirmed (`src/field_select.c:280`) it tracks the
  *currently highlighted* field every frame during `STATE_FIELD_SELECT`
  (not just on confirm), and that screen only ever sets it to 0/1.
- `PinballGame.boardState` (offset `0x013`, already listed above for the
  normal-board `MAIN_BOARD_STATE_*` values) is reused per-bonus-board with
  entirely different enums:
  - Kecleon (`include/constants/board/kecleon_states.h`):
    `KECLEON_BOARD_STATE_BATTLE_PHASE=1`.
  - Dusclops (`include/constants/board/dusclops_states.h`):
    `DUSCLOPS_BOARD_STATE_1_DUSKULL_PHASE=1`,
    `DUSCLOPS_BOARD_STATE_3_DUSCLOPS_PHASE=3`.
  - Kyogre/Groudon/Rayquaza share `LegendaryBoardState`
    (`include/constants/board/bonus_board.h`):
    `LEGENDARY_BOARD_STATE_BATTLE_PHASE=1`.
- `PinballGame.legendaryHitsRequired` (offset `0x384`, s8,
  `include/global.h:504`) — live RAM, computed at stage entry as `18` if
  `numCompletedBonusStages % 5 == 3` else `15`
  (`src/kyogre_process3.c:50-53`, `src/groudon_process3.c:44-47`,
  `src/rayquaza_process3.c:38-41`, identical pattern in all three). Kyogre/
  Groudon/Rayquaza only — read directly rather than reimplementing the
  15-vs-18 logic.
- `PinballGame.bonusModeHitCount` (offset `0x385`, s8,
  `include/global.h:505`) — **shared field, meaning depends on which
  board/boardState is active**:
  - Kecleon (`src/kecleon_process3.c:620,636`): hit count, hardcoded max 10.
  - Dusclops Duskull phase (`boardState==1`, `dusclops_process3.c:443`):
    Duskulls defeated. `DUSKULL_NEEDED_TO_PHASE_TRANSFER=20`
    (`dusclops_process3.c:11`), but the actual transition gate is fuzzier
    than a clean 20: spawning stops once `bonusModeHitCount > 18`
    (`DUSKULL_ALLOWED_TO_SPAWN`, `:13`), at most 2 Duskulls are ever
    concurrently alive (`minionActiveCount < 2`, `:288`, despite the 3-slot
    array/`DUSKULL_CONCURRENT_MAX`), and the phase only advances once every
    already-spawned Duskull is cleared (`:266-280`) — so the realistic
    final count is 19 or 20 depending on exactly how many were still alive
    when the 18-kill spawn-gate closed.
  - Dusclops Dusclops phase (`boardState==3`, reset on entry `:124`,
    incremented `:872`): direct hits,
    `DUSCLOPS_HITS_NEEDED_TO_SUCCEED=5` (`:14,858`).
  - Kyogre/Groudon/Rayquaza: hits vs. `legendaryHitsRequired` above.
- **Devon Scope power-up** (Kecleon board only — makes the otherwise
  invisible Kecleon appear on screen for a set time): `kecleonTargetActive`
  (offset `0x406`, s8/bool, `include/global.h:558`) and `kecleonAnimTimer`
  (offset `0x408`, u16, `include/global.h:560`). Confirmed via
  `UpdateKecleonScopeItem`/`UpdateKecleonScopeVision`
  (`src/kecleon_process3.c:928-1052`): the falling scope orb hitting the
  ball sets `kecleonTargetActive=1` and plays `SE_KECLEON_SCOPE_ACTIVATED`;
  while active, `kecleonAnimTimer` counts 0->600 (~10s at 60fps) and drives
  `gMain.kecleonOverlayHeight` — an actual screen overlay revealing Kecleon
  regardless of its own entity state — before auto-clearing. Explicitly
  verified distinct from the unrelated hit-then-rise entity-state cycle
  (`KECLEON_ENTITY_STATE_HIT_WHILE_DOWN` -> `RESPOND_TO_HIT` ->
  `RISE_FROM_DOWN`, `:614-655`, which uses `bossFrameTimer`/
  `kecleonCamoStrength` instead and has no "scope" naming anywhere near it)
  after a specific request to double-check the two weren't being conflated.
- **Spheal minigame score breakdown**: `PinballGame.sphealKnockdownCount[2]`
  (offset `0x52C`, s8 array, `include/global.h:645`, `ix 0=spheal,
  1=ball`), incremented live at `spheal_process3.c:1291`/`:1334`. Spheal
  knockdowns worth 5,000,000 pts each, ball-through-hoop worth 1,000,000
  pts each (`spheal_process3.c:1665-1667`). There's also
  `sphealKnockdownDisplayCount[2]` (offset `0x52E`) — a slow tally-animation
  copy used only for the results-screen counting effect, not useful for a
  live readout; read `sphealKnockdownCount` directly instead.
  `PinballGame.totalBonusScore` (offset `0x544`, already documented above)
  is the computed sum, but only set once the results screen computes it
  (`:1665-1667`) — not valid during live play, unlike the two counts.
- **Not found**: a "Devon Scope" *timer* separate from the above was
  initially suspected not to exist at all (a full-repo grep for "devon"
  turned up nothing); it turned out to just be under different in-game
  naming than expected, matching the mechanic described above once searched
  for by behavior instead of name.

## Score / HUD

All on `PinballGame` (base `0x02000000`), lower priority than the above:

| Field                                                      | Offset                      | Notes                                                             |
| ---------------------------------------------------------- | --------------------------- | ----------------------------------------------------------------- |
| `scoreLo` / `scoreHi`                                      | `0x044` / `0x048`           | u32; `scoreLo` counts to 99,999,999 then overflows into `scoreHi` |
| `numLives`                                                 | `0x030`                     | s8, ball count/lives remaining                                    |
| `ballSpeed`                                                | `0x031`                     |                                                                   |
| `coins`                                                    | `0x192`                     | Sapphire pond mini-currency                                       |
| `bonusMultiplier`                                          | `0x62F`                     |                                                                   |
| `bonusSubtotal` / `bonusCategoryScore` / `totalBonusScore` | `0x630` / `0x634` / `0x544` | bonus-stage scoring                                               |

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
`lastCatchSpecies` — not reimplemented in Lua; reading the game's own
computed result instead is the only sane option. That result is **only
valid while `boardState == 4`** (`MAIN_BOARD_STATE_CATCH_EM_MODE`) — same
staleness pattern as the `currentSpecies` fix.

There's also a separate hidden legendary/bonus-species branch (Chikorita,
Cyndaquil, Totodile, Aerodactyl, Latios-or-Latias) in
`PickSpeciesForCatchEmMode()` (lines 282-333) that bypasses
`gWildMonLocations` entirely — roughly 1-in-50/1-in-100 odds, gated behind
`caughtMonCount >= 5` and a `gBoardConfig` species-caught-count threshold not
yet located. Not reflected in the pool listing.

## Egg-hatch spawn pool (static ROM data)

`gEggLocations`: ROM, abs `0x086A4A38`. Shape `[MAIN_FIELD_COUNT=2][26]` of
`u16` `SPECIES_*` values, field-major (Ruby row, then Sapphire). Unlike
`gWildMonLocations`, this is keyed only by the current field
(`gMain.selectedField`) — not by area/stage — so it's the same 25 real spawns
(`BuildSpeciesWeightsForEggMode()`'s loop bound is `i < 25`) regardless of
where on the board the player currently is. Slot 25 (the 26th entry) is
Pichu, present in the data but unused by that loop — Pichu is picked via a
separate forced-rare branch in `PickSpeciesForEggMode()`
(`src/main_board_catch_hatch_picker.c:413-442`), not read from this table.

Row address: `0x086A4A38 + field * 52`.

Unlike `gWildMonLocations`, this is defined as plain C data
(`src/data/egg_locations.h`), not hand-placed asm, so it has no `@ 0x08...`
source address comment either. **Found empirically**: hex-searched the ROM
for the Ruby row's first 10 species IDs
(Wurmple/Seedot/Ralts/Shroomish/Whismur/Skitty/Zubat/Aron/Plusle/Minun =
`13,21,28,33,44,60,62,69,79,80`) as a little-endian `u16` byte sequence —
unique match at file offset `0x6a4a38`. Confirmed by dumping the following
52 halfwords and checking them byte-for-byte against both full field rows
in `src/data/egg_locations.h`.

Weighting (`BuildSpeciesWeightsForEggMode()`,
`src/main_board_catch_hatch_picker.c:353-411`) mirrors the catch-em weight
logic — `gCommonAndEggWeights` lookup plus a 2-hop evolution-chain max, an
Oddish/Vileplume-or-Bellossom field-conditional special case (parallel to
Gloom's split in catch mode), and a no-repeat rule against `lastEggSpecies`
— not reimplemented in Lua for the same reasons as the catch-em weights
above.

## Sprite/icon graphics (static ROM data)

Unlike everything else in this doc, this data has no _runtime_ Lua reader —
it's image data, decoded once (from-scratch GBA 4bpp-tile + BGR555-palette
decode, no compression involved) by `overlay/GfxExtract.lua` the first time
the overlay launches, then cached to `overlay/images/` and loaded normally
via `gui.drawImage` from then on — see the README's Images section and
`docs/graphics-extraction.md` for the tile-arrangement/format details. Every
address below was verified byte-for-byte against the real ROM before being
ported to Lua.

**Area icons** (13 unique, `overlay/images/areas/`): `gAreaPortraitIndexes`
(ROM, `data/rom_1.s:622-625`, abs `0x08137928`, `s16[14]`) maps `AREA_*`
index to icon index 0-12 — Ruin Ruby/Sapphire share one icon
(`AREA_RUIN_RUBY=12`/`AREA_RUIN_SAPPHIRE=13` both -> icon 12), every other
area has a distinct Ruby/Sapphire icon. Gfx: `gPortraitGenericGraphics`
(`data/rom_1.s:1343-1344`, abs `0x0848D68C`) + `icon_idx * 0x300`. Pal:
`gPortraitGenericPalettes` (`data/rom_1.s:988`, abs `0x081C00E4`) +
`icon_idx * 0x20`. Both DMA'd together by `LoadPortraitGraphics()` (case
`PORTRAIT_STATE_CURRENT_LOCATION`, `src/all_board_portrait_display.c:35-41`)
whenever the travel-mode/area-roulette UI shows a location.

**Species portraits** (one per `SpeciesNames` entry, `overlay/images/portraits/`):
gfx `gMonPortraitsGroup0_Gfx` (`data/graphics/mon_portraits.inc:1`, abs
`0x084C596C`) + `species * 0x300` — the 14 named groups in that file are
back-to-back with no gap, so this is really one flat table despite the
source splitting it into groups of 15. **Palette addressing is not the same
flat shape**: each palette group carries a 16th trailing
`silhouette.gbapal` entry the gfx groups don't have
(`data/graphics/mon_portraits_pals.inc`, confirmed against the file
directly), so pal stride is `0x200`/group (16 entries), not `0x1E0`
(15 entries) — pal addr = `gMonPortraitsGroup0_Pals` (abs `0x0839AB8C`) +
`(species // 15) * 0x200 + (species % 15) * 0x20`. A flat `species * 0x20`
formula silently reads the wrong species' colors starting at species 15 —
caught by pixel-diffing decoded output against the known-good portraits
already in the repo before trusting this. Both read via
`gMonPortraitGroupGfx[species/15] + (species%15)*0x300` /
`gMonPortraitGroupPals[species/15] + (species%15)*0x20`
(`src/all_board_portrait_display.c:56-68`, case
`PORTRAIT_STATE_POKEMON_DISPLAY`); that file also uses
`gMonPortraitGroupPals[0] + 15*0x20` (i.e. group 0's own silhouette slot) as
a shared "unseen species" silhouette palette.

**Egg-hatch sprites** (31 species that can appear in an egg pool,
`overlay/images/egg_hatch/`): species -> sprite is **not** a formula — read
`s16 gDexAnimationIx[species]` (`data/rom_2.s:577`, abs `0x086A61BC`).
`-1` = no animation; `< 100` = a catch-sprite animation (different asset,
not extracted by this project); `>= 100` = hatch sprite, with
`group = (v-100) // 6` and `index = (v-100) % 6` into 6 gfx/pal groups
(`gMonHatchSpriteGroup0..5_Gfx/_Pals`, `data/graphics/mon_hatch_sprites.inc`
/ `mon_hatch_sprites_pals.inc`; gfx stride `0x10E0`/species = 15 animation
frames x `0x120` bytes, pal stride `0x20`). Only frame 0 (first `0x120`
bytes) is needed. **The 24x24 frame is not a flat 3x3 tile raster** — GBA
sprites can't be a single 24x24 OBJ, so the game composites it at runtime
from 4 separate OBJs (`gCatchCreatureOamFramesets`,
`src/main_board_to_be_split.c:1698-1723`): a 16x16 OBJ (tiles 0-3, 2x2
row-major) at (0,0), an 8x16 OBJ (tiles 4-5) at (16,0), a 16x8 OBJ
(tiles 6-7) at (0,16), and an 8x8 OBJ (tile 8) at (16,16), all reading from
the same fixed 9-tile block. Found by decoding the naive raster order first,
noticing the bottom third matched perfectly but the top two-thirds didn't
(a signature of "right decode, wrong tile grouping" rather than wrong
addresses), then reading the actual OAM setup code instead of guessing
further. Palette index 0 is transparent (green chroma-key, standard GBA
sprite convention).

## Species evolution data (static ROM data)

`gSpeciesInfo`: ROM, `struct PokemonSpecies` (`include/types.h:74-84`) array of
`NUM_SPECIES` (205) entries, `species.h` numbering. `evolutionTarget` field at
struct offset `0x15` (u8; a value `>= SPECIES_NONE` (205) means "no further
evolution"). **Entry stride is `0x18` (24) bytes, not `0x16` (22)** — the
struct's own field offsets only add up to `0x16`, but agbcc pads the struct
with 2 trailing bytes, confirmed empirically (see below). Don't derive the
stride from the field offsets alone.

Unlike `gWildMonLocations`, this is defined as plain C data
(`src/data/species.h`), not hand-placed asm, so its source has no `@ 0x08...`
address comment — pret's own repo doesn't give us this address without an
actual linked build. **Found empirically instead**: BizHawk's Hex Editor,
ROM domain, searching for the ASCII string `TREECKO   ` (name field, space-padded
to 10 chars, struct offset `0x07` — see `src/data/species.h:5`) landed at file
offset `0x6A3707`. Subtracting the `0x07` field offset gives the table base as
a raw file offset (`0x6A3700`); adding the GBA ROM base (`0x08000000`) gives
the real address: **`0x086A3700`**.

Initially assumed a `0x16`-byte stride (matching the struct's field offsets)
and shipped that in the overlay — wrong. It read `SPECIES_TREECKO` (index 0)
fine, since offset 0 needs no stride, but every other index was misaligned,
making `evolutionTarget` reads (and hence "evolution line fully caught" /
`baseWeight`) subtly wrong except at index 0. Caught by cross-checking
species index 1 (Grovyle) with `scripts/species_info_check.lua`: its
name landed 2 bytes later than `0x16` would predict, confirming `0x18`.
Lesson: always verify struct array strides against a second element, not just
the base address against the first.

## Evolution mode

`PinballGame.evolvablePartySpecies[MAX_EVOLVABLE_PARTY_SIZE=16]` (offset
`0x270`, abs `0x02000270`, `include/global.h:363`) — a FIFO queue of
caught/hatched species awaiting Evolution Mode, populated whenever a catch or
hatch result has `gSpeciesInfo[species].evolutionTarget < SPECIES_NONE`
(`src/main_board_catch_hatch_picker.c:27-36`, `113-121`). Count in
`evolvablePartySize` (offset `0x281`, s8); `evolvingPartyIndex` (offset
`0x280`, s8) tracks which queue slot is currently mid-evolution, not a count
— don't confuse the two adjacent offsets.

Evolution Mode itself (`MAIN_BOARD_STATE_EVO_MODE=6`) needs two independent
gates, both true, checked identically in several board files (e.g.
`src/ruby_catch_holes.c:399-401`, `src/main_board_to_be_split.c:504-508`):

```c
if (gCurrentPinballGame->evoArrowProgress > 2 && gCurrentPinballGame->evolvablePartySize > 0)
    RequestBoardStateTransition(MAIN_BOARD_STATE_EVO_MODE);
```

- `evoArrowProgress` (offset `0x72E`, abs `0x0200072E`) — the evo-mode arrow
  meter (parallel to `catchModeArrows`), must reach 3.
- `evolvablePartySize > 0` — the queue above must be non-empty.

Lighting all 3 evo arrows with an empty queue accomplishes nothing: the
center-hole roulette's evo-mode prize slot silently downgrades to the catch-
mode prize in that case (`src/main_board_center_capture_hole.c:107-111`).
Both `catchModeArrows` and `evoArrowProgress` are preserved (not reset) across
a ball loss within a session, restored via `arrowProgressPreserved`
(`src/all_board_state_transitions_and_idle.c:75-133`).

**Why the dex "caught" flag isn't enough to tell you this**: `pokedexFlags`
is permanent (SRAM) and says nothing about whether _this session's_ catch of
that species is still sitting in the queue — it may already have evolved out,
or the dex entry may be from a previous session with nothing queued right
now. `overlay/Overlay.lua`'s `isPendingEvolution()` walks a species and its
up-to-2-hop evolution targets (same depth as `isEvolutionLineCaught`) against
this queue to decide whether to show the "C+" (caught, evolution pending)
border state instead of plain "C".

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
