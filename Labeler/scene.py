# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Whole frames for the scene classifier, by `scene.txt`'s label for each capture: rack, or table. Shrunk to 299 px
square, as the classifier sees them. Held-out captures are left out.
uv run Labeler/scene.py <captures> <out>"""

import shutil
import sys
from pathlib import Path

from PIL import Image

from held import held

captures, out = Path(sys.argv[1]), Path(sys.argv[2])


shutil.rmtree(out, ignore_errors=True)
counts = {}
for line in (captures / "scene.txt").read_text().splitlines():
    name, label = line.split()
    if held(name):
        continue
    (out / label).mkdir(parents=True, exist_ok=True)
    image = Image.open(captures / f"{name}.png").convert("RGB").resize((299, 299), Image.Resampling.BILINEAR)
    image.save(out / label / f"{name.replace('/', '-')}.jpg", quality=90)
    counts[label] = counts.get(label, 0) + 1
print(counts)
