# MoonringAccess

A blind-accessibility mod for **Moonring** (Fluttermind's LÖVE 2D roguelike RPG):
screen-reader output via [Prism](https://github.com/ethindp/prism), audio
navigation cues, and a keygraph UI layer that owns every menu. Loaded via the
[Lovely Injector](https://github.com/ethangreen-dev/lovely-injector).

Status: pre-alpha. The opening of the game is playable by ear: menus, character
creation, town exploration, NPC keyword conversations, inventory, looting,
melee and ranged combat, and the message log all speak. Not yet covered:
shops (buy/sell panels), notes panel, skill tree, the world map screen, and
some quest UIs.

## Controls (mod)

The game's own keys are unchanged (WASD move, E interact, Space wait, F safety,
Q quiet, R ranged, I inventory, Escape menu bar, ` console...). The mod adds:

- In any mod-voiced menu: Up/Down/Left/Right or WASD move, Enter/E activates,
  Home/End jump to the ends, Space reads the item's description where one
  exists, Escape stays the game's cancel.
- Exploration cursor (gameplay): Arrow keys or numpad 8/4/6/2 step;
  Shift+direction skips to the next different tile; numpad 5 reads the cursor
  tile in full (during a conversation it instead reads what you've typed plus
  the visible cloud words); numpad 0 or slash recenters on you. The cursor
  re-homes to you each game turn. (The numpad is never required — every
  numpad key has or will get a main-keyboard twin.)
- Wall echo (Ctrl+E toggles; Ctrl+W opens the live tuning menu): movement-
  relative, compass-fixed. One noise ping for the wall in your direction of
  travel — west always hard left, east always hard right, north a rising
  pair centered, south a falling pair centered; closer = sooner and louder.
  Flank width monitors chirp when a side's clearance changes: pan carries
  east/west, register carries north/south (high = north, low+slow = south),
  gentle contour = widened, loud contour = narrowed, and south's contour
  inverts so the pitch motion draws the direction the space extends.
- Step sounds (Ctrl+F toggles): each move plays a terrain-keyed cue — wood
  knock, soft rustle, stone tick, water double-blip, sand hiss.
- Secrets: Ctrl+S speaks how many hidden doors and traps remain on the level
  (counts only); the scanner's Secrets category lists locations. Reveals
  announce where ("Secret door, 2 left").
- Scanner: PageUp/PageDown step through found features nearest-first;
  Ctrl+PageUp/PageDown switch category (Visible, Monsters, People, Doors,
  Stairs and exits, Loot, Readables, Everything); Home points the exploration
  cursor at the selection; End rescans.
- Announcers: H = hostiles in sight; Ctrl+H = points of interest; Alt+H =
  notable terrain, grouped.
- Status: Ctrl+X vitals, Ctrl+M money, Ctrl+P position, Ctrl+T turn count,
  Ctrl+Q safety/quiet modes, Ctrl+C character summary.
- Tutorials are captured modals: any direction key re-reads, Enter dismisses;
  tutorial and alert text also lands in the Game log buffer.
- Review buffers: Ctrl+Left/Right switch buffer (Game log, Conversation),
  Ctrl+Up/Down step lines (up = older; snaps to latest on new content).

## Development

- `src/` — the mod (deployed to `%APPDATA%\Moonring\Mods\MoonringAccess` as a
  junction by `scripts/deploy.ps1`, which also installs lovely's version.dll)
- `scripts/launch.ps1` — starts the game WITHOUT stealing focus, muted by
  default (`-Speak` to hear it), and waits for the dev server
- Dev server on `127.0.0.1:8771`: `/health`, `POST /eval` (persistent Lua
  REPL), `/speech?since=N` and `/log?since=N` (monotonic ring buffers),
  `POST /key` (synthesize keypresses), `/gui` (live overlay graph),
  `/screenshot`, `POST /reload` (hot reload from disk)
- `scripts/backup-saves.ps1` / `restore-saves.ps1` before automated runs
- The game's extracted Lua source lives OUTSIDE this repo at
  `../moonring-decomp` (copyrighted; local reference only; never committed)

## Credits

Speech stack and keygraph engine ported from Brad Renshaw's
[Blindfold](https://github.com/bradjrenshaw/Blindfold) (Balatro); gameplay
access design (exploration cursor, wall echo, scanner, announcer family)
follows Tanglebeep (Tangledeep). Prism is by Ethin Probst (MPL-2.0), Lovely
Injector by ethangreen-dev (MIT).
