# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Tile crops for the value classifiers, one folder per tile (k1…r13, j), each 224 px square, written under
<out>/upright and <out>/any. Upright: confirmed tiles of done captures that aren't held out, turned upright, for
racks. Any: the same at all four quarter turns, plus every tile of the outside sets as it lies, for tables.
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
for kind in ("upright", "any"):
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
            save(upright.rotate(90 * turn, expand=True), "any", t["tile"], f"{key}-{turn}")
for folder in outside:
    for labels in sorted(folder.glob("*.tiles.json")):
        stem = labels.name.removesuffix(".tiles.json")
        image = Image.open(folder / f"{stem}.jpg").convert("RGB")
        for i, t in enumerate(json.loads(labels.read_text())):
            tile = crop(image, t["frame"])
            if min(tile.size) >= 20:
                save(tile, "any", t["tile"], f"{folder.name}-{stem}-{i}")
for kind in ("upright", "any"):
    print(kind, sum(1 for _ in (out / kind).glob("*/*.jpg")), "crops")
