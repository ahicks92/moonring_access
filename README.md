# MoonringAccess

A blind-accessibility mod for **Moonring** (Fluttermind's LÖVE 2D roguelike
RPG): screen-reader output via [Prism](https://github.com/ethindp/prism),
audio navigation cues, and a keygraph UI layer that owns every menu. Loaded
via the [Lovely Injector](https://github.com/ethangreen-dev/lovely-injector).

Status: alpha. The game is broadly playable by ear: menus, character
creation, exploration, keyword conversations, shops, inventory, the notes
journal, the gods/skill screen, the character sheet, both map screens
(overworld and dungeon), combat with melee and ranged targeting, and the
message log all speak. Not yet covered: the full-screen text scrollback, the
help screen, the ending sequences, and settings/key rebinding.

## Menus

The game's own keys are unchanged (WASD move, E interact, Space wait,
F safety, Q quiet, R ranged, I inventory, Escape menu bar, backquote
console). In any mod-voiced screen:

- Arrows or WASD navigate; Enter or E activates; Escape stays the game's
  cancel.
- Space reads the focused item's full details (item stats and prices, god
  descriptions, map-block breakdowns).
- Left/Right adjust value rows and switch categories (inventory, sell,
  notes); Shift+Left/Right is a coarse step on sliders.
- Tab and Shift+Tab cycle panes on the bigger screens (character sheet,
  shops); Home and End jump to the ends of the current list.

## Exploration cursor

A second tile cursor, decoupled from the player. Speech is differential —
a step speaks only what changed — and every step plays a tile cue (ground,
wall, entity, unexplored).

- Arrows or numpad 8/4/6/2 step; Shift+direction skips to the next
  different tile.
- Numpad 5 reads the tile in full (during a conversation it instead reads
  what you've typed plus the visible keywords).
- Numpad 0 or slash recenters on you; Ctrl+Tab jumps to the current combat
  target.
- The cursor re-homes to you each game turn, and is capped at 30 tiles out.

## Scanner

A nearest-first catalog of everything found on the level.

- PageUp/PageDown step entries; Ctrl+PageUp/PageDown switch category:
  Visible, Monsters, People, Doors and gates, Stairs and exits, Loot,
  Hazards, Lights, Readables, Secrets, Everything.
- Home points the exploration cursor at the selection; End rescans.

## Announcers and status keys

- H: hostiles in sight, nearest first. Ctrl+H: points of interest in line
  of sight. Alt+H: notable terrain, grouped with counts.
- Ctrl+X vitals, Ctrl+M money, Ctrl+P position, Ctrl+T turn count,
  Ctrl+Q safety/quiet modes, Ctrl+C character summary.
- Ctrl+S status effects (active, then building); Ctrl+Shift+S counts the
  hidden doors and traps left on the level (the scanner's Secrets category
  has locations).
- Backslash: weather report on the overworld and in wilderness zooms
  (amber fog, wind, sky, date and moon).
- Alt+Backslash: where is the tracked map location from here.

## Maps

The game's map key (M) opens two different mod screens:

- Overworld: known locations nearest-first with their status (known, seen,
  visited). Enter tracks a location; Alt+Backslash then reads its compass
  offset from anywhere. Details add region and distance.
- Dungeons: the level as a grid of 9 by 9 tile blocks (usually one room
  each). Arrowing between blocks plays a connection earcon — one short
  tone per side you could potentially pass: north high, south low,
  east/west panned to their side. Labels tell exploration state
  (unexplored, entrance unseen, glimpsed, partly explored) and contents
  (stairs, locked doors and whether you hold the key, chests, warps).
  Space gives a per-side breakdown; Enter points the exploration cursor at
  the block's most useful feature and closes the map.

## Movement sound

- Wall echo (Ctrl+E toggles, Ctrl+W opens a live tuning screen): each move
  pings the wall ahead — west hard left, east hard right, north a rising
  pair, south a falling pair; closer is sooner and louder. Side-clearance
  changes chirp: gentle rise means widened, loud fall means narrowed.
- Step sounds (Ctrl+F toggles): terrain-keyed footfalls — wood, soft,
  stone, water, sand.

## Automatic speech

Game log lines, the player's rising text (pickups, mode toggles, damage),
NPC dialogue, terrain changes underfoot (roads speak only at corners and
junctions), newly spotted landmarks ("Spotted:"), monster alerts with
offsets, secret door and trap reveals with offsets, targeting and target
cycling, status effects building and fading, gaze links, detection radius
while sneaking, and quickslot bind changes. Offsets always come last in an
utterance.

## Review buffers

Ctrl+Left/Right switch buffer; Ctrl+Up/Down step lines (up is older; new
content snaps back to latest). Buffers: Game log, Conversation
(speaker-prefixed), Ask about (unused keywords for the current speaker),
and Details (the focused menu item's lines, kept live).

## Development

- `src/` is the mod. `scripts/deploy.ps1` junctions it to
  `%APPDATA%\Moonring\Mods\MoonringAccess` and installs lovely's
  version.dll beside the game.
- `scripts/launch.ps1` starts the game without stealing focus, muted
  unless you pass `-Speak`, and waits for the dev server.
- Dev server on `127.0.0.1:8771`: `/health`, `POST /eval` (persistent Lua
  REPL), `/speech?since=N` and `/log?since=N`, `POST /key`, `/gui` (live
  overlay graph), `/screenshot`, `POST /reload` (hot reload; a compile
  error keeps the running version). New source files must be added to both
  `src/lovely.toml` and the module list in `src/moonring_access.lua`, and
  need a game restart once.
- `scripts/backup-saves.ps1` and `restore-saves.ps1` guard real saves
  around automated runs.
- The game's extracted Lua source lives outside this repo at
  `../moonring-decomp` (copyrighted; local reference only; never
  committed).

## Credits

Speech stack and keygraph engine ported from Brad Renshaw's
[Blindfold](https://github.com/bradjrenshaw/Blindfold) (Balatro); gameplay
access design (exploration cursor, wall echo, scanner, announcer family)
follows Tanglebeep (Tangledeep); the map connection earcon is ported from
OniAccess (Oxygen Not Included). Prism is by Ethin Probst (MPL-2.0),
Lovely Injector by ethangreen-dev (MIT).
