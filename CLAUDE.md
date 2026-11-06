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
  - `Recognizer.swift`: reading tiles from an image. It finds numerals, not tiles: blobs of ink with tile face all
    around, joined into numbers. Digits are matched against glyphs rendered in a few bold fonts, color comes from the
    ink's hue, and each tile's frame is guessed from its numeral's size. The tile face color is the peak of a
    saturation/value histogram, since white balance varies too much between photos for fixed thresholds. Vision's
    text recognition skips lone digits, both rendered and photographed, so it isn't used.
  - `Overlay.swift`: what to draw for each step of a play over the image: the tile to pick up, its target slot as a
    ghost, and an arrow.
  - `Render.swift`: synthetic table images for tests, and drawing overlays onto images.
  - `scan` reads a photo and writes `<photo>.scan.png` with what it read drawn on.

- `Rummikub/`: the iOS app (`Rummikub.xcodeproj`, iOS 27, iPhone). `Camera` streams upright frames about three
  times a second; `Game` reads them, keeps the table and rack, solves, and tracks the step shown; `ContentView`
  draws the step over the camera. A reading only replaces the last one once two frames in a row agree, so a missed
  tile doesn't re-solve. While a play is being shown, readings don't re-solve; they advance the step instead
  (`Play.stepsDone`). The simulator never uses a camera: it reads a rendered table and rack (`Demo`) once a second.
  `make` builds it and installs and launches it on the phone (an iPhone named Yam); `make sim`
  builds the Simulator's; `make test` runs the package's tests.
- `RummikubKit` builds with `-O` even in debug, since recognition's pixel loops take seconds a frame unoptimized.

## Design

What the app is for, as the user put it: pan the camera over the table and your own rack, it keeps the state current
whenever the camera's open again, and it shows where to place your tiles. The open question was how to show large
rearrangements. What we settled on:

- Disruption is part of the solver's objective, not an afterthought: among plays that place as many tiles, prefer
  the one that moves the fewest table tiles.
- Offer the trade-off, not one answer: "Place 3, move 0" … "Place 7, move 4". Turns are often timed.
- A play is a numbered list of steps ("Step 2 of 5"), shown one at a time over the camera: the tile to pick up, an
  arrow, and a ghost where it goes. The camera advances them as it sees each done, and can catch a wrong move.
- Not built yet: for a rebuild of most of the table, a flat diagram of the finished table, each meld marked kept,
  changed or new, may beat step-by-step AR.

## Recognition thresholds

All in `Pixels` in `Recognizer.swift`. Face: within .1 saturation of the histogram peak and value above peak − .2.
Ink: value under .35 or saturation over .5. Color: saturated pixels brighter than .3 vote by hue (red under 15° or
over 330°, orange 15–60°, blue 150–270°, which takes in the green-teal of real tiles); the rest under .35 are black.
A numeral needs three quarters of the ring a fifth of its height around it to be face. Digits join when they overlap
vertically by half and sit within .7 of their height; a flat blob under a digit is a 6 or 9's underline.
`ARCHIVE.md` has what loosening each of these broke.

## Testing

- `make test` runs everything in the package; recognition tests run in milliseconds because the package always
  builds with `-O`. `RENDER_DIR=<dir> swift test` also writes the rendered tables and step overlays there as PNGs.
- `swift run -c release scan photo.jpg` prints the melds it reads and writes `photo.scan.png` with them drawn on.
- `swift run -c release bench "<table>" "<rack>"` times one solve. The benchmark boards are in `SolverTests`
  (`midgame`, `lateGame`).
- Real photos: the two samples from rummikubsolver.com (a top-down board on wood, and a rack at a low angle) are not
  in the repo, since the site has no license; download them again from its sample images if needed. Their results
  are in `TODO.md`.
- Captures from the phone: the app's shutter button saves `<ISO time>.jpg` and `<ISO time>.txt` (what it was looking
  at, then the melds it read, one per line) to its Documents. Copy them off with
  `xcrun devicectl device copy from --device Yam --domain-type appDataContainer --domain-identifier
  com.visnup.Rummikub --source Documents --destination <dir>`. The plan is to keep them as fixtures with the right
  reading written down, under `RummikubKit/Tests/RummikubKitTests/Fixtures/`.
- At a real table, the recognizer does best with a plain dark surface, even light, tiles face up and upright in rows
  with gaps between melds, and the camera close to top-down from 30–50 cm. Light wood grain is its main source of
  false reads, and shaded tile edges its main source of misses.

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
