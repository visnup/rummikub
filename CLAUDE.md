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
  - `Recognizer.swift`: reading tiles from an image. It finds numerals, not tiles: blobs of ink with tile face all
    around, joined into numbers. Digits are matched against glyphs rendered in a few bold fonts, color comes from the
    ink's hue, and each tile's frame is guessed from its numeral's size. The tile face color is the peak of a
    saturation/value histogram, since white balance varies too much between photos for fixed thresholds. Vision's
    text recognition skips lone digits, both rendered and photographed, so it isn't used.
  - `Overlay.swift`: what to draw for each step of a play over the image: the tile to pick up, its target slot as a
    ghost, and an arrow.
  - `Render.swift`: synthetic table images for tests, and drawing overlays onto images.
  - `scan` reads a photo and writes `<photo>.scan.png` with what it read drawn on.

## Tile notation

`k` black, `b` blue, `o` orange, `r` red, then the value: `r5`, `b13`. `j` is a joker. Melds are space-separated,
tables comma-separated: `"r1 r2 r3, k5 b5 o5"`. Real tiles' "blue" is teal or green.

## Solver

Plays are a Pareto front of tiles placed from the rack against table tiles moved. The first is "place nothing" (or
the least you can place without moving anything); the last places the most. Each play's steps say which tile goes
from where (`.rack(i)` or `.table(meld:index:)`) to which new meld; a new meld's `anchor` is the old meld it stays in
place of, or nil for one laid down somewhere new.

Moves are counted in `plan`: old and new melds pair up greedily by overlap, and a table tile that ends up in a meld
other than its old meld's partner has moved. The search only steers by a heuristic of the same thing.
