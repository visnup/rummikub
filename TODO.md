# TODO

## Strategy: fast, accurate reading

The goal: every tile on the table and rack read right, nothing read from what isn't a tile, fast enough that overlays
stay live. The target, to be checked against measurements: a reading at least 5 times a second on the phone, and
overlays held at 60 fps between readings. Hand-tuned thresholds have topped out: each change trades one photo for
another (`ARCHIVE.md`).

Reading is five stages, each scored on its own and replaceable without touching the others:

1. **Find** each tile's box. Today: numerals from ink blobs ringed by face, kept only inside a learned detector's
   boxes. Next: the detector's boxes alone.
2. **Normalize** each tile into an upright crop of one size, at any angle including upside down. Create ML's
   object detector gives axis-aligned boxes with no angle (from memory, unchecked), so orientation belongs here.
3. **Read** value and color from the crop: glyph matching against references cut from real tiles, and a Core ML
   classifier only if that falls short. Color by hue stays; it's right on every fixture.
4. **Place** tiles in the world: ARKit's table plane and raycasts. That replaces the tilt switch, holds overlays on
   the tiles between readings, and lets the table be panned and remembered.
5. **Settle** what each position says by votes across frames, so one bad frame never re-solves.

### Data

- **Known layouts**: the capture writes the layout as its truth, so there's no hand labeling. The full set is four
  rows, black, blue, orange and red 1–13, then both jokers.
- **No tiles**: backgrounds and clutter, with empty truth. They score false reads and are the backdrops for synthetic
  scenes.
- **Real games**: tables and racks mid-game, labeled by hand from the photo.
- **Synthetic scenes**: real tile crops pasted onto the no-tile photos at random angles, scales, lighting and blur.
- **Held out**: every fifth capture is never used for training or tuning, so scores stay honest once there's a model.

Each capture saves `<time>.png`, `<time>.txt` (what it looked at with the tilt, then the truth, a meld per line) and
`<time>.json`. The JSON holds:
- the layout and notes;
- gravity and tilt;
- the camera's ISO, exposure, lens position, white balance gains, field of view and zoom;
- the read time;
- every detection with its box.

Pick the layout before shooting and type the scene into notes; the app pushes each one to `Captures/`.

### Captures

These are roughly in order of what they unblock. "Full set" is the whole box: two of each number and color, plus
both jokers, 106 tiles. Distance is by framing, not measured:
- **close**: a row of 13 fills the screen's width (about 40 cm);
- **middle**: the row fills half the width (about 80 cm);
- **far**: it fills a third (about 1.2 m).

Take three to five frames of each, moving the phone a little between them, and check off a shot once it's taken.
Unless a shot says otherwise, it's top-down, close, with tiles upright in rows.

2026-11-06's batches were in window daylight: up to 29:16 on the gray cutting mat, and from 34:51 on bare light
wood. They're kept in `Captures/`, which git ignores. Times below are UTC, 22:xx. The orientations come from scoring
each capture at all four rotations.

Captures are meant to be fit for a public dataset. A screen in frame is fine, but not with readable personal text,
like messages. On 2026-11-06, three shots were dropped for showing a chat (24:55, 51:15, 51:23), and two were
cropped below the screen (13:31, 14:46; their JSON records the crop). `Captures/.removed` keeps `make captures`
from copying the dropped ones back.

25:03 and 25:09 were saved as "No tiles", but they show the full set, part of it hidden or out of frame. Their truth
needs writing by hand, so they're in `unlabeled/`, with the early duplicates that have no fixture. 25:18 was saved
as "No tiles" too, and its truth is now fixed to the full set.

- [x] Full set in daylight, upright, top-down: 12:06, 12:36, 15:14
- Full set under each light:
  - [ ] warm overhead light
  - [ ] dim evening
  - [ ] a lamp making glare
  - [ ] mixed daylight and lamp
- Full set on each surface:
  - [x] the gray cutting mat
  - [x] bare wood: upright top-down 35:06, 35:09, 36:30, 36:35, which read as well as on the mat (8 missed, 6
    extra). Sideways, upside down and angled shots follow below.
  - [ ] a white table
  - [ ] a patterned cloth
- Full set from each side of the table:
  - [x] upside down: 13:44 and 35:29 (wood) top-down, 13:53 at an angle
  - [x] turned 90°, 13s to the top: 12:48, 12:53, 14:14, 14:19, 25:55, 25:59 and 35:17 (wood) top-down, 14:09 at an
    angle
  - [x] turned 90°, 13s to the bottom: 34:51, 34:54, 36:42 (wood) top-down, 14:00 at an angle
  - [x] at a low angle from the side, on wood: 35:37, 35:46, 35:58, 36:10, 36:16 (tilt 25–44°). None reads at any
    rotation: the best is 77 missed.

  Rotated a quarter turn the right way, the image reads well: 12:48 drops from 71 misses to 13, 25:55 from 61 to 6,
  and 14:00, turned the other way, from 97 to 23.
