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
  - `Recognizer.swift`: `Detection`, a tile read in a box, and `melds`, which groups tiles side by side into melds.
    `Valid.swift` adds the orientation vote and the valid-meld pass.
  - `Finder.swift`: finds tiles, not values, with the detector `Labeler/finder.py` makes, through Vision. It runs on
    the whole image and on squares its short side, three down a 1080p frame, overlapping by about half; a box cut by
    a crop's edge is left to the neighboring crop. It keeps boxes over .6 confidence and drops any that overlap a kept
    one by over .3 (IoU): angled tiles' axis-aligned boxes overlap their neighbors by up to .25 (453 of 9916 labeled
    boxes over .1), and on 2026-11-10 .3 found 1308 of 1324 held-out tiles with 23 extra, against .1's 1301 with 22
    and .5's 1308 with 37. On the Simulator the model must run on the CPU, or Vision can't create an inference
    context. With crops half the short side, 19 regions, it took 290–500 ms a frame on the phone (2026-11-09).
    Tiles under 30 px on their short side in a 1920 px frame (`Finder.smallest`) are out of scope for `score` and
    `check`: the far end of a table, which a table panned with ARKit won't need. The app doesn't apply it. The table
    behind a rack is nearer (37–55 px in #280), and the app leaves that out by `Finder.nearest` instead. Of 1054
    held-out tiles 960 are in scope.
    There the 4 regions found 932 with 14 extras, the 19 found 937 with 16, and the whole image alone 908 with 12.
    The app sets `enough` to 80: when every box the whole image finds is 80 px or more, it skips the squares. On
    2026-11-12 that read a fifth fewer regions (202 of 256) for one tile of 2220 lost; 60 lost five.
  - `Overlay.swift`: what to draw for each step of a play over the image: the tile to pick up, its target slot as a
    ghost, and an arrow.
  - `World.swift`: the table as places, with ARKit: each read joins the place within half a tile of where its box's
    bottom edge meets the table (¾ for the same tile), or starts one, and each place votes on its own tile. A place
    the finder should have seen three frames running and didn't is dropped, unless a person (ARKit's segmentation,
    `World.Mask`) or another box covers it. On the rack by Values' mean (.75). A rack tile's foot stands on a ledge
    above the table, so where it meets the table moves as the camera does; each rack place keeps every sighting's
    ray and finds the height where they meet (`settle`), 25–67 mm in #327–331, and matches new reads at that height.
    Without it, coming back to the rack from the table doubled 5 of its 12 tiles. `World.melds` joins the table's places
    into melds on the table, not in the image: neighbors under 1.1 box widths apart along both tiles' reading
    direction, within 37°, so a meld at an angle stays whole and a tile just behind another stays apart. Both bounds
    are fit to #319–326's one table, where melds measured .7–.83 widths and 26° at most, and other neighbors 1.2 and
    58° at least. `swift run world <start>.jsonl …` replays a recording's log through it, or a 2026-11-11 capture's
    `ar.history`: on #319–326 it read the rack's 7 tiles every time, and the table exactly in all four that saw it
    whole (#319, #323, #325, #326). ARKit doesn't always find the tabletop: over dark felt (#327–331) it found only
    the floor, 0.97 m down, and called it a table. So `World.level` lifts the plane, kept level, to where the tiles
    Values says lie on the table measure 36 mm along their bottom edge (35–37 in #325 and #326), the running median
    over 30 frames, only when they measure over 1.5 times that: always lifting pinned the AR labels to a plane below
    the table, and they swam as the camera moved. That read #327–331's table and rack exactly; #319–326 read as
    before.
  - `Render.swift`: table images and where their tiles lie, for tests, and drawing overlays onto images.
  - `score` (`make score`) runs the finder on the held-out done captures, through `Finder`: tiles found (a box
    overlapping a true one by half), then those boxes read by `Values.mlpackage` when it's beside the captures, as
    the app reads them. It takes `Captures/Tiles.mlpackage`, and counts each error by name: a tile **missed**, a
    **phantom** box on no tile (`PHANTOMS=1` lists them; a box out of scope or on a tile out of scope isn't one, as in
    `check`), a **duplicate** box on a tile already found; of the confirmed tiles found, read
    **correctly**, **misread** as another value, or **unread** (Values not sure enough); and a **phantom read** on a phantom or duplicate box. Reads are scored against the
    confirmed boxes, not the written truth, which was short on "As read" captures and listed the table behind racks.
    Later on 2026-11-12, after more Check fixes: 2289 tiles, 9 missed, 27 phantom, 0 duplicate; of 2277 confirmed,
    2234 read correctly, 14 misread, 20 unread, 12 phantom reads. Then, with 2309 tiles and phantoms scoped as
    `check` scopes them, 11 missed and 19 phantom where the old count said 28: #156's six were loose boxes on far
    tiles. #114's are two empty rack slots and a thing on the stove. Each value's confirmed tiles missed, misread (and as
    what) and unread go to `Captures/.score.json` for the values page, unless `TILES` or `BOXES` names another
    model. For rack captures with boxes marked background (`x` in the labeler),
    it also counts the rack's tiles `Finder.nearest` keeps and the background ones it lets through.
  - `Classifier.swift` reads the finder's boxes with an image classifier whose classes are tiles at an orientation
    ("k6@2", the quarter turns clockwise that make it upright). `make values` builds `Values`, for tables and racks
    alike: `crops.py` crops confirmed tiles upright, and `Labeler/values.py` trains MobileNetV3 (ImageNet) at 128 px
    with a head for the tile and one for the orientation, on those crops at random orientations, for 5 minutes on
    the Mac's GPU, then converts it with each class p(tile)·p(orientation). It's 6.8 MB, and reads about 1.2 ms a
    tile on the phone (72 in 84 ms). Read at the labeled boxes, it got 2261 of 2308 held-out confirmed tiles and their orientations right on 2026-11-12; it levels off after about 3
    minutes. Orientation matters because our 6 and 9 differ only in the logo under the numeral. The outside sets'
    orientations aren't written down, so they join at the orientation the last `Values` gives them
    (`.crops/outside.turns`), where it's .9 sure, but not their 6s and 9s. `Recognizer.turned` then reads each
    patch of touching tiles at the orientation they agree on, any direction, since a meld seen sideways runs down
    the photo. The feature-print classifiers it replaced are in `ARCHIVE.md`.
    The `looking` tool trains `Looking`: logistic regression over Vision's feature print of each frame.
  - `make looking` trains `Looking` on whole frames labeled in `Captures/looking.txt`: by eye between 30° and 55°,
    else by tilt (two low ones were tables). Tilt alone can't say: racks were shot at 24–48°, tables from 35° up, and
    box shape doesn't separate them either. 21 of 24 held-out frames right, two of the misses judgment calls.

- `Labeler/`: pages for checking boxes and values by hand, served by Vite with `server.js` saving them to each
  `.tiles.json`, and the Python that trains on them. `held.py` is `Finder.isHeldOut` for the Python.
  - `finder.py` trains the finder: D-FINE small (Apache 2.0) from COCO, one "tile" class at 640 px, on random
    squares of the done captures (listed in `Captures/boxed.txt`) and the outside sets, at random quarter turns. It
    never trains on held-out captures (`Finder.isHeldOut`, a fifth of them by a hash of the name, so finishing more
    never moves one in or out). It runs `MINUTES` (60) on the Mac's GPU, then converts to
    `Captures/Tiles-new.mlpackage`, swapping out three parts coremltools 9.0 can't convert. `make finder` runs it
    and scores it beside the kept `Tiles.mlpackage`, which the app, prelabeling, `check` and `score` go on using
    until `make keep-finder` swaps it in and copies it to `Rummikub/`, since most runs don't beat the last; `make
    train` runs it beside `make values`, then `score`. In 15 minutes, a
    quarter of our captures took it from 856 found with 169 extras (outside sets alone) to 895 with 67, and all of
    them to 894 with 62; 60 minutes found 950 with 45. 120 minutes did worse, one run each: 966 of 1051 with 47
    against 60 minutes' 988 with 44, and so did 60 minutes with the rate falling along a half cosine: 974 with 50.
    After the first round of Check fixes, that model found 1001 of 1057 with 31, and a fresh 60-minute run on the
    fixed labels 973 with 45. Runs vary by about that much, so the 988 model is likely a lucky draw: compare a
    change over several runs, not one. On 2026-11-09, after the box sizes were fixed, that model found 1016 of 1054
    with 52, and a fresh run 993 with 75; `Values` retrained then read 1006 of 1072 with 35 either way. Nano found
    905 with 103 in 60 minutes, small 950, for about a fifth less time. `QUARTERS` (0–4) and `SIZE` (`nano`,
    `small`) are for those comparisons, and `SNAPSHOTS` (`"15 30"`) saves checkpoints along one run for a curve over
    run lengths, since the rate is constant. On 2026-11-10, with 1988 held-out tiles, a fresh run found 1964 with 36
    against the earlier best's 1969 with 23; it was kept. On 2026-11-11, with 2058, a fresh run missed 9 with 38
    extras against its 24 with 35, and replaced it; nano, YOLO26s and OWLv2 were rerun too (`ARCHIVE.md`). On
    2026-11-12, with 2220, three runs missed 19, 10 and 16 with 20, 32 and 27 extras, against its 11 with 42; the
    second replaced it. The retrained `Values` misread 14 where the last one misread 29. Later that day, with 2289, a
    fresh run missed 22 with 23 extras against its 9 with 27, and was dropped; `Values` retrained misread 14 against
    the last one's 18, and was kept.
  - `make labels` runs `prelabel.py`, then `fill`, then serves the pages on Vite's dev server at
    http://localhost:8765/captures
    (`/captures/48` is #48; also `labeler` in `.claude/launch.json`). Over the VPN bytes matter most, so photos go
    out as WebP (q90, about 290 kB against the PNG's 2.6 MB), made once into `Captures/.web/`, the next capture's
    is fetched ahead, and JSON is brotli-compressed (`/api/values` 2.6 MB to 426 kB).
  - `prelabel.py` draws boxes on every capture not yet edited by hand, keeping values already confirmed, so each
    round of fixing boxes leaves less for the next. `--new` only boxes captures with none yet. `make watch` runs it
    every 30 s while capturing, beside `make labels`, which takes the app's pushes. It's the finder, from the
    kept finder's checkpoint, `Captures/.finder`, read as `Finder` reads, so it improves only as `make keep-finder`
    takes a better one. On 2026-11-12 it's the run that missed 22, since the 9's checkpoint wasn't kept. It replaced OWLv2 with a linear probe, which found 897 of 1013 held-out tiles with 153 extras to its 950
    with 45.
  - On the capture page, every tile needs a box and nothing else may have one. Click adds an average-sized box, drag draws
    one. Enter marks a capture done. Values are optional. A tile cut off by the photo's edge gets a box too, which
    may run past the edge. Its layout picker rewrites the truth: Full set and No tiles write theirs, and As read
    clears it, to be written by hand. Tab follows the grid, a line at a time along most boxes' orientation. Beside
    the photo, every box is cropped upright, a row per color and a column per value: a dashed slot is a tile in the
    truth no box reads as, and a red bar a box past the truth's count.
  - http://localhost:8765/values/r6 shows every r6 in the captures, done or not, as a grid, each crop turned upright by its
    orientation, so a wrong orientation or value stands out; "Least sure" lists the unconfirmed ones `Values` is least
    sure of. Its list gives each value's boxes and, from `make score`, its held-out tiles missed, misread and unread. The `fill` tool (`swift run -c release fill ../Captures`) writes what `Values` reads, with its odds,
    into every unconfirmed box; on 2026-11-09 that was 2905. `make watch` runs `fill --new` after `prelabel.py`, so
    a new capture's boxes arrive with values too. In a rack capture, a box it fills first is marked background where
    Values' rack odds are under .5. On 2026-11-12 that matched 1313 of 1317 hand-marked boxes, mostly ones it trained
    on; held out, it read 120 of 136 rack tiles as rack.
  - For a full set, a box count other than 106 means a miss or an extra. Drawing the boxes numbered and looking
    row by row finds them faster than the page does: 13 such captures were fixed that way on 2026-11-07.
  - `make check` runs the `check` tool, which writes `Captures/.check.json`: for every done capture, training ones
    too, the boxes the finder misses, the boxes it finds that have none, and confirmed values `Values` reads as another
    tile at least .8 sure. It takes 22 s for 194 captures, four at a time; one at a time took 31 s. `make train` reruns it, and `make watch` runs `check --new`
    on captures newly done (those not in `.check.done`). Clicking the boxes header steps to "to check first", which lists those captures fewest first (the
    other headers sort by their column), and
    marks each spot, which `n` zooms to in turn; Enter there records the capture in `Captures/checked.txt`. On 2026-11-08 it flagged 120 of
    174: 470 boxes missed, 456 extra, 57 values. 279 of the misses had a finder box on them (median IoU .44), mostly
    our click-placed boxes sitting loose or off center, which `f` snaps to the finder's. Of the rest, most were real
    tiles at a low angle, and a few weren't tiles at all (keyboard keys, an app icon). After a day of fixes, on
    2026-11-09 it flagged 100: 275 missed, 250 extra and 3 values, though `Values` now learns most training labels,
    so it flags few of theirs. Of the finder's 54 held-out misses that day, 14 were tiles fanned 30–45° in two full
    sets (#48, #62) with boxes off their tiles, 32 small or low-angle tiles (10–45 px, rows sheared or
    overlapping), 3 motion-blurred, 4 large tiles partly covered by another, and 1 cut by the edge.
  - The app pushes each capture to `server.js` (`PUT /api/capture/<file>`, notes before the photo), which keeps one
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
    `uv run Labeler/outside.py Outside/sverrela Outside/sverrela-train`; `make finder` adds every `Outside/*-train`,
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

- `Rummikub/`: the iOS app (`Rummikub.xcodeproj`, iOS 27, iPhone). `Camera` streams upright frames at most five
  times a second, fewer when a frame takes longer to read; `Game` decides rack or table (`Looking`), finds the tiles (`Tiles`; at the rack, only those at least .4 as tall as the tallest,
  `Finder.nearest`, to leave out the table behind it), reads each box
  and its orientation (`Values`), keeps the table and rack, solves, and
  tracks the step shown; `ContentView`
  draws the step over the camera, each tile read in the last frame labeled with what it was read as, and the table
  and rack as text once two frames agree. The table and rack are each voted over their last five frames (each tile as often as the median frame read it),
  and lock once the vote holds for two seconds: then frames stop changing them and the plays are solved once. A locked
  part that reads differently for three seconds shows "changed?"; its chip in the Solver panel scans it again. While a play is being shown, readings don't re-solve; they advance the step instead
  (`Play.stepsDone`). The simulator never uses a camera: it reads a photo in `Demo/` of whichever the Table/Rack switch
  says, straight off the Mac's disk. On the phone, Table/Rack follows `Looking` when it's .8 sure, or
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
    re-solves, with no rescan. Models load off the main thread, in parallel, about 7 s on a cold launch; frames wait for them, and the
    top pill shows progress against the last launch's load time.
    Once the part in view is locked, frames are read a second apart.
  - A capture is a finger lifted off the camera (pressing hides everything drawn over it, to check the framing) or a
    second tap on the Capture tab. The tab's icon is a checkmark for 1.5 s after, so a burst doesn't make duplicates.
    In AR the same starts and stops a recording: every frame read goes to `<start>.jsonl`, a line each (pose, plane,
    a quarter-size person mask, every read with its odds), and every 2 s the frame is captured too, with
    `recording` in its notes naming the log. The log is pushed with the captures once stopped.
  - AR, beside the lens buttons (which leave it), hands the camera to ARKit, an experiment (`Pose.swift`): it finds the table as a
    plane and measures each box on it, in mm under the box, green when tile-sized, so lying on the table; a standing
    rack tile reaches far behind it. Between reads the overlay redraws every display frame where the camera is now,
    each box's bottom edge held to the table (`Pose.follow`). Once ARKit has the table, the table and rack come from
    `World` instead of the five-frame vote, and the rack isn't filtered by `nearest` or Values first. Captures then record the pose, planes and footprints under `ar`. On the Duo
    ARKit has no LiDAR and tracks only with the wide lens, at 1920×1080 here to match the models.
  - The camera is the virtual multi-lens device, so .5× reaches the ultra wide; it starts at the widest, since a whole
    table fits from closer. Captures record the zoom as labeled and the lens.
  - Each frame's read and find times go to `Documents/timing/`, a file a launch, for `make timing`.
  `make` builds it and installs it on the phone (an iPhone named Yam); `make sim`
  builds the Simulator's; `make test` runs the package's tests.

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

## Testing

- `make test` runs everything in the package, the solver and the overlays on rendered tables. `RENDER_DIR=<dir>
  swift test` also writes the step overlays there as PNGs.
- `swift run -c release bench "<table>" "<rack>"` times one solve. The benchmark boards are in `SolverTests`
  (`midgame`, `lateGame`). `bench random 800` times 800 boards dealt from a shuffled set by a fixed seed and prints
  the slowest five: on 2026-11-11, 3.4 ms on average, 0.32 s at worst.
- Recognition is scored on captures by `make score`, and the models by their training scripts.
- Captures from the phone: each capture saves three files to the app's Documents, and pushes them to the labeler:
  - `<ISO time>.png`. PNG, so it holds the pixels the phone read; the first seven were JPEG, converted to PNG on the
    Mac.
  - `<ISO time>.txt`: what it was looking at and the tilt, then the truth, one meld per line. The truth is what was
    read, unless the Layout picker names a known layout.
  - `<ISO time>.json`: the layout, notes, gravity, camera settings, read time and every detection's box. Notes are
    single-word tags separated by spaces, which `check` totals by, and the app keeps the last ones typed. Each
    capture is tagged with its tile set: `pouch`, `large` (#202–285) or `curved` (#80–89); No tiles ones have none.

  They land in `Captures/`, which git ignores since they're hundreds of MB. By cable, `make captures` copies them
  one file at a time, since `devicectl device copy from` with `--source Documents` copies nothing, and skips the
  per-frame timing logs, which `make timing` pulls into `Timing/`. Captures whose truth isn't written yet go in
  `Captures/unlabeled/`; both paths move new "As read" ones there. `make upload` sends them to the Hugging Face dataset
  `visnup/rummikub-captures`, private for now and meant to go public. So before uploading, drop any capture that
  shows readable personal text, like messages on a screen; a screen in frame is fine otherwise.
  `Captures/README.md` is the dataset's card.

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

Before a player has laid down 30 points (`opened: false`, the Solver's "Laid down 30" switch, which Finish turns
on), `opening` picks melds from the rack alone worth 30 or more, placing the most tiles, by a smaller integer program
over the templates in the rack. A joker counts as the tile it stands for, its meld laid out for the most points
(`worth`). The table stays as it is.
