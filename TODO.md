# TODO

## Next

- **A real game on the phone**: scan the table and rack, let both lock, step through a play and Finish. Nothing has
  tested the whole loop on today's models.
- **The finder's misses.** On 2026-11-09, 38 held-out tiles in scope went unfound:
  - 10 in #206, the new tile set still in its wrap; it needs captures of its own (below).
  - 5 in #48, a fanned full set whose boxes sit off their tiles: fix them in the labeler.
  - 16 stacked, overlapping or partly covered, at low angles (#128, #130, #144) and close up (#158, #160). Those are
    what a table looks like mid-turn, so captures of real play, then several training runs, keeping the best: runs
    vary by about 20 tiles.
- **Speed.** A frame takes about 150 ms to find and 20–90 ms to read on the phone. Time reading again now that a
  frame's boxes go to Values in one call. When the whole frame already finds large tiles, as in a rack close up,
  the three squares could be skipped.

## Captures

Unchecked kinds, roughly in order of what they unblock. Pick the layout and tag the tile set before shooting; the
app pushes each one to `Captures/`.

- **The new tile set** (#206's): out of its wrap, the full set half at a time so tiles are 50 px or more, at a couple
  of angles and orientations; then racks and melds in play.
- **Real games**: crowded mid-game tables with tiles touching, tiles being moved, the rack in a corner of the frame.
- **Light**: warm overhead, dim evening, a lamp making glare, daylight and lamp mixed; racks too.
- **Surfaces**: a white table, a patterned cloth, and each surface from above with no tiles.

## Solver speed

The integer program solves the benchmark boards in 5–27 ms, and 800 random boards of up to 16 melds average 2–4 ms.
A few take longer: the slowest seen, 16 melds with two jokers on the table and a 10-tile rack, took 0.29 s and about
a thousand branch-and-bound nodes, nearly all proving the most "kept" for a front point. Ideas: a rounding
heuristic for an early incumbent, or cuts.

## App

- Rack steps show only the target while looking at the table, and only the tile to pick up while looking at the
  rack.
- A flat diagram of the finished table for plays that rebuild most of it (see "Design" in `CLAUDE.md`). Comes free
  with step 4 below.

## ARKit throughout

Today a frame is the unit: each one is found, read, voted over the last five, and drawn until the next. With ARKit
the table is the unit: every tile has a place on it, frames add evidence to tiles, and drawing follows the camera at
60 fps between reads. On 2026-11-11 the AR mode measured flat tiles on the table plane to a few mm (28–45 mm sides,
large set), once ARKit had found the table. What it costs: no ultra wide (ARKit offers the wide lens only, so a whole
table takes a pan), more battery than a stopped camera, and the Simulator has no ARKit, so `Demo/` photos keep a
path with no pose. Each step ships on its own and keeps the non-AR path working until step 5.

1. **Labels pinned to the table.** Built 2026-11-11 as `Pose.follow`, a box's bottom edge carried from the read
   frame's pose to the camera's now; on the phone it feels much better than labels that jump at each read. As planned: each detection gets a world point: its box's bottom edge cast onto the table plane
   (`Pose.ground`). A flat tile's lies under it; a rack tile's bottom edge sits near the table, so its point is close
   too. The overlay redraws every ARFrame by projecting those points with the current camera, so labels and step
   arrows stay on their tiles between reads, which run at 5 a second or less. About 100 lines: the projection in
   `Pose` (tested on the Mac), a per-frame callback that doesn't run the models, and the overlay drawing from world
   points.
2. **Sequences for the Mac.** Built 2026-11-11: AR recordings log every frame read, for `swift run world`, so steps
   3 and 4 can be tuned and tested off the phone. Not yet recorded on the phone.
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
   - Rack by place, not only Values' mean: the rack's line, once found, claims any tile on it.
   - Lock per tile, not per part, and don't read again a tile already sure, which saves the reader most of its time.
   - Plays on places: a step's ghost slot a point on the table, `stepsDone` seeing tiles move, `Scene.following`
     gone, and the Board the table from above in table coordinates.
   - The melds come from boxes projected from the current pose, where `Recognizer.melds` split #323's r4 from r5 r6.
5. **AR as the only camera.** Once 1–4 beat today's on the phone, drop the AVCaptureSession path, the lens buttons,
   `Looking` and the tilt, keeping a no-pose path for the Simulator and tests. Captures always record the pose.

## Models out of git

Each finder retrain adds about 20 MB to git, and the pack was 105 MB on 2026-11-11. Move the models to a Hugging
Face model repo beside the captures dataset, `visnup/rummikub-models` (private): `make finder` and `make values`
upload with the `score` line as the message and a tag, `make` and `make sim` `hf download` the revision pinned in the
Makefile into `Rummikub/`, and the packages are gitignored. About 10 lines. The laptop needs `hf auth login` once, and
a fresh clone builds in Xcode only after a `make`. Leave the versions already in history.

## Rules not handled yet

- The 30-point initial meld: a player who hasn't melded can only lay rack-only melds worth 30 or more, and can't
  touch the table that turn.
- Scoring: "placed" counts tiles, not their value.