- Full set with tiles turned 10–45°:
  - [x] in loose rows: 29:16, 23 missed and 27 extra
  - [x] scattered loose on wood, with no rows at all: 48:54, 49:01, 49:04, 49:45, 49:48, 49:52 top-down, 49:14,
    49:23, 49:32, 49:36 at an angle. Top-down, the best rotation still misses 45–55.
- Full set at other distances and angles:
  - [x] middle, top-down: 25:18, 25:31, 25:35
  - [x] middle at 45°: 13:31, 14:46, cropped below the TV
  - [x] far at 45°, with a keyboard and the rack tray: 14:37, 14:58
  - [x] far, top-down: 25:40, and 36:45 on wood, which reads 3 tiles
- Full set in motion:
  - [x] with a hand moving through the frame: 25:03
  - [x] while panning: 25:09
- No tiles:
  - [x] the bare wood table, top-down: 51:09, which reads nothing
  - [x] at an angle: the bare wood table at 23:21:18 and 23:21:30, which read 6 and 0; the empty mat at 23:21:09
    and 23:21:43, which read 2 and 17
  - [x] the empty mat, top-down: 51:26, 51:30, which read nothing
  - [x] a keyboard: 24:40, which reads 31 tiles
  - [x] a TV with screen text: 24:50, which reads 3 tiles
  - [x] printed boxes: 26:26, game boxes on a shelf, which reads one k4
  - [x] playing cards beside 12 tiles and a keyboard, truth by hand: 58:47 top-down, 58:55 at an angle. Each reads
    about 40 tiles that aren't there, many of them jokers and black 7s.
  - [x] playing cards alone, top-down: 23:00:57 and 23:01:03, which read 68 and 69 tiles. Most are the pips, hearts
    as red 4s and 6s and spades as black 6s and 9s, plus a few jokers.
  - [x] the empty rack tray: 26:42, which reads nothing
  - [ ] each surface from above
- Racks, labeled by hand:
  - [x] real hands from the player's seat on the mat, in daylight, truth by hand. 55:15 and 55:20 hold 10 tiles:
    55:20 reads them all, and 55:15 reads a k5 as k8. 55:44 and 55:51 hold 16 tiles: both read them all, plus one
    or two false b8s from the screen behind.
  - [ ] the same under warm overhead light
  - [ ] the same in dim evening light
- Real games, labeled by hand:
  - [ ] crowded mid-game tables, with tiles touching
  - [ ] the rack in a corner of the frame

Scores, on the Mac and in the Simulator:
- detection precision and recall;
- read accuracy on correct boxes;
- end-to-end misses plus extras (`readsCaptures`);
- the phone's milliseconds per frame, which show on screen, go into each capture's JSON and every frame's into
  `make timing`'s logs.

### Order

1. **Measure, and capture known layouts** (now), so captures pile up while the rest gets built.
2. **Rotation-tolerant reading** on today's pipeline, for upside-down and turned tiles. The same code reads detector
   crops later.
   - Quarter turns were done on 2026-11-06. Over the 74 labeled captures, wrong reads fell from 3878 (2852 missed,
     1026 extra) to 2616 (1823 missed, 793 extra). Clean upright shots held at 180 against 181. Sideways and
     upside-down shots read like upright ones: 12:48 went from 101 wrong to 17, 13:44 from 127 to 13.
   - It costs about 2.3 times as long: the 12 fixtures take 1.9 s on the Mac, up from 0.8 s.
   - Left: tiles turned 10–45°, where scattered shots still miss 30–60, and low angles.
   - `melds` still groups side by side, so sideways tiles come out as one meld each.
   - Each tile's embossed logo sits below its numeral. That tells a 6 from a 9 even alone, and a detector crop could
     use it to find which way is up.
3. **Crops from the fixtures**: cut out each labeled tile. That gives better references (for 5/6 and 11/8) and the
   boxes and crops to train on.
   - On 2026-11-06, `label` agreed with 3362 of 5185 true tiles and confirmed 2207. Clean rows confirm 60–100 of 106.
     Scattered tiles, low and far angles, the loose rows and the cards confirm few or none, so they're labeled by
     hand in `Labeler/`.
   - The boxes are still guessed from the numeral's size. The page fixes them where they're off.
   - Next: references from the confirmed tiles, scored against the font ones.
