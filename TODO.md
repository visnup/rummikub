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

## Rules not handled yet

- The 30-point initial meld: a player who hasn't melded can only lay rack-only melds worth 30 or more, and can't
  touch the table that turn.
- Scoring: "placed" counts tiles, not their value.

## Recognition

- Real photos: rummikubsolver.com's two sample photos (not in the repo, no license) show a wood floor, slightly
  rotated tiles, red smiley jokers, and a rack shot at a low angle.
- 6 and 9 have underlines; rotated tiles need them.
