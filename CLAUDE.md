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
    around, joined into numbers. Digits are matched against glyphs rendered in a few bold fonts and baked into
    `References.bin`, color comes from the
    ink's hue, and each tile's frame is guessed from its numeral's size. It reads all four quarter turns of the
    image and keeps the closest match wherever readings overlap. Turns other than the frame's usual one lose ties by
    .1 and count only matches closer than .3. The usual turn is voted by digits that look different upside down, so
    not 1, 6, 8, 9 or 11. The tile face color is the peak of a
    saturation/value histogram, since white balance varies too much between photos for fixed thresholds. Vision's
    text recognition skips lone digits, both rendered and photographed, so it isn't used.
  - `Finder.swift`: finds tiles, not values, with the detector `train` makes, through Vision. It runs on the whole
    image and on overlapping crops half its short side, since small tiles are missed whole; a box cut by a crop's
    edge is left to the neighboring crop. It keeps boxes over .9 confidence and drops any that overlap a kept one.
    On the Simulator the model must run on the CPU, or Vision can't create an inference context.
  - `Overlay.swift`: what to draw for each step of a play over the image: the tile to pick up, its target slot as a
    ghost, and an arrow.
  - `Render.swift`: synthetic table images for tests, and drawing overlays onto images.
  - `scan` reads a photo and writes `<photo>.scan.png` with what it read drawn on.
  - `label` writes each capture's `<capture>.tiles.json`. It holds every tile the reader read that agrees with the
    truth, with its box, its turns and whether it's confirmed. Agreeing with a full set's truth proves little, since
    that truth holds every tile. So in full sets a tile is confirmed only when the tile beside it continues its run
    in its color and one above or below has its value. Elsewhere, agreeing is enough. Files with hand labels are
    left alone.

  - `train` (macOS only) trains a Create ML object detector, one "tile" class, on the captures whose boxes are done.
    Done captures are listed in `Captures/boxed.txt`. It writes `Captures/Tiles.mlmodel`. `make train` runs it,
    copies the model to `Rummikub/` and runs `score`. It trains on each
    image and its side-by-side crops, and never on held-out captures (`Finder.isHeldOut`, a fifth of them by a
    hash of the name, so finishing more never moves one in or out). It stops
    after `MINUTES` (60) with its last checkpoint. `QUARTERS` (1–4, default 4) trains on that many quarters of the
    captures, nested, for a learning curve. It waits on the run loop: sleeping the main thread hung a run at 0% CPU.
  - `score` (`make score`) runs the finder and the reader on the held-out done captures, through `Finder`, since
    `MLObjectDetector.prediction`'s boxes are skewed on portrait images: tiles found (a box
    overlapping a true one by half) and extra boxes, then tiles read right and extra against the written truth,
    with and without the app's filter. Not against `tiles.json`'s values, which are mostly the reader's own.

- `Labeler/`: a page for checking boxes by hand, and a stdlib server that saves to the same `.tiles.json`.
  - `make labels` runs `label`, then `prelabel.py`, then serves the page at http://localhost:8765 (also `labeler`
    in `.claude/launch.json`).
  - `prelabel.py` draws boxes on every capture not yet edited by hand, keeping values already confirmed, so each
    round of fixing boxes leaves less for the next. `--new` only boxes captures with none yet, and the probe is
    cached in `Captures/.probe.pt` until the done captures' boxes change. `make watch` runs it every 30 s while
    capturing, beside `make labels`, which takes the app's pushes. A second probe pass learns from the patches the first wrongly calls tiles, but
    keyboard keys still get boxed: the done captures rarely show one. It's OWLv2, frozen, run on the same overlapping crops as
    `Finder`, with a linear probe trained on the done captures' boxes; patches that fit a tile badly are its
    negatives, or they come back as extra boxes. A box mostly inside a likelier one is dropped too: numerals got
    their own small boxes inside their tiles'. On the held-out captures it found 248 of 263 tiles with 14 extras
    at its .8 cutoff, where `train`'s detector found 199 with 110. A text prompt alone found 226 of 230 with 127
    extras, and needed the crops: whole photos shrink to OWL's 960 px. It's too big for the phone.
  - In the page, every tile needs a box and nothing else may have one. Click adds an average-sized box, drag draws
    one. Enter marks a capture done. Values are optional. A tile cut off by the photo's edge gets a box too, which
    may run past the edge.
  - For a full set, a box count other than 106 means a miss or an extra. Drawing the boxes numbered and looking
    row by row finds them faster than the page does: 13 such captures were fixed that way on 2026-11-07.
  - The app pushes each capture to `server.py` (`PUT /api/capture/<file>`, notes before the photo), which keeps one
    already there or in `.removed` and moves "As read" ones to `unlabeled/`. It retries what didn't get through on
    the next capture or launch (`Sync.swift`, `Documents/.sent`); the Mac is `box.localdomain`, which also resolves over the phone's VPN, and the server listens on
    the local network for it. `make captures` still copies by cable.
  - `words` flags captures with readable words, a line of three or more, into `Captures/review.txt` for a look
    before `make upload`; `make watch` runs it. Vision's text recognition, so tile numerals and key legends don't
    count. On the first 101 captures it flagged 8: a Messages thread, this project's own chat on a laptop, a
    business card, game boxes.

