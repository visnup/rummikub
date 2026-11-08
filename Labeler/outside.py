# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy", "pillow"]
# ///
"""Turns an outside dataset into captures `train` reads: each photo upright, as <name>.jpg beside its
<name>.tiles.json. Two formats:
- sverrela/rummikub (Kaggle, CC0, from arXiv 2411.18172), VIA JSON: shrunk to 1920 px like ours. Its boxes are in the
  photos' displayed orientation, so EXIF rotation comes first.
- A Roboflow export as CreateML JSON (train/, valid/, test/). Photos uploaded already rotated, with black corners, keep
  the boxes of the unrotated photo, which no longer fit their tiles, so they're skipped; black bars are cropped off.
  Labels like Black9, black_9, 9_black, yellow9 or Joker give the tile; any other label leaves it "?", a box without
  a value.
uv run Labeler/outside.py <unzipped dataset> <out>"""

import json
import math
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

source, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
colors = {"black": "k", "blue": "b", "bliue": "b", "orange": "o", "yellow": "o", "red": "r"}


def save(image, name, tiles):
    image.save(out / f"{name}.jpg", quality=92)
    (out / f"{name}.tiles.json").write_text(json.dumps(tiles, indent=2))


def tile(label: str) -> str:
    label = label.lower()
    if "joker" in label or re.fullmatch(r"j(_[a-z]+)?", label):
        return "j"
    color = next((c for c in colors if c in label), None)
    number = re.search(r"\d+", label)
    return colors[color] + number[0] if color and number and 1 <= int(number[0]) <= 13 else "?"


def sverrela():
    count = 0
    for entry in json.loads((source / "rummikub.json").read_text()).values():
        path = source / "images" / entry["filename"]
        if not entry["regions"] or not path.exists():
            continue
        image = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        scale = 1920 / max(image.size)
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.Resampling.LANCZOS)
        tiles = []
        for region in entry["regions"]:
            box, label = region["shape_attributes"], region["region_attributes"]
            number = label.get("number")
            frame = [box[k] * scale for k in ("x", "y", "width", "height")]
            name = "j" if number == "J" else colors[label["color"].lower()] + number
            tiles.append({"tile": name, "frame": frame, "turns": 0, "confirmed": True, "source": "sverrela"})
        save(image, Path(entry["filename"]).stem, tiles)
        count += 1
    return count


def inside_of(inner, outer) -> bool:
    """Whether inner's center is in outer."""
    x, y = inner[0] + inner[2] / 2, inner[1] + inner[3] / 2
    return outer[0] <= x <= outer[0] + outer[2] and outer[1] <= y <= outer[1] + outer[3]


def edge(row) -> int:
    """How many dark pixels lead the row."""
    lit = np.nonzero(row > 12)[0]
    return int(lit[0]) if len(lit) else len(row)


def roboflow():
    count = skipped = 0
    for labels in sorted(source.glob("*/_annotations.createML.json")):
        for entry in json.loads(labels.read_text()):
            image = Image.open(labels.parent / entry["image"]).convert("RGB")
            gray = np.asarray(image.convert("L"))
            # A rotated photo's black corner is a triangle: its legs along the top and left edges give the angle. Black
            # bars give a sliver of an angle.
            x, y = edge(gray[2]), edge(gray[:, 2])
            if min(math.atan2(y, max(x, 1)), math.atan2(x, max(y, 1))) > math.radians(10):
                skipped += 1
                continue
            lit = np.nonzero(gray > 12)
            left, top = int(lit[1].min()), int(lit[0].min())
            image = image.crop((left, top, int(lit[1].max()) + 1, int(lit[0].max()) + 1))
            scale = min(1, 1920 / max(image.size))
            image = image.resize((round(image.width * scale), round(image.height * scale)), Image.Resampling.LANCZOS)
            boxes = []
            for a in entry["annotations"]:
                c = a["coordinates"]
                frame = [c["x"] - c["width"] / 2 - left, c["y"] - c["height"] / 2 - top, c["width"], c["height"]]
                frame = [v * scale for v in frame]
                boxes.append((a["label"], frame))
            # rummikub-3gqr9 labels a tile with its color or its value, each its own box, in different photos.
            values = [(label, f) for label, f in boxes if re.fullmatch(r"\d+|J", label)]
            tiles = []
            for label, frame in boxes:
                if (label, frame) in values:
                    if any(inside_of(frame, f) for other, f in boxes if other.lower() in colors):
                        continue
                    label = "joker" if label == "J" else "?"
                elif label.lower() in colors:
                    inside = [v for v, f in values if inside_of(f, frame)]
                    label = "joker" if inside == ["J"] else label + inside[0] if len(inside) == 1 else "?"
                tiles.append({"tile": tile(label), "frame": frame, "turns": 0, "confirmed": True, "source": source.name})
            save(image, Path(entry["image"]).stem, tiles)
            count += 1
    print(skipped, "rotated photos skipped")
    return count


print(roboflow() if any(source.glob("*/_annotations.createML.json")) else sverrela(), "photos")
