# TODO

## Now

Twelve captures from 2026-11-06 are fixtures, one of each burst (a 7-tile rack with a TV behind it, the table
top-down, the rack from the front and from far, the table from across it, and printed cards with no tiles), with
68 misreads. What's left:

- From across the table (160936) every tile is upside down: 16 of the 68. Nothing rotates glyphs yet.
- Printed text (162408, no tiles): 7 false reads, 3 of them jokers, which skip the crowding check.
- Small, distant digits (160551, 160632, numerals 20–35 px tall): 7 reads as 1, 2 as 7, 6 as 8, black 1 as blue,
  and the rack tray reads as k1s.
- 5 reads as 6, black and red, top-down (distance .118 to a 6 against .126 to a 5); the black 11 as 8, and the
  orange 11 as o8 in 155603.
- Tiles turned 15–20° (155924): b10 reads as b4, o11 as o9, k11 as k4 and k6. Glyphs aren't deskewed.
- Washed-out black ink in glare (155856): the rack's k1 and k10 read together as one k11, hypothesis untested.
- The TV capture is out of focus: the black 1's stem is v .55–.7, so it's missed, and a subtitle reads as k9.
- Table/Rack follows the phone's tilt (table over 50° down, rack under 35°), guessed, not calibrated. Captures now
  record the tilt on their first line; set the cutoffs from them.

## Plan: fast, accurate AR

Hand-tuned thresholds have topped out: each change trades one photo for another (`ARCHIVE.md`), and finding a tile
around a numeral by its face doesn't work. In order:

1. **Measure on the phone.** Recognition takes 80–140 ms a frame on the Mac at 1080×1920; the phone's time is
   unknown. Log it per frame with signposts and show the frame rate, so every later step has a number.
2. **A learned tile detector** (Create ML object detection, run through Vision on the Neural Engine, ~10 ms). It finds
   tiles, not numerals, so keyboards, subtitles and the rack tray stop counting, and it gives each tile's box and
   angle for deskewing. Training data: the fixtures with boxes (the recognizer's frames, corrected by hand), plus
   synthetic scenes from real tile crops pasted onto other photos at random angles, scales and lighting, which
   Render can generate by the thousand.
3. **Read each tile crop, deskewed and scaled to one size.** Glyph matching on a clean, upright, fixed-size crop
   should fix tilted and small tiles; if not, a small Core ML classifier over the 53 tiles, trained on the same
   crops. Color by hue stays: it's right on every fixture now.
4. **ARKit instead of AVCaptureSession.** Plane detection finds the table; each tile's box is raycast onto it, so
   tiles get world positions. That replaces the tilt guess (on the plane is table, upright above it is rack), keeps
   overlays locked to tiles at 60 fps between readings, and lets the table be panned and remembered.
5. **Vote across frames.** Each world position keeps a tally of what it was read as; a tile counts once it wins
   several frames, so one bad frame never re-solves. Show settled and unsettled tiles differently.
6. **Speed last:** read ARKit's YCbCr buffer directly instead of converting to a CGImage, run only when the camera
   has moved or a tile is unsettled, and read only the crops the detector found.

The fixtures stay the yardstick: score detection (precision, recall) and reading separately once there's a detector,
on the Mac and in the Simulator.

## Solver speed

The integer program solves the benchmark boards in 5–27 ms, and 800 random boards of up to 16 melds average 2–4 ms.
A few take longer: the slowest seen, 16 melds with two jokers on the table and a 10-tile rack, took 0.29 s and about
a thousand branch-and-bound nodes, nearly all proving the most "kept" for a front point. Ideas: a rounding
heuristic for an early incumbent, or cuts.

## App

- Rack steps show only the target while looking at the table, and only the tile to pick up while looking at the
  rack.
- New melds go in a row under the table, which may be off screen or on top of the rack.
- A flat diagram of the finished table for plays that rebuild most of it (see "Design" in `CLAUDE.md`).

## Rules not handled yet

- The 30-point initial meld: a player who hasn't melded can only lay rack-only melds worth 30 or more, and can't
  touch the table that turn.
- Scoring: "placed" counts tiles, not their value.

## Recognition

Checked against rummikubsolver.com's two sample photos (not in the repo: the site has no license), with
`swift run -c release scan photo.jpg`, 2026-11-06:

- Top-down board on a wood floor, 2460×1908: all 22 tiles right, jokers included, in 115 ms.
- Rack at a low angle, 2016×1512: 12 of 13. The green 7 is missed: the left of its tile is shaded too far below the
  face color for `onTile`. Loosening that margin lets wood grain through on the board photo.

Not rerun since the thresholds changed for the fixtures (see "Now"); download them again to check.

Next (see "Plan" above for the order):
- Tiles sideways, as from the side of the table.
- Frames are guessed from the numeral's size, so overlapping tiles on a rack can misplace them.
