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

Unchecked kinds, roughly in order of what they unblock. Pick the layout before shooting and type the scene into
notes; the app pushes each one to `Captures/`.

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
- A flat diagram of the finished table for plays that rebuild most of it (see "Design" in `CLAUDE.md`).
- A big table read across a slow pan, not one frame. It needs to know a tile seen in two frames is one tile, by its
  place on the table, since there are two of each. ARKit world tracking would give each detection a fixed point on
  the table plane (a raycast from the camera pose), and keep a play's arrows pinned as the phone moves. It means
  moving the camera from AVCaptureSession to an ARSession, and giving up the ultra wide: on the iPhone 18 Pro (iOS
  27.2), `ARWorldTrackingConfiguration.supportedVideoFormats` lists only the wide camera, 720p to 4K. So a whole
  table takes more panning, which is the point of this anyway. Stitching frames by `Scene.following`'s shift and scale needs
  no ARKit but drifts, and breaks when the angle changes mid-pan.

## Rules not handled yet

- The 30-point initial meld: a player who hasn't melded can only lay rack-only melds worth 30 or more, and can't
  touch the table that turn.
- Scoring: "placed" counts tiles, not their value.
