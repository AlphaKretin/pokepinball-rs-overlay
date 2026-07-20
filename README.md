# pprs-tas-tools

Tooling for a tool-assisted speedrun (TAS) of *Pokémon Pinball: Ruby & Sapphire*
(GBA), targeting Pokédex completion.

## Emulator target

[BizHawk](https://github.com/TASEmulators/BizHawk), using the mGBA core.
GBAHawk (the from-scratch accuracy-focused GBA core) was considered but is
currently unmaintained and not bundled with mainline BizHawk, so it's not a
target for now.

## Layout

- `lua/` — BizHawk-side Lua scripts: reading game state out of RAM, driving
  input sequences, live RNG probes.
- `python/` — analysis and offline tooling fed by data from `lua/`: physics
  solving (input sequence from a desired ball trajectory), RNG search/
  manipulation, visualization of game state, one-off asset extraction from
  the ROM (see `docs/graphics-extraction.md`).
- `docs/` — our own notes: RAM structures (named/annotated from the `pret`
  decompilation), RNG findings, physics model writeups.
- `reference/` (gitignored) — external repos kept for reference, not vendored
  into the build. Currently:
  - [`pokepinballrs`](https://github.com/pret/pokepinballrs) — a decompilation
    of this exact ROM (`sha1: 9fec81ce2c5df589e0371a0bf2f92a5fe8db730b`), used
    as ground truth for RAM addresses and data structures.
- `rom/` (gitignored) — the ROM itself, not committed.

## Prior art

- [eliilek's "Sapphire Field" TAS](https://tasvideos.org/6951S) — the only
  published TAS of this game. Notes describe the RNG advancing once per frame
  based on an in-game timer, and physics exploits (ball-wedging,
  collision-desync hits). No tools or scripts were published alongside it.
