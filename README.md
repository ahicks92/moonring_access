# MoonringAccess

A blind-accessibility mod for **Moonring** (Fluttermind's LÖVE 2D roguelike RPG),
providing screen-reader output and audio navigation. Loaded via the
[Lovely Injector](https://github.com/ethangreen-dev/lovely-injector).

Status: pre-alpha, under active development. Not yet playable.

## Layout

- `src/` — the mod itself (deployed to `<savedir>/Mods/MoonringAccess` by junction)
- `scripts/launch.ps1` — build-free launcher: starts the game without stealing
  focus and waits for the mod's dev server
- `scripts/deploy.ps1` — creates the mod junction and installs lovely's
  `version.dll` next to `Moonring.exe`
- `scripts/backup-saves.ps1` / `restore-saves.ps1` — snapshot and restore the
  game's save data before automated test runs
- The game's extracted Lua source lives OUTSIDE this repo at
  `../moonring-decomp` (copyrighted; local reference only; never committed)
