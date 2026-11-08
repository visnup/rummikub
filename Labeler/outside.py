# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Turns sverrela/rummikub (Kaggle, CC0, from arXiv 2411.18172) into captures `train` reads: each photo upright and
shrunk to 1920 px like ours, as <name>.jpg beside its <name>.tiles.json. Its boxes are in the photos' displayed
orientation, so EXIF rotation comes first.
uv run Labeler/outside.py <unzipped dataset> <out>"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageOps

source, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
colors = {"Black": "k", "Blue": "b", "Orange": "o", "Red": "r"}
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
        tile = "j" if number == "J" else colors[label["color"]] + number
        frame = [box[k] * scale for k in ("x", "y", "width", "height")]
        tiles.append({"tile": tile, "frame": frame, "turns": 0, "confirmed": True, "source": "sverrela"})
    name = Path(entry["filename"]).stem
    image.save(out / f"{name}.jpg", quality=92)
    (out / f"{name}.tiles.json").write_text(json.dumps(tiles, indent=2))
    count += 1
print(count, "photos")