- `Rummikub/`: the iOS app (`Rummikub.xcodeproj`, iOS 27, iPhone). `Camera` streams upright frames about three
  times a second; `Game` reads them, drops readings outside every box `Finder` sees (`Tiles.mlmodel`), keeps the table and rack, solves, and tracks the step shown; `ContentView`
  draws the step over the camera, each tile read in the last frame labeled with what it was read as, and the table
  and rack as text once two frames agree. A reading only replaces the last one once two frames in a row agree, so a missed
  tile doesn't re-solve. While a play is being shown, readings don't re-solve; they advance the step instead
  (`Play.stepsDone`). The simulator never uses a camera: it reads a fixture photo of whichever the Table/Rack switch says
  (`Demo`), straight off the Mac's disk. On the phone, Table/Rack follows the tilt from CoreMotion (`Game.tilt`), shown in degrees
  in the top pill and written into each capture.
  - Two tabs. Capture's controls are one row in the tab bar's accessory (`tabViewBottomAccessory`), which the system
    places above the tab bar, or level with it on the iPhone Duo, whose tab bar is at the side; hand-placed panels
    were off on one device or the other. Notes are typed in an alert, since the accessory stays behind the keyboard.
    Solver keeps a two-row panel.
  - A capture is a finger lifted off the camera (pressing hides everything drawn over it, to check the framing) or a
    second tap on the Capture tab. The tab's icon is a checkmark for 1.5 s after, so a burst doesn't make duplicates.
  - The camera is the virtual multi-lens device, so .5× reaches the ultra wide; it starts at the widest, since a whole
    table fits from closer. Captures record the zoom as labeled and the lens.
  - Each frame's read and find times go to `Documents/timing/`, a file a launch, for `make timing`.
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

All in `Pixels` in `Recognizer.swift`. Face: within .1 saturation of the histogram peak and value above peak − .2,
where the peak is the brightest bin at least a quarter as full as the fullest (a gray mat outnumbers the tiles).
Ink: value under .4 or saturation over .3; blurred orange and black ink fall short of tighter cuts. Color: saturated
pixels brighter than .3 vote by hue (red under 5° or over 330°, orange 5–60°, blue 150–270°, which takes in the
green-teal of real tiles); the rest under .4 are black. Real orange ink measures 10–17° and red about 350°.
A numeral needs three quarters of the ring a fifth of its height around it to be face. Digits join when they overlap
vertically by half and sit within .7 of their height, in the same ink color (else an orange 11 takes in the joker
beside it). Our tiles' 6 and 9 have no underline. Stroke width over height: tile digits are .15–.26, joker
faces and keyboard legends under .06, so a numeral under .1 is a joker if its box is square (.8–1.25) and otherwise
not a tile. A number (not a joker, whose features crowd it) needs under 8% ink in the band from a sixth to two
fifths of its height around it: a tile's numeral stands alone, printed text has neighbors. Wider than two fifths
reaches the table between rendered tiles.
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
- Captures from the phone: the app's shutter button saves three files to its Documents:
  - `<ISO time>.png`. PNG, so a fixture holds the pixels the phone read; the first seven were JPEG, converted to PNG
    on the Mac.
  - `<ISO time>.txt`: what it was looking at and the tilt, then the truth, one meld per line. The truth is what was
    read, unless the Layout picker names a known layout.
  - `<ISO time>.json`: the layout, notes, gravity, camera settings, read time and every detection's box.

  `make captures` copies the new ones into `Captures/`, which git ignores since they're hundreds of MB. It copies
  one file at a time, since `devicectl device copy from` with `--source Documents` copies nothing. Captures whose
  truth isn't written yet go in `Captures/unlabeled/`; `make captures` moves new "As read" ones there itself. It
  skips the per-frame timing logs, which `make timing` pulls into `Timing/`. `make upload` sends them to the Hugging Face dataset
  `visnup/rummikub-captures`, private for now and meant to go public. So before uploading, drop any capture that
  shows readable personal text, like messages on a screen; a screen in frame is fine otherwise.
  `Captures/README.md` is the dataset's card. `CAPTURES=$PWD/../Captures swift test --filter readsCaptures`,
  run from `RummikubKit/`, scores the rest without failing.
- Fixtures: captures in `RummikubKit/Tests/RummikubKitTests/Fixtures/`, each `.txt` rewritten with the true melds.
  `readsCaptures` prints each one's misses and extras and fails if the total rises above its count. Raise the bar
  as it drops.
- The reference glyphs are baked into `Sources/RummikubKit/References.bin`, rendered on macOS, because iOS renders
  the same fonts differently: reading the fixtures from fonts at startup, the Simulator made 32 misreads where macOS
  made 19, and its joker fell back to Apple Color Emoji, a filled disc. `bakesReferences` fails when a change to
  recognition or rendering changes them; rebake with `BAKE=1 swift test --filter bakesReferences`. The Simulator
  runs the same tests: `xcodebuild test -scheme RummikubKit-Package -destination 'name=iPhone 18 Pro'` from
  `RummikubKit/`. Fixtures are PNG because iOS and macOS decode JPEG differently (a quarter of the bytes differed,
  by up to 41), which made the Simulator read 22 misreads where macOS read 19.
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
