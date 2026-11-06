# Archive

What was tried and dropped, so nobody repeats it.

## Solver

- **Memoized search over melds by value** (`Search`, replaced 2026-11-06 by the integer program). It settled the
  lowest tile left at each step and kept a Pareto front of placed against a "kept" heuristic per state. States
  recorded which tiles ahead of the cursor runs had already used, about 3^4 per color, so late game it blew up: 835k
  states and 3.9 s for 19 melds with a joker on the table. Its moves were also worse: it steered by the heuristic,
  and the program finds plays with fewer moves on the same boards (13 placed with 1 move where it found 4 or 10).
- **Dense tableau simplex.** The first version kept all of B⁻¹A, 72 × 2,100 doubles. Each pivot touched all of it,
  about 75 µs even through vDSP, and every branch copied 1.2 MB. Keeping B⁻¹ (72 × 72) and A as sparse columns made
  pivots and copies several times cheaper.
- **Branching on the most fractional column alone** took 641 nodes on the late-game board; branching on the placed
  and kept sums first took 31. Branching on the least fractional column took 4 s on the same board. Branching on
  the keep variants before the templates, or on the first fractional column, swung random boards between 20 ms and
  11 s. Exploring the down branch first when the value is under .5 (nearest first) made the slowest random board
  0.23 s against 0.07 s for always up first.
- **Solving placed and kept separately** (max placed, then fix it and max kept): the placed-only objective has so
  many ties that proving it took 70–90 nodes even midgame, against 1–2 for the weighted objective.
- **A node budget** after which the search only looks for more placed, settling for fewer kept: the slow boards spend
  their nodes finding a first whole solution, not proving it, so a budget of 10–100 saved nothing, and the weaker
  front points meant more re-solves.
- **Keep variants from the meld's camera order** (runs extended 1–3 and trimmed 1–2 at each end, positions inferred
  from the first real tile). They missed a group with a joker becoming a run (`k4 o4 j` → `k4 j k6`) and a 6-run
  trimmed by three, so plays came out with more moves than the old search found. Variants are now any run or group
  sharing two tiles with the old meld, within three values of its tiles. Letting runs reach further (four, or
  anything) fixed one more random board in 500 and made the program up to 3.5 times wider and 5 times slower.