4. **The detector**: Create ML object detection on real and synthetic scenes, run through Vision. It replaces
   numeral-finding, and with it the false reads on printed text and the rack tray, and tiles joined in glare.
   - In the app since 2026-11-07, filtering the reader: readings outside every box are dropped. Its boxes show
     faintly, and its time shows beside the read time. Trained on whole photos it found 58% of held-out tiles; on
     crops, half the short side, 83% (29 captures). Earlier models are in `ARCHIVE.md`.
   - Since 2026-11-07 the held-out fifth is picked by a hash of the name, and `make score` scores it. With 39 done
     captures it found 269 of 369 held-out tiles (73%) with 131 extras; the set had grown to include a low-angle
     shot.
   - On the reader: against written truth, the held-out captures read 257 of 360 right with 61 extras, and the
     finder's filter barely changes that (255, 61). It drops false reads off the tiles, but most held-out errors
     are misread values on real tiles.
   - Data: 75 captures boxed by 2026-11-07, but most are full sets from two sessions at one table. Learning curve
     (`QUARTERS`) on the 581 held-out tiles: a quarter found 392 (67%) with 274 extras, half 446 (77%) with 194,
     three quarters 446 with 201, all 477 (82%) with 124. Still rising, so more captures pay off; varied ones most:
     real games, racks, other surfaces, light and angles.
   - With sverrela's CC0 Kaggle set (382 photos, 4,434 tiles) too: 468 with 88 extras at Create ML's 1,000
     iterations, 486 (84%) with 106 at 3,000, against 477 with 124 on ours alone. Repeat runs move about ten tiles,
     so it's a modest gain. The app ships the 3,000-iteration model (2026-11-07).
   - On 12 game captures (220 tiles, values written by hand, tilted 31–77°) the reader got 58 right, missed 106 and
     misread 55, many at the wrong quarter turn. Finding numerals at an angle is the gap, not reading them. A value
     classifier given the true box, turned upright, got 177; it mostly reads 6 as 5. Next: finder boxes plus the
     classifier, picking the turn by its confidence over all four.
   - On the phone (`make timing`, 1,317 frames on 2026-11-07): the finder takes 148 ms a frame (max 622) beside the
     reader's 96 (max 288). It runs 16 passes a frame (the whole frame and 15 crops). Backgrounded frames log
     outliers of tens of seconds, which skew later averages.
   - The finder's boxes draw below their tiles on screen while the labels sit on the numerals, so the preview and
     the read frame may be framed differently. Not looked into; captures are unaffected.
   - Considered: Ultralytics YOLO is AGPL. RF-DETR and D-FINE nano are Apache-2.0 and could fine-tune on our boxes,
     but their Core ML export is untested. The Rummikub models on Hugging Face (roeiderman) are gated and
     unlicensed.
5. **The classifier**, if glyph matching on clean crops still confuses values.
   - Tried 2026-11-07 on about 2000 confirmed crops, fixtures' captures left out: on the reader's frames filtered by
     the finder, fixtures went from 59 wrong to 49. It changes 32 values, so it breaks some right ones; k6 often
     reads as k5. It had 100 sixes and 2 jokers. Cropping by the finder's box instead was worse (53).
6. **ARKit** planes, raycasts and voting. The tilt switch goes away.
7. **Speed**: read ARKit's YCbCr buffer directly, skip unchanged frames, and read only unsettled crops.

## Now

Twelve captures from 2026-11-06 are fixtures, with 65 misreads. With quarter turns, the upside-down one (160936) went
from 16 wrong to 8. Each problem is listed with the stage that fixes it:

- Printed text (162408, no tiles): 7 false reads, 3 of them jokers, which skip the crowding check. Fixed by the
  detector.
- Small, distant digits (160551, 160632, numerals 20–35 px tall): 7 read as 1, 2 as 7, 6 as 8, a black 1 as blue,
  and the rack tray as k1s. Fixed by the detector and by scaling crops to one size.
- 5 reads as 6, black and red, top-down (distance .118 to a 6 against .126 to a 5); the black 11 reads as 8, and
  the orange 11 as o8 in 155603. Fixed by reading: references from real crops.
- Tiles turned 15–20° (155924): b10 reads as b4, o11 as o9, k11 as k4 and k6. Fixed by normalizing.
- Washed-out black ink in glare (155856): the rack's k1 and k10 read together as one k11 (hypothesis, untested).
  Fixed by the detector.
- The TV capture is out of focus: the black 1's stem is at v .55–.7, so it's missed, and a subtitle reads as k9.
  Fixed by settling.

## Solver speed

The integer program solves the benchmark boards in 5–27 ms, and 800 random boards of up to 16 melds average 2–4 ms.
A few take longer: the slowest seen, 16 melds with two jokers on the table and a 10-tile rack, took 0.29 s and about
a thousand branch-and-bound nodes, nearly all proving the most "kept" for a front point. Ideas: a rounding
heuristic for an early incumbent, or cuts.

## App

- Rack steps show only the target while looking at the table, and only the tile to pick up while looking at the
  rack.
- New melds go in a row under the table, which may be off screen or on top of the rack.
- A flat diagram of the finished table for plays that rebuild most of it (see "Design" in `CLAUDE.md`).

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

Not rerun since the thresholds changed for the fixtures (see "Now"); download them again to check.
