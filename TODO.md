# TODO

## Next

- **A real game on the phone**: scan the table and rack, let both lock, step through a play and Finish, once without
  AR and once with it, recording. Nothing has tested the whole loop on the 2026-11-12 models, the "Laid down 30"
  switch, or `World.melds` outside a replay.
- **Speed.** A frame took about 150 ms to find and 20–90 ms to read on the phone (2026-11-09). Since then a frame's
  boxes go to Values in one call, and the app skips the squares when the whole frame finds only tiles 80 px or more
  (a fifth fewer regions in `score`). Time both with `make timing`.
- **Phantom boxes** are now the finder's biggest error: 32 on held-out captures against 10 tiles missed
  (2026-11-12). Most are in a few captures: #156 (6), #114 (5), #48 (4), #27 (3). Look at what they sit on; if it's
  something real, like a keyboard or a game box, capture more of it with no tiles.
- **The last misses**: #130 (3), #48 (2, the fanned full set with boxes off their tiles), and one each in #86, #128,
  #160, #206 and #267: stacked or low-angle tiles, what a table looks like mid-turn, so captures of real play.
- **Misreads**: 14 misread and 17 unread of 2210. #263 has 9 of them; #320 and #255 most of the rest.
- **`make check`** flags 92 done captures: 50 boxes missed, 109 extra and 17 values, mostly training captures whose
  labels the models disagree with. Work through "to check first" in the labeler, then retrain.

## Captures

Unchecked kinds, roughly in order of what they unblock. Pick the layout and tag the tile set before shooting; the
app pushes each one to `Captures/`.

- **Real games**: crowded mid-game tables with tiles touching, tiles being moved, the rack in a corner of the frame.
- **Light**: warm overhead, dim evening, a lamp making glare, daylight and lamp mixed; racks too.
- **Surfaces**: a white table, a patterned cloth, and each surface from above with no tiles.

## Labeler on a phone

At 600 px or narrower the capture page already shows the list alone at `/captures` and a capture alone once picked,
with ‹ back. What's left is everything the keys do. Buttons can send the same keydown events the keys do, so nothing
is written twice.

- **A toolbar under the photo.**
  - With a box selected: ✓ confirm (Enter), ↺ ↻ orientation (← →), table or rack (`x`), delete (⌫), snap to the
    finder (`f`), next unconfirmed (Tab).
  - With none: done (Enter), next and previous mark (`n` `N`), previous and next capture (`[` `]`). A swipe on the
    header could do `[` `]` too.
  - About 40 lines.
- **Values by tapping the crop grid.** It's already a 4 × 13 table of values with a joker row: tapping a cell or
  empty slot with a box selected sets that box to that value and confirms it. That replaces typing `r12` Enter.
  Part of the toolbar's 40 lines.
- **Pinch to zoom, one finger to pan**, replacing `+` `−` `0`. A tap selects a box or adds one; drawing a box
  becomes a long press then a drag, since a plain drag now pans. About 40 more lines, and the fiddlier half.
- **Left to the keyboard:** `a`, `u`, `D` and shift-drag selection.

## Solver speed

The integer program solves the benchmark boards in 5–27 ms, and 800 random boards of up to 16 melds average 2–4 ms.
A few take longer. `bench random 800` deals them; on 2026-11-11 its slowest, 15 melds with two jokers and a 14-tile
rack, took 0.32 s. Its first front point took 983 nodes, and it had a whole solution at node 11 and the best at 211:
the rest prove that a 15th tile can't be placed (the relaxation says 15.4). So an early incumbent, by rounding or
otherwise, won't help; only a tighter relaxation will, like cuts.

## App

- Rack steps show only the target while looking at the table, and only the tile to pick up while looking at the
  rack.
- A flat diagram of the finished table for plays that rebuild most of it (see "Design" in `CLAUDE.md`). Comes free
  with step 4 below.
- "Laid down 30" starts on at every launch, so a new game means switching it off by hand. It could be part of a
  "New game" button that also clears the table.

