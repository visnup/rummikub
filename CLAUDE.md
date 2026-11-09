# Rummikub

An iOS app that reads a Rummikub table and your rack from the camera and shows, AR-style, where to place your
tiles. When a play rearranges the table, it shows how many steps it takes and walks through them one at a time,
advancing as the camera sees each step done.

This file describes the project as it is. What was tried and dropped goes in `ARCHIVE.md`, so nobody repeats it.
What's next is in `TODO.md`.

Keep long waits short: training, pre-labeling, scoring and anything else that runs for minutes. When one grows,
make it faster (cache what doesn't change, only redo what's new, run independent steps together, skip work when
there's nothing to do), or say how it could be, with a rough cost and saving.

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
  - `Finder.swift`: finds tiles, not values, with the detector `Labeler/finder.py` makes, through Vision. It runs on
    the whole image and on overlapping crops half its short side, since small tiles are missed whole; a box cut by a
    crop's edge is left to the neighboring crop. It keeps boxes over .6 confidence and drops any that overlap a kept
    one by over a tenth (IoU). On the Simulator the model must run on the CPU, or Vision can't create an inference
    context. On the phone it takes 290–500 ms a frame for the 19 regions of a 1080p frame (2026-11-09).
  - `Overlay.swift`: what to draw for each step of a play over the image: the tile to pick up, its target slot as a
    ghost, and an arrow.
  - `Render.swift`: synthetic table images for tests, and drawing overlays onto images.
  - `scan` reads a photo and writes `<photo>.scan.png` with what it read drawn on.
  - `label` writes each capture's `<capture>.tiles.json`. It holds every tile the reader read that agrees with the
    truth, with its box, its turns and whether it's confirmed. Agreeing with a full set's truth proves little, since
    that truth holds every tile. So in full sets a tile is confirmed only when the tile beside it continues its run
    in its color and one above or below has its value. Elsewhere, agreeing is enough. Files with hand labels are
    left alone.

  - `score` (`make score`) runs the finder and the reader on the held-out done captures, through `Finder`: tiles
    found (a box overlapping a true one by half) and extra boxes, then tiles read right and extra against the
    written truth, with and without the app's filter, and the finder's boxes read by `Values.mlpackage` when it's
    beside the captures. Not against `tiles.json`'s values, which are mostly the reader's own. It takes
    `Captures/Tiles.mlpackage`. On 2026-11-09, with every tile's value and orientation confirmed, the finder
    found 1016 of 1054 held-out tiles with 52 extras, and with `Values` read 1009 of 1072 right with 31 extras.
  - `Classifier.swift` reads the finder's boxes with an image classifier whose classes are tiles at an orientation
    ("k6@2", the quarter turns clockwise that make it upright). `make values` builds `Values`, for tables and racks
    alike: `crops.py` crops confirmed tiles upright, and `Labeler/values.py` trains MobileNetV3 (ImageNet) at 128 px
    with a head for the tile and one for the orientation, on those crops at random orientations, for 5 minutes on
    the Mac's GPU, then converts it with each class p(tile)·p(orientation). It's 6.8 MB, and reads about 1.2 ms a
    tile on the phone (72 in 84 ms). Read at the labeled boxes, it gets about 612 of 628 held-out confirmed tiles and 595 orientations right; it levels off after about 3
    minutes. Orientation matters because our 6 and 9 differ only in the logo under the numeral. The outside sets'
    orientations aren't written down, so they join at the orientation the last `Values` gives them
    (`.crops/outside.turns`), where it's .9 sure, but not their 6s and 9s. `Recognizer.turned` then reads each
    patch of touching tiles at the orientation they agree on, any direction, since a meld seen sideways runs down
    the photo. The feature-print classifiers it replaced are in `ARCHIVE.md`.
    The `values` tool still trains `RackOrTable`: logistic regression over Vision's feature print of each frame.
  - `make scene` trains `RackOrTable` on whole frames labeled in `Captures/scene.txt`: by eye between 30° and 55°,
    else by tilt (two low ones were tables). Tilt alone can't say: racks were shot at 24–48°, tables from 35° up, and
    box shape doesn't separate them either. 21 of 24 held-out frames right, two of the misses judgment calls.

- `Labeler/`: a page for checking boxes by hand, a stdlib server that saves to the same `.tiles.json`, and the
  Python that trains on them.
  - `finder.py` trains the finder: D-FINE small (Apache 2.0) from COCO, one "tile" class at 640 px, on random
    squares of the done captures (listed in `Captures/boxed.txt`) and the outside sets, at random quarter turns. It
    never trains on held-out captures (`Finder.isHeldOut`, a fifth of them by a hash of the name, so finishing more
    never moves one in or out). It runs `MINUTES` (60) on the Mac's GPU, then converts to
    `Captures/Tiles.mlpackage`, swapping out three parts coremltools 9.0 can't convert. `make train` runs it and
    copies the model to `Rummikub/`; `make retrain` runs it beside `make values`, then `score`. In 15 minutes, a
    quarter of our captures took it from 856 found with 169 extras (outside sets alone) to 895 with 67, and all of
    them to 894 with 62; 60 minutes found 950 with 45. 120 minutes did worse, one run each: 966 of 1051 with 47
    against 60 minutes' 988 with 44, and so did 60 minutes with the rate falling along a half cosine: 974 with 50.
    After the first round of Check fixes, that model found 1001 of 1057 with 31, and a fresh 60-minute run on the
    fixed labels 973 with 45. Runs vary by about that much, so the 988 model is likely a lucky draw: compare a
    change over several runs, not one. On 2026-11-09, after the box sizes were fixed, that model found 1016 of 1054
    with 52, and a fresh run 993 with 75; `Values` retrained then read 1006 of 1072 with 35 either way. Nano found 905 with 103 in 60 minutes, small 950, for about a fifth less time.
    `QUARTERS` (0–4) and `SIZE` (`nano`, `small`) are for those comparisons.
  - `make labels` runs `label`, then `prelabel.py`, then serves the page at http://localhost:8765/captures (`/captures/48` is #48; also `labeler`
    in `.claude/launch.json`).
  - `prelabel.py` draws boxes on every capture not yet edited by hand, keeping values already confirmed, so each
    round of fixing boxes leaves less for the next. `--new` only boxes captures with none yet. `make watch` runs it
    every 30 s while capturing, beside `make labels`, which takes the app's pushes. It's the finder, from the
    checkpoint `finder.py` leaves in `Captures/.finder`, read as `Finder` reads, so it improves only as `make train`
    reruns. It replaced OWLv2 with a linear probe, which found 897 of 1013 held-out tiles with 153 extras to its 950
    with 45.
  - In the page, every tile needs a box and nothing else may have one. Click adds an average-sized box, drag draws
    one. Enter marks a capture done. Values are optional. A tile cut off by the photo's edge gets a box too, which
    may run past the edge.
  - http://localhost:8765/values/r6 shows every r6 in the done captures as a grid, each crop turned upright by its
    orientation, so a wrong orientation or value stands out; "Least sure" lists the unconfirmed ones `Values` is least
    sure of. The `fill` tool (`swift run -c release fill ../Captures`) writes what `Values` reads, with its odds,
    into every unconfirmed box; on 2026-11-09 that was 2905.
  - For a full set, a box count other than 106 means a miss or an extra. Drawing the boxes numbered and looking
    row by row finds them faster than the page does: 13 such captures were fixed that way on 2026-11-07.
  - `make check` runs the `check` tool, which writes `Captures/.check.json`: for every done capture, training ones
    too, the boxes the finder misses, the boxes it finds that have none, and confirmed values `Values` reads as another
    tile at least .8 sure. The page lists those captures under Check, fewest first, and
    marks each spot, which `n` zooms to in turn; Enter there records the capture in `Captures/checked.txt`. On 2026-11-08 it flagged 120 of
    174: 470 boxes missed, 456 extra, 57 values. 279 of the misses had a finder box on them (median IoU .44), mostly
    our click-placed boxes sitting loose or off center, which `f` snaps to the finder's. Of the rest, most were real
    tiles at a low angle, and a few weren't tiles at all (keyboard keys, an app icon). After a day of fixes, on
    2026-11-09 it flagged 100: 275 missed, 250 extra and 3 values, though `Values` now learns most training labels,
    so it flags few of theirs. Of the finder's 54 held-out misses that day, 14 were tiles fanned 30–45° in two full
    sets (#48, #62) with boxes off their tiles, 32 small or low-angle tiles (10–45 px, rows sheared or
    overlapping), 3 motion-blurred, 4 large tiles partly covered by another, and 1 cut by the edge.
  - The app pushes each capture to `server.py` (`PUT /api/capture/<file>`, notes before the photo), which keeps one
    already there or in `.removed` and moves "As read" ones to `unlabeled/`. The phone deletes each file once the
    server has it, so Documents holds only what hasn't gone; that's retried on the next capture, launch or return to
    the app (`Sync.swift`). The Mac is `box.localdomain`, which also resolves over the phone's VPN, and the server
    listens on the local network for it. `make captures` still copies by cable.
  - `words` flags captures with readable words, a line of three or more, into `Captures/review.txt` for a look
    before `make upload`; `make watch` runs it. Vision's text recognition, so tile numerals and key legends don't
    count. On the first 101 captures it flagged 8: a Messages thread, this project's own chat on a laptop, a
    business card, game boxes.
  - Outside data goes in `Outside/`, which git ignores, and only under licenses a closed app can ship: CC0, CC BY
    (credited), MIT, Apache. `outside.py` converts [sverrela/rummikub](https://www.kaggle.com/datasets/sverrela/rummikub)
    (Kaggle, CC0; from arXiv 2411.18172, KU Leuven): 382 phone photos of melds, 4,434 tiles boxed with value and
    color, 378 of them jokers. Download it by hand (it needs a Kaggle account), unzip into `Outside/sverrela`, then
    `uv run Labeler/outside.py Outside/sverrela Outside/sverrela-train`; `make train` adds every `Outside/*-train`,
    and `make values` those and every `Outside/*-values`, sets whose tiles aren't all boxed.
    Not christophrus/rummikub, which is GPL-3.0.
  - Roboflow Universe sets, all CC BY 4.0, so credit them: arthurvanmeerbeeck/rummikub-p8akb, jonasbuehler/rummikub-nvypk,
    ofir-grinholtz/rummikub-b8i9s, snips/test2-fkcgr, and konstantin-elenik/rummy, web photos: 73 in `-train`, 8 in
    `-values` with a face-up tile unboxed, mostly printed on a game box. Each was forked into our Roboflow workspace, given a version with auto-orient only (the
    published ones are stretched to 640 and flipped), exported as CreateML JSON into `Outside/roboflow-<name>`, and
    converted by `outside.py`. Many uploads were already rotated, with black corners and boxes that no longer fit,
    and `outside.py` skips those. After converting, photos near-identical to an earlier set's were deleted
    (difference hash within 20 of 256 bits), and ofir's photos whose boxes mostly hold no ink (shifted off their
    tiles) too. Left out: rummikub-3gqr9 and noabiber44/rummikub-joker-tiles (re-uploads of sverrela and
    arthurvanmeerbeeck), ferhatcelik/test (konstantin's), rummikub/rummikub-pvln1 (a suited tile design, numerals
    boxed), bluebox (NC-SA), Okey sets (another game's tiles).

- `Rummikub/`: the iOS app (`Rummikub.xcodeproj`, iOS 27, iPhone). `Camera` streams upright frames about three
  times a second; `Game` decides rack or table (`RackOrTable`), finds the tiles (`Tiles`), reads each box
  and its orientation (`Values`), or falls back to the reader without the models, keeps the table and rack, solves, and
  tracks the step shown; `ContentView`
  draws the step over the camera, each tile read in the last frame labeled with what it was read as, and the table
  and rack as text once two frames agree. The table and rack are each voted over their last five frames (each tile as often as the median frame read it),
  and lock once the vote holds for two seconds: then frames stop changing them and the plays are solved once. A locked
  part that reads differently for three seconds shows "changed?"; its chip in the Solver panel scans it again. While a play is being shown, readings don't re-solve; they advance the step instead
  (`Play.stepsDone`). The simulator never uses a camera: it reads a fixture photo of whichever the Table/Rack switch says
  (`Demo`), straight off the Mac's disk. On the phone, Table/Rack follows `RackOrTable` when it's .8 sure, or
  without it the tilt from CoreMotion (`Game.tilt`), shown in degrees in the top pill and written into each capture.
  A pick by hand holds until that part locks. In the Simulator, Vision requests are pinned to the
  CPU, else it can't create an inference context; the finder's boxes there still come out wrong, so check on the phone.
  - Two tabs. Capture's controls are one row in the tab bar's accessory (`tabViewBottomAccessory`), which the system
    places above the tab bar, or level with it on the iPhone Duo, whose tab bar is at the side; hand-placed panels
    were off on one device or the other. Notes are typed in an alert, since the accessory stays behind the keyboard.
    Solver keeps a two-row panel.
  - Once table and rack are both locked, the Solver shows the Board (`Board.swift`) and the camera stops, to save
    battery: each part drawn as it sat in its frame, with the step shown drawn on it. Tapping a part scans it again.
    Finish on a play's last step takes its melds as the table (`Play.finished`, in the slots the steps put them) and
    re-solves, with no rescan. Models load off the main thread, about 7 s on a cold launch; frames wait for them.
    Once the part in view is locked, frames are read a second apart.
  - A capture is a finger lifted off the camera (pressing hides everything drawn over it, to check the framing) or a
    second tap on the Capture tab. The tab's icon is a checkmark for 1.5 s after, so a burst doesn't make duplicates.
  - The camera is the virtual multi-lens device, so .5× reaches the ultra wide; it starts at the widest, since a whole
    table fits from closer. Captures record the zoom as labeled and the lens.
  - Each frame's read and find times go to `Documents/timing/`, a file a launch, for `make timing`.
  `make` builds it and installs it on the phone (an iPhone named Yam); `make sim`
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
- Captures from the phone: each capture saves three files to the app's Documents, and pushes them to the labeler:
  - `<ISO time>.png`. PNG, so a fixture holds the pixels the phone read; the first seven were JPEG, converted to PNG
    on the Mac.
  - `<ISO time>.txt`: what it was looking at and the tilt, then the truth, one meld per line. The truth is what was
    read, unless the Layout picker names a known layout.
  - `<ISO time>.json`: the layout, notes, gravity, camera settings, read time and every detection's box.

  They land in `Captures/`, which git ignores since they're hundreds of MB. By cable, `make captures` copies them
  one file at a time, since `devicectl device copy from` with `--source Documents` copies nothing, and skips the
  per-frame timing logs, which `make timing` pulls into `Timing/`. Captures whose truth isn't written yet go in
  `Captures/unlabeled/`; both paths move new "As read" ones there. `make upload` sends them to the Hugging Face dataset
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
