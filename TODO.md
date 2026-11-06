# TODO

## Solver speed

The integer program solves the benchmark boards in 5–27 ms, and 800 random boards of up to 16 melds average 2–4 ms.
A few take longer: the slowest seen, 16 melds with two jokers on the table and a 10-tile rack, took 0.29 s and about
a thousand branch-and-bound nodes, nearly all proving the most "kept" for a front point. Ideas: a rounding
heuristic for an early incumbent, or cuts.

## App

- Rack steps show only the target while looking at the table, and only the tile to pick up while looking at the
  rack.
- The Table/Rack switch is manual. A rack is close, upright and at the bottom of the frame, which may be enough to
  tell automatically.
- New melds go in a row under the table, which may be off screen or on top of the rack.

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

Next:
- Our own photos, under a few kinds of light, kept as test fixtures. Thresholds tuned on two photos are overfit.
- A learned detector (Create ML object detection) if heuristics keep trading one photo for another.
- Tiles upside down or sideways, as from across the table. 6 and 9 have underlines in some editions, not others.
- Frames are guessed from the numeral's size, so overlapping tiles on a rack can misplace them.
