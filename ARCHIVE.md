# Archive

What was tried and dropped, so nobody repeats it.

## Recognition

- **The hand-built reader** (`Recognizer.tiles`, 2026-11-06 to 11-09, removed once the finder and `Values` were the
  only path the app used). It found numerals, not tiles: ink blobs with tile face all around, joined into numbers,
  matched against glyphs rendered in bold fonts and baked into `References.bin` on macOS (iOS renders fonts
  differently), colored by the ink's hue, at all four quarter turns. The face color was the peak of a
  saturation/value histogram, since white balance varies too much for fixed thresholds. On the 12 fixtures it made
  65 misreads; on held-out captures it read 509 of 1048 right with 305 extras, where `Values` on the finder's boxes
  read 993 with 10. It did best on a plain dark surface, tiles upright in rows, top-down from 30–50 cm; light wood
  grain gave false reads, shaded tile edges misses, and printed text and playing cards read as tiles. The entries
  below are what tuning it tried.
- **Vision's text recognition** (`RecognizeTextRequest`, 2026-11-06). On rendered tables it skipped most lone digits
  (1–4 and the 1s of a group), and per-tile `regionOfInterest` passes found nothing. On the real board photo it still
  missed every lone 1, 3 and 9, and its first call took 54 s while the model loaded.
- **Finding tiles first**: tile-face blobs split into tile-width pieces by aspect ratio. On the real photo blobs ran
  into the wood and the splits fell between digits. Finding numerals and guessing each tile's frame from the numeral's
  size replaced it.
- **Matching whole numbers** against rendered 1–13: real "10"–"13" all read as 11 or 13. Each digit is now matched on
  its own against 0–9, in several fonts, with glyphs scaled to unit length so boldness matters less.
- **Fixed tile-face thresholds.** The board photo's faces are bluish (saturation up to .24, value ~.95) and the rack
  photo's are warm and dark (value .66–.76). Any fixed cut that took both let light wood in. The face color is now the
  peak of a saturation/value histogram.
- **White balance from the brightest near-gray pixels**: on the rack photo those were floor glare, not tiles, and on
  the board photo the brightest were blown out, so it found nothing.
- **A median-height filter on numerals**: background tiles on the rack photo are a third the size of the rack's, so
  the rack's own were dropped. Only an absolute minimum (shorter side / 80) is left.
- **A median-saturation check on the ring around a numeral**, to reject wood: the board photo's bluish faces failed it.
- **Ink value relative to the face** (face − .4 to − .55) instead of a fixed .4, for the out-of-focus black 1 in the
  TV captures (stem at v .55–.7): 20–28 misreads on the fixtures against 19, and the 1 was still missed.
- **A numeral centered on a tile-sized face** (2026-11-06), to reject keyboards and subtitles before reading: tile
  face runs on into neighboring tiles and the rack tray without a visible seam, so real tiles measured 0.02 to 11
  numeral heights of face to each side, and the false k9 on a subtitle (4.1, 2.1) and k1s on the rack tray (3.5,
  3.5) fell inside that. Not built. Stroke width caught the keyboard instead.
- **A 3×3 blur of glyph cells** before matching, to soften aliasing: 29 misreads against 25.
- **A wider value margin for the face** (peak − .3) to catch the rack photo's shaded green 7: it let wood grain in on
  the board photo and still missed the 7.
- **The color from the ink's hue** (`inkColor` in the middle 60% of each finder box), weighing `Values`' tiles in
  other colors by .2: 896 of 1048 right with 85 extras against 892 with 84, on 2026-11-08. Letting the hue decide
  outright read 853 with 131, so it's wrong too often to trust. 10 of the 100 misreads were color only.
- **Values as logistic regression over Vision's feature print**, replaced 2026-11-09 by a small CNN, which read 974 of
  1048 held-out tiles right with 35 extras through the same finder boxes, against 897 with 79. Two models: `Values`,
  a class per tile and orientation ("k6@2") from crops at all four, and `RackValues`, a class per tile, upright. Its
  orientations were right for 417 of 552 held-out tiles, even with touching tiles voting, where the CNN's are 96%
  right alone: the feature print barely sees rotation. It was quick, 80 s cold and seconds warm, since prints were
  kept by crop. Before it, Create ML's image classifier took about 8 minutes every time, read 474 of 703 with 209
  extras against its 486 with 194, failed past a few thousand images ("Failed to create CVPixelBufferPool") unless
  run as a session, and its default flips took validation from 96% to 78%.
- **A finder with a class per orientation**, so one D-FINE pass gives boxes and orientations: right for 541 of 552
  held-out tiles, but it found 929 of 1057 at .6 against the one-class finder's 1003, and lower cutoffs brought
  extras (976 with 90 at .4). Untested whether that's the four classes, its ~1,700 fewer tiles (photos with no
  confirmed orientation were left out) or run noise. Still the goal once boxes hold up.

## Tile finder

