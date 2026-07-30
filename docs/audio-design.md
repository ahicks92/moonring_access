# MoonringAccess audio grammar

The mod's non-speech audio follows four rules, learned through play-tuning
with Austin (2026-07-29). They apply to every cue; new cues must fit them.

## The four rules

1. **Pan means world east/west, always.** A left-panned sound concerns
   something west of the player, right-panned east — never "left of my
   heading". Heading-relative panning was tried and rejected: it made
   east/west-panned tones mean north/south walls while traveling east/west.

2. **Register means north/south.** Centered-high = north, centered-low =
   south. Applies to wall pings (rising vs falling pair) and width chirps
   (x2 vs x0.7 transposition). South is "low and UNHURRIED", not deeply low:
   short tones below ~250 Hz have too few cycles to read as pitch (195 Hz at
   50 ms is under ten cycles = a click). South compensates depth with ~1.8x
   duration and a level boost (the Tanglebeep low-end-hole lesson).

3. **Contour draws the line the space extends along.** Rise = wider
   everywhere EXCEPT south, where widening falls away downward and a south
   wall closing rises toward you (Austin: "it draws a line").

4. **Salience marks the event, timbre marks the system.** Narrowing is
   always the loud, urgent shape; widening the gentle one — decodable before
   the direction is. Walls speak band-passed NOISE; width/cursor/step cues
   speak TONES.

## The cues

- **Forward wall ping** (on each step, movement direction only): west =
  single noise ping hard left; east = hard right; north = rising noise pair
  (base then a fifth up), centered; south = falling pair, centered. Distance
  = onset delay (35 ms/tile past adjacent) + gain (-3 dB/tile). Broadside
  four-direction pinging every step was rejected as wrong for a corridor
  game (Shades-of-Doom lineage informs the movement-relative design).

- **Flank width chirps**: fire when a flank's clearance to the first blocked
  tile changes between consecutive same-flank-axis steps. History is keyed
  by flank axis + world direction, so 180-degree turns keep comparing and
  only 90-degree turns re-baseline (silently). Out-of-range counts as
  MAX_DIST+1 so walls entering/leaving range register.

- **Step cues** (Ctrl+F): terrain family on every player move — wood knock,
  soft rustle, stone tick, water double-blip, sand hiss. These restore the
  terrain-differentiated footsteps the game designed and abandoned (its
  puddle pitch-shift is commented out at actor.lua:6281).

- **Cursor cues**: ground tick 880 Hz, blocked thud 220 Hz, entity adds a
  1318 Hz ping, unexplored 110 Hz pulse, scanner page-blip 660 Hz. A sound
  ALWAYS plays on a cursor step even when differential speech is silent.

## Synthesis notes (ma_synth.lua)

Faithful port of Tanglebeep's Core/Audio pipeline. Non-negotiables:

- **Decorrelation**: left/right wall pings draw successive slices from a
  shared pre-filtered noise pool. Identical noise in both ears fuses to
  phantom center regardless of pan (this bug shipped once; never again).
- **RMS normalization** (target 0.3) after band-passing, so Q changes
  timbre, not loudness. A Q=30 bandpass passes ~9 Hz of white-noise energy;
  unnormalized pings sit ~25 dB under everything.
- **ITD**: far ear delayed |pan| * 0.7 ms (tunable), integer shift + first-
  order allpass fractional delay, ringout flushed.
- Wall-echo constants are runtime-tunable (Ctrl+W menu) and persist to
  moonring_access_tuning.lua in the save dir; tuned values should
  periodically be folded back into the WALL defaults.
