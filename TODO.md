# TODO

## Solver speed

The memoized search (`Search` in `Solver.swift`) is fast midgame and slow late. Release build on an M-series Mac,
measured 2026-11-06:

| board | states | time |
| --- | --- | --- |
| 12 melds, 45 tiles, 13-tile rack | 17k | 70 ms |
| same, plus a joker in the rack | 70k | 250 ms |
| 19 melds, 65 tiles, joker on the table | 835k | 3.9 s |

Its states record which tiles ahead of the cursor runs have already used, about 3^4 per color. A DP by value only
needs each color's run lengths so far (0, 1, 2, 3+), about 10. Next: an ILP over the templates, the formulation
`rummikub-solver` (mjpieters, MIT) uses and solves in 3–15 ms with HiGHS or GLPK. "Kept" becomes variables for each
old meld kept as-is, extended or trimmed at its ends.

## App

Not yet run on a device; only the simulator's rendered demo.

- Rack steps can't point at the rack while looking at the table, so they only show the target. Looking at the rack
  could highlight the tile to pick up instead.
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