## ARKit throughout

Today a frame is the unit: each one is found, read, voted over the last five, and drawn until the next. With ARKit
the table is the unit: every tile has a place on it, frames add evidence to tiles, and drawing follows the camera at
60 fps between reads. On 2026-11-11 the AR mode measured flat tiles on the table plane to a few mm (28–45 mm sides,
large set), once ARKit had found the table. What it costs: no ultra wide (ARKit offers the wide lens only, so a whole
table takes a pan), and more battery than a stopped camera. The Simulator has no ARKit, so it replays a recording
(`Replay`). Each step ships on its own and keeps the non-AR path working until step 5.

1. **Labels pinned to the table.** Done 2026-11-11 (`Pose.follow`): on the phone it feels much better than labels
   that jump at each read.
2. **Sequences for the Mac.** Built 2026-11-11: AR recordings log every frame read, for `swift run world`, so steps
   3 and 4 can be tuned and tested off the phone. None recorded on the phone yet; the first should be a crowded
   table, to check `World.melds`' bounds.
3. **Rack or table, by geometry.** One frame's footprint doesn't separate them at the angles racks are shot (40–45°:
   rack tiles measured 31×42–50 mm, the same as flat ones; only at 25–33° were they 60–80 deep). Nor, on 2026-11-11,
   did two other single-tile tests beat Values' rack head, which keeps 135 of 140 rack tiles and lets 4 table tiles
   through after `nearest`:
   - *Parallax.* Over 9 frames and 10–20 cm of motion, rack tiles' tops wandered 14–33 mm on the table plane against
     table tiles' 1–11, but the two nearest rack tiles only 7–18.
   - *Taper* (`Standing`, in `ARCHIVE.md`): kept 116 of 135 with 6 let through.
   What's left is *place*: the rack sits at the table's edge nearest the player and doesn't move during a game, and
   its tiles' bottom edges held still on the table plane to 2–9 mm. Once Values has found it, any tile there is rack,
   at any angle. That belongs to step 4's world table, and with it `Looking`, the tilt and the Table/Rack switch can
   go.
4. **A world table.** Started 2026-11-11: `World` replaces the five-frame vote in AR mode once ARKit has the table,
   and tells the rack by Values' mean per place. Not yet tried on the phone. Still to do:
   - Rack by place, not only Values' mean: the rack's line, once found, claims any tile on it. Rack places now
     find their ledge's height (`settle`), which ended #327–331's doubles, but only when the camera moves
     gradually: a jump from 45° to 27° in one frame still doubles a tile, in the test. Once it's by place, AR
     captures' `part` per detection can label Values' rack head in `crops.py`, from every capture, not only those
     marked rack; until then it's Values' own odds averaged, so training on it would learn its own mistakes.
   - Lock per tile, not per part, and don't read again a tile already sure, which saves the reader most of its time.
   - Plays on places: a step's ghost slot a point on the table, `stepsDone` seeing tiles move, `Scene.following`
     gone, and the Board the table from above in table coordinates.
5. **AR as the only camera.** Once 1–4 beat today's on the phone, drop the AVCaptureSession path, the lens buttons,
   `Looking` and the tilt, the five-frame vote and `Game.onRack`, keeping a no-pose path for the Simulator and tests.
   Captures always record the pose.

## Models out of git

Each finder retrain adds about 20 MB to git (fe4ac1e did again), and the pack was 105 MB on 2026-11-11. Move the models to a Hugging
Face model repo beside the captures dataset, `visnup/rummikub-models` (private): `make finder` and `make values`
upload with the `score` line as the message and a tag, `make` and `make sim` `hf download` the revision pinned in the
Makefile into `Rummikub/`, and the packages are gitignored. About 10 lines. The laptop needs `hf auth login` once, and
a fresh clone builds in Xcode only after a `make`. Leave the versions already in history.

## Rules not handled yet

- Scoring: "placed" counts tiles, not their value.
