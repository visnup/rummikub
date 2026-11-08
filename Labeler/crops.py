# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Tile crops for the value classifiers, each 224 px square. Upright, one folder per tile (k1…r13, j): confirmed
tiles of done captures that aren't held out, turned upright, for racks. Turned, one folder per tile and turn ("k6@2",
the quarter turns clockwise that make it upright): the same at all four turns, plus the outside sets' tiles, for
tables. Outside, one folder per tile: the outside sets' tiles as they lie, for `values --turns`.
uv run Labeler/crops.py <captures> <out> [<outside set>...]"""

import json
import shutil
import sys
from pathlib import Path

from PIL import Image

captures, out = Path(sys.argv[1]), Path(sys.argv[2])
outside = [Path(p) for p in sys.argv[3:]]


def held(name: str) -> bool:
    """The same as Finder.isHeldOut."""
    h = 14695981039346656037
    for b in name.encode():
        h = ((h ^ b) * 1099511628211) % 2**64
    return h % 5 == 0


def crop(image, frame):
    x, y, w, h = frame
    return image.crop((max(0, round(x)), max(0, round(y)), min(image.width, round(x + w)), min(image.height, round(y + h))))


def save(image, kind, tile, name):
    (out / kind / tile).mkdir(parents=True, exist_ok=True)
    image.resize((224, 224), Image.Resampling.BILINEAR).save(out / kind / tile / f"{name}.jpg", quality=90)


# The crops, not the feature prints `values` keeps beside them, which spare it reading unchanged crops again.
for kind in ("upright", "turned", "outside"):
    shutil.rmtree(out / kind, ignore_errors=True)
for name in (captures / "boxed.txt").read_text().split():
    if held(name):
        continue
    tiles = [t for t in json.loads((captures / f"{name}.tiles.json").read_text()) if t.get("confirmed") and t.get("tile", "?") != "?"]
    image = Image.open(captures / f"{name}.png").convert("RGB") if tiles else None
    for i, t in enumerate(tiles):
        upright = crop(image, t["frame"]).rotate(-90 * t.get("turns", 0), expand=True)
        if min(upright.size) < 20:
            continue
        key = f"{name.replace('/', '-')}-{i}"
        save(upright, "upright", t["tile"], key)
        for turn in range(4):
            # Labeled with the quarter turns clockwise that make it upright, so an upside-down 6 isn't a 9.
            save(upright.rotate(90 * turn, expand=True), "turned", f"{t['tile']}@{turn}", f"{key}-{turn}")
for folder in outside:
    for labels in sorted(folder.glob("*.tiles.json")):
        stem = labels.name.removesuffix(".tiles.json")
        image = Image.open(folder / f"{stem}.jpg").convert("RGB")
        for i, t in enumerate(json.loads(labels.read_text())):
            tile = crop(image, t["frame"])
            if t["tile"] != "?" and min(tile.size) >= 20:
                save(tile, "outside", t["tile"], f"{folder.name}-{stem}-{i}")
# Outside tiles lie at turns nobody wrote down, so they join `turned` at the turn a turned model gives them
# (`values --turns`), where it's .9 sure; not 6s and 9s, whose turn is the very thing it confuses.
known = out / "outside.turns"
for line in known.read_text().splitlines() if known.exists() else []:
    path, turns, share = line.split("\t")
    tile, name = path.split("/")
    if float(share) >= 0.9 and tile[1:] not in ("6", "9") and (out / "outside" / path).exists():
        upright = Image.open(out / "outside" / path).rotate(-90 * int(turns))
        for turn in range(4):
            save(upright.rotate(90 * turn), "turned", f"{tile}@{turn}", f"{name.removesuffix('.jpg')}-{turn}")
for kind in ("upright", "turned", "outside"):
    print(kind, sum(1 for _ in (out / kind).glob("*/*.jpg")), "crops")
