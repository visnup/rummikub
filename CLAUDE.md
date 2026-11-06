# Rummikub

An iOS app that reads a Rummikub table and your rack from the camera and shows, AR-style, where to place your
tiles. When a play rearranges the table, it shows how many steps it takes and walks through them one at a time,
advancing as the camera sees each step done.

This file describes the project as it is. What was tried and dropped goes in `ARCHIVE.md`, so nobody repeats it.
What's next is in `TODO.md`.

## Layout

- `RummikubKit/`: a Swift package with everything that doesn't need a device, so it's tested with `swift test` on
  the Mac. `bench` is a release-build timing tool: `swift run -c release bench "r1 r2 r3, b5 b6 b7" "r4 k9"`.
  - `Tile.swift`: tiles, and `Counts`, a `SIMD64<UInt8>` of how many of each tile, indexed by value then color so
    lower values come first.
  - `Meld.swift`: `isMeld`, and `Template.all`, every distinct valid meld as counts.
  - `Solver.swift`: `solve(table:rack:)` returns the plays worth considering, each with its final melds and steps.
  - `LP.swift`: the linear and integer program solver behind it.
  - `Recognizer.swift`, `Render.swift`: reading tiles from an image, and drawing synthetic table images to test it.

## Tile notation

`k` black, `b` blue, `o` orange, `r` red, then the value: `r5`, `b13`. `j` is a joker. Melds are space-separated,
tables comma-separated: `"r1 r2 r3, k5 b5 o5"`. Real tiles' "blue" is teal or green.

## Solver

Plays are a Pareto front of tiles placed from the rack against table tiles moved. The first is "place nothing" (or
the least you can place without moving anything); the last places the most. Each play's steps say which tile goes
from where (`.rack(i)` or `.table(meld:index:)`) to which new meld; a new meld's `anchor` is the old meld it stays in
place of, or nil for one laid down somewhere new.

The melds come from an integer program (Den Hertog and Hulshof 2006, as in mjpieters' `rummikub-solver`): how many
of each candidate meld to lay out so every table tile and any rack tiles are used. Candidates are `Template.all`,
plus each old meld's keep variants (`keeps`): runs and groups sharing at least two tiles with it, reaching up to
three values past its tiles, with jokers standing in for missing ones. A variant credits the old meld's tiles it
shares as kept, and each old meld keeps at most one. The objective is placed × (table tiles + 1) + kept. Each front
point after the first requires kept above the last one's, re-solving from the previous basis.

`LP.swift` is the solver: a revised dual simplex with bounded variables (dense B⁻¹, sparse A), and depth-first branch
and bound that branches on the placed and kept sums first, then the most fractional candidate, up first. All bounds
are finite, so every basis is dual feasible and a bound change warm-starts.

Moves are counted in `plan`: old and new melds pair up greedily by overlap, and a table tile that ends up in a meld
other than its old meld's partner has moved. "Kept" only steers toward the same thing, so `solve` re-filters the
front by real moves.
