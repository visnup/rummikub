# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "scipy", "torch", "torchvision", "transformers"]
# ///
"""Draws boxes on every capture not yet edited by hand, with the finder `finder.py` last trained, as the app reads
them: uv run Labeler/prelabel.py [--new].

A box takes the value of the tile already there it overlaps most; confirmed tiles stay where no box overlaps them."""

import json
import sys
from pathlib import Path

import torch
from PIL import Image
from torchvision.transforms.functional import pil_to_tensor

captures = Path(__file__).parent.parent / "Captures"
# With --new, only captures with no boxes yet.
new_only = "--new" in sys.argv


def iou(a, b):
    w = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    h = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    i = w * h
    return i / (a[2] * a[3] + b[2] * b[3] - i) if i else 0


def tiles(name):
    path = captures / f"{name}.tiles.json"
    return json.loads(path.read_text()) if path.exists() else []


done = set((captures / "boxed.txt").read_text().split())


def needs(png):
    """Whether a capture gets boxes drawn: not done or edited by hand, nor known to hold no tiles."""
    name = str(png.relative_to(captures).with_suffix(""))
    txt = png.with_suffix(".txt")
    empty = png.parent == captures and txt.exists() and not "".join(txt.read_text().splitlines()[1:]).strip()
    if name in done or empty or any(t.get("source") == "hand" for t in tiles(name)):
        return False
    return not (new_only and (captures / f"{name}.tiles.json").exists())


# Nothing to box costs nothing: `make watch` runs this every 30 s.
todo = [png for png in sorted([*captures.glob("*.png"), *captures.glob("unlabeled/*.png")]) if needs(png)]
if not todo:
    sys.exit()

from transformers import DFineForObjectDetection

device = "mps" if torch.backends.mps.is_available() else "cpu"
# Whether to look in crops too, as `Finder.cropped`.
cropped = True
model = DFineForObjectDetection.from_pretrained(captures / ".finder").to(device).eval()


@torch.no_grad()
def detect(image, least=0.6):
    """As `Finder` does: the whole photo and squares its short side overlapping by about half, each at 640 px; a box
    cut by a square's edge left to the square it's whole in, and one overlapping a likelier box by over .3 (IoU)
    dropped."""
    w, h = image.size
    side = min(w, h)

    def starts(length):
        n = -(-(length - side) // (side // 2)) + 1
        return [0] if n == 1 else [(length - side) * i // (n - 1) for i in range(n)]

    regions = [(0, 0, w, h)] + [(x, y, side, side) for y in starts(h) for x in starts(w)] * cropped
    pixels = torch.stack([
        pil_to_tensor(image.crop((x, y, x + rw, y + rh)).resize((640, 640), Image.BILINEAR)) for x, y, rw, rh in regions
    ])
    out = model(pixel_values=(pixels.float() / 255).to(device))
    found = []
    for (x, y, rw, rh), scores, boxes in zip(regions, out.logits.sigmoid()[..., 0].cpu(), out.pred_boxes.cpu()):
        for score, (cx, cy, bw, bh) in zip(scores.tolist(), boxes.tolist()):
            box = [x + (cx - bw / 2) * rw, y + (cy - bh / 2) * rh, bw * rw, bh * rh]
            cut = (
                (box[0] < x + 2 and x > 0) or (box[0] + box[2] > x + rw - 2 and x + rw < w)
                or (box[1] < y + 2 and y > 0) or (box[1] + box[3] > y + rh - 2 and y + rh < h)
            )
            if score > least and not cut:
                found.append((box, score))
    kept = []
    for f in sorted(found, key=lambda f: -f[1]):
        if all(iou(f[0], k[0]) <= 0.3 for k in kept):
            kept.append(f)
    return kept


for png in todo:
    name = str(png.relative_to(captures).with_suffix(""))
    current = tiles(name)
    found = detect(Image.open(png).convert("RGB"))
    unmatched = list(current)
    merged = []
    for box, score in found:
        tile = {"tile": "?", "turns": 0, "confirmed": False}
        overlaps = [iou(t["frame"], box) for t in unmatched]
        if overlaps and max(overlaps) > 0:
            tile = unmatched.pop(overlaps.index(max(overlaps)))
        merged.append({**tile, "frame": box, "source": "finder", "confidence": score})
    merged += [t for t in unmatched if t.get("confirmed") and not any(iou(t["frame"], b) > 0 for b, _ in found)]
    (captures / f"{name}.tiles.json").write_text(json.dumps(merged, indent=2, sort_keys=True))
    print(name, len(current), "→", len(merged), "boxes", flush=True)
