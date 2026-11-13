# TODO

## The game as designed

The flow in "Design" in `CLAUDE.md`, in order. Each step ships on its own.

1. **Table and rack in one view.** With the rack known, `World.parts` takes the rack's tiles back from the table: in
   replays of the 2026-11-13 reports the table came out exact, and the rack 13 of 14 where `World` never had the
   second o10. Left: a first scan mid-game, with nothing known and more than 14 tiles, still splits by Values' rack
   odds alone, so a rack tile seen from above is dropped (07:43's r10) and a phantom can join the rack (06:57's b4).
2. **No moves.** "No moves. Draw a tile." with a button to the rack scanner, which looks for exactly one new tile.
3. **Steps on the Board only.** Drop the AR marks and the camera advancing steps; a tap moves to the next step.
4. **A real game**, reporting (a long press in the Solver) whenever it goes wrong.

## Next

- **Speed.** A frame took about 150 ms to find and 20–90 ms to read on the phone (2026-11-09). Since then a frame's
  boxes go to Values in one call, and the app skips the squares when the whole frame finds only tiles 80 px or more
  (a fifth fewer regions in `score`). Time both with `make timing`.
- **Phantom boxes** are now the finder's biggest error: 32 on held-out captures against 10 tiles missed
  (2026-11-12). Most are in a few captures: #156 (6), #114 (5), #48 (4), #27 (3). Look at what they sit on; if it's
  something real, like a keyboard or a game box, capture more of it with no tiles.
- **The last misses**: #130 (3), #48 (2, the fanned full set with boxes off their tiles), and one each in #86, #128,
  #160, #206 and #267: stacked or low-angle tiles, what a table looks like mid-turn, so captures of real play.
- **Misreads**: 14 misread and 17 unread of 2210. #263 has 9 of them; #320 and #255 most of the rest.
- **`make check`** flags 92 done captures: 50 boxes missed, 109 extra and 17 values, mostly training captures whose
  labels the models disagree with. Work through "to check first" in the labeler, then retrain.

## Captures

Unchecked kinds, roughly in order of what they unblock. Pick the layout and tag the tile set before shooting; the
app pushes each one to `Captures/`.

- **Real games**: crowded mid-game tables with tiles touching, tiles being moved, the rack in a corner of the frame.
- **Light**: warm overhead, dim evening, a lamp making glare, daylight and lamp mixed; racks too.
- **Surfaces**: a white table, a patterned cloth, and each surface from above with no tiles.

## Labeler on a phone

At 600 px or narrower the capture page already shows the list alone at `/captures` and a capture alone once picked,
with ‹ back. What's left is everything the keys do. Buttons can send the same keydown events the keys do, so nothing
is written twice.

- **A toolbar under the photo.**
  - With a box selected: ✓ confirm (Enter), ↺ ↻ orientation (← →), table or rack (`x`), delete (⌫), snap to the
    finder (`f`), next unconfirmed (Tab).
  - With none: done (Enter), next and previous mark (`n` `N`), previous and next capture (`[` `]`). A swipe on the
    header could do `[` `]` too.
  - About 40 lines.
- **Values by tapping the crop grid.** It's already a 4 × 13 table of values with a joker row: tapping a cell or
  empty slot with a box selected sets that box to that value and confirms it. That replaces typing `r12` Enter.
  Part of the toolbar's 40 lines.
- **Pinch to zoom, one finger to pan**, replacing `+` `−` `0`. A tap selects a box or adds one; drawing a box
  becomes a long press then a drag, since a plain drag now pans. About 40 more lines, and the fiddlier half.
- **Left to the keyboard:** `a`, `u`, `D` and shift-drag selection.

## Solver speed

The integer program solves the benchmark boards in 5–27 ms, and 800 random boards of up to 16 melds average 2–4 ms.
A few take longer. `bench random 800` deals them; on 2026-11-11 its slowest, 15 melds with two jokers and a 14-tile
rack, took 0.32 s. Its first front point took 983 nodes, and it had a whole solution at node 11 and the best at 211:
the rest prove that a 15th tile can't be placed (the relaxation says 15.4). So an early incumbent, by rounding or
otherwise, won't help; only a tighter relaxation will, like cuts.

## App

- A flat diagram of the finished table for plays that rebuild most of it (see "Design" in `CLAUDE.md`).

## World

The app is AR only since 2026-11-13. What's left of making the table, not the frame, the unit:

- **Rack by place**, not only Values' mean and the rules: the rack's line, once found, claims any tile on it. One
  frame's footprint, parallax and taper didn't separate them (2026-11-11); height from rays did in #372–390 but not
  with little camera motion (2026-11-13). Once it's by place, AR captures' `part` per detection can label Values' rack
  head in `crops.py`; until then it's Values' own odds averaged, so training on it would learn its own mistakes.
- **Lock per tile**, not per part, and don't read again a tile already sure, which saves the reader most of its time.
- **The Board in table coordinates**, from above.

## Models out of git

Each finder retrain adds about 20 MB to git (fe4ac1e did again), and the pack was 105 MB on 2026-11-11. Move the models to a Hugging
Face model repo beside the captures dataset, `visnup/rummikub-models` (private): `make finder` and `make values`
upload with the `score` line as the message and a tag, `make` and `make sim` `hf download` the revision pinned in the
Makefile into `Rummikub/`, and the packages are gitignored. About 10 lines. The laptop needs `hf auth login` once, and
a fresh clone builds in Xcode only after a `make`. Leave the versions already in history.

## Rules not handled yet

- Scoring: "placed" counts tiles, not their value.