- **Training on whole frames, with tiles under 30 px as background** (2026-11-09), for a finder that reads the whole
  frame alone: 60 minutes found 897 of 960 held-out tiles in scope with 26 extras, where the finder trained on random
  squares, run on the whole frame alone, found 908 with 12. Squares the short side, 4 regions, found 932 instead.

- **Bootstrapping on [christophrus/rummikub](https://huggingface.co/datasets/christophrus/rummikub)** (2026-11-07):
  828 boxed photos of a similar tile set, trained with ours, took held-out tiles found from 83% to 92% with 44 extra
  boxes, against 129 on ours alone (29 captures). It's GPL-3.0, so its model only pre-labeled, never shipped. Dropped
  once OWLv2 with a probe pre-labeled better from our boxes alone; `Labeler/bootstrap.py` and `make bootstrap` are in
  the history.
- **A Create ML object detector** (`train`, replaced 2026-11-08 by D-FINE). Its object print reads every region at
  299 px, so a 22 px tile shrinks to a few pixels: on 1013 held-out tiles it found 764 with 203 extras, and a
  quarter of our captures did nearly as well as all of them (741). Crops a quarter of the short side found 860 but
  read no more right, the extra tiles too small for the classifier; YOLO (darknet) at 416 px found 746 with 155 after
  32 minutes. D-FINE small found 950 with 45. Ultralytics YOLO26s, AGPL so only a benchmark, found 924 with 56 in
  the same hour.
- **The detectors again, 2026-11-11**, an hour each on that day's captures, scored by `score` on 2058 held-out tiles
  (missed, phantom): the kept D-FINE small 24 and 35; a fresh D-FINE small 9 and 38 at .6; D-FINE nano 34 and 46 at
  .6, 28 and 95 at .5; YOLO26s 7 and 50 at .5, 22 and 37 at .6; OWLv2 with a probe 123 and 292. YOLO26s matches
  D-FINE small's finds with a few more phantoms, but it's AGPL. The scripts were `yolo.py` and `owl.py`, not kept.
- **D-FINE small from Objects365 then COCO** (`PRETRAINED=obj2coco`, 2026-11-12), against COCO alone: on 2309
  held-out tiles it missed 30 with 23 phantoms, where the kept finder missed 9 with 22. One run, but runs vary by
  about 10 misses.
- **Vision's rectangle detector as the finder** (`VNDetectRectanglesRequest`, every rectangle, 2026-11-11): 789 of
  2114 held-out tiles found, with 1862 phantom boxes.
- **Cheat at SET's card finder** (`visnup/cheat-at-set`, 2026-11-12), ported to tiles: luminosity over a threshold,
  bright 8-connected blobs, filled hulls kept by area and some ink inside. At its best threshold, 195, it found 1073
  of 2309 held-out tiles with 358 phantoms; at its own 212, 1009 with 270. Set cards lie apart, but tiles in a meld
  or on a rack touch, and a bright tabletop merges with them, so their blobs come out too big (fits the misses, not
  checked on the images).
- **Rack or table by a tile's taper** (`Standing`, 2026-11-11): cast onto a plane level with the table, a standing
  tile's top edge comes out longer than its bottom edge, about 1.15 at 30–40 cm, and a flat tile's the same length;
  gravity alone places the plane. Corners are the extremes of the box's largest bright patch. On the 14 held-out
  rack captures with background marked, rack tiles' median was 1.23 and table tiles' 1.02, but they overlap: at 1.08
  it kept 116 of 135 rack tiles and let 6 table tiles through, where Values' rack head keeps 135 with 4. Of those 4,
  it would drop 3, at the cost of 19 rack tiles. Touching rack tiles likely merge into one bright patch, so better
  corners might close the gap; `score` still prints it (`TAPER`, `TAPERS`).
- **Create ML's own pre-labels**: `train` used to draw its boxes on unchecked captures. On the same held-out captures
  it found 199 of 263 tiles with 110 extras; OWLv2 with a probe found 248 with 14.
- **OWLv2 with a linear probe as the pre-labeler** (`prelabel.py`, replaced 2026-11-08 by the finder). Frozen OWLv2 on
  the finder's crops, with a probe trained on the done captures' boxes, two passes so the second learned from the
  first's false tiles; a box mostly inside a likelier one was dropped, since numerals got boxes of their own. It found
  897 of 1013 held-out tiles with 153 extras, where D-FINE found 950 with 45, and keyboard keys still got boxed. A
  text prompt alone needed the crops, since whole photos shrink to OWL's 960 px.
- **OWLv2 queried with the mean tile embedding** instead of a probe: about 2,000 extra boxes at any threshold, since
  OWL's per-patch logit shift and scale swamp a single query.
- **A value classifier** (Create ML image classifier on upright crops of confirmed tiles): on the fixtures, reader
  frames filtered by the finder went from 59 wrong to 49, but it breaks right values too, mostly 6 read as 5. On 12
  game captures given the true box and turn it read 177 of 220. `Values` replaced it.

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
