# /// script
# requires-python = ">=3.12"
# dependencies = ["transformers", "torch", "pillow", "scipy"]
# ///
"""Draws boxes on every capture not yet edited by hand, with OWLv2 and a linear probe trained on the done captures'
boxes: uv run Labeler/prelabel.py [--new]. Too big for the phone, so it only pre-labels.

A box takes the value of the tile already there it overlaps most; confirmed tiles stay where no box overlaps them."""

import hashlib
import json
import sys
from pathlib import Path

import torch
from PIL import Image
from transformers import Owlv2ForObjectDetection, Owlv2Processor
from transformers.image_transforms import center_to_corners_format

captures = Path(__file__).parent.parent / "Captures"
threshold = 0.8
# With --new, only captures with no boxes yet.
new_only = "--new" in sys.argv


def shared(a, b):
    w = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
    h = max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
    return w * h


def iou(a, b):
    i = shared(a, b)
    return i / (a[2] * a[3] + b[2] * b[3] - i) if i else 0


def contained(a, b):
    """How much of the smaller box lies in the other: a numeral's box inside its tile's has a low IoU but a high
    overlap here."""
    return shared(a, b) / min(a[2] * a[3], b[2] * b[3])


@torch.no_grad()
def embed(image):
    """Per patch of a square crop: a unit class embedding and a box (x, y, w, h in the crop's pixels)."""
    pixels = processor(images=image, return_tensors="pt").pixel_values.to(device)
    feature_map, _ = model.image_embedder(pixels)
    b, h, w, d = feature_map.shape
    feats = feature_map.reshape(b, h * w, d)
    _, embeds = model.class_predictor(feats)
    embeds = embeds[0] / embeds[0].norm(dim=-1, keepdim=True)
    boxes = center_to_corners_format(model.box_predictor(feats, feature_map))[0] * max(image.size)
    boxes = torch.stack([boxes[:, 0], boxes[:, 1], boxes[:, 2] - boxes[:, 0], boxes[:, 3] - boxes[:, 1]], 1)
    return embeds, boxes.cpu().tolist()


def crops(w, h, overlap):
    """Squares half the short side, as in `Finder`: tiles too small for OWL's 960 px input whole are large in them."""
    side = min(w, h) // 2
    step = side // 2 if overlap else side
    return [(x, y, side) for y in range(0, h - side + 1, step) for x in range(0, w - side + 1, step)]


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


# Nothing to box costs nothing: `make watch` runs this every 30 s, and retraining the probe whenever a capture is
# checked kept the GPU busy under training.
todo = [png for png in sorted([*captures.glob("*.png"), *captures.glob("unlabeled/*.png")]) if needs(png)]
if not todo:
    sys.exit()
device = "mps" if torch.backends.mps.is_available() else "cpu"
processor = Owlv2Processor.from_pretrained("google/owlv2-base-patch16-ensemble")
model = Owlv2ForObjectDetection.from_pretrained("google/owlv2-base-patch16-ensemble").to(device).eval()

@torch.no_grad()
def examples(probe=None):
    """Each true tile's best-fitting patch is a tile. Patches that fit a tile badly are not, or they come back as extra
    boxes beside the good one; so is a sample of the rest. Given a probe, also every patch it wrongly calls a tile:
    keyboard keys, mostly, too few to turn up in the sample."""
    positives, negatives = [], []
    for name in sorted(done):
        image = Image.open(captures / f"{name}.png").convert("RGB")
        true = [t["frame"] for t in tiles(name)]
        for x, y, s in crops(*image.size, overlap=False):
            within = [(bx - x, by - y, bw, bh) for bx, by, bw, bh in true if bx >= x and by >= y and bx + bw <= x + s and by + bh <= y + s]
            embeds, boxes = embed(image.crop((x, y, x + s, y + s)))
            scores = torch.sigmoid(probe(embeds).squeeze(1)).tolist() if probe else None
            for t in within:
                i = max(range(len(boxes)), key=lambda i: iou(boxes[i], t))
                if iou(boxes[i], t) > 0.5:
                    positives.append(embeds[i])
            for i, box in enumerate(boxes):
                best = max((iou(box, t) for t in within), default=0)
                if best < 0.4 and (best > 0.05 or i % 7 == 0 or (scores and scores[i] > 0.5 and best == 0)):
                    negatives.append(embeds[i])
    return positives, negatives


def train(positives, negatives):
    X = torch.cat([torch.stack(positives), torch.stack(negatives)])
    Y = torch.cat([torch.ones(len(positives)), torch.zeros(len(negatives))]).to(device)
    probe = torch.nn.Linear(X.shape[1], 1).to(device)
    optimizer = torch.optim.Adam(probe.parameters(), lr=1e-2, weight_decay=1e-4)
    weight = torch.where(Y == 1, len(negatives) / len(positives), 1.0)
    for _ in range(500):
        optimizer.zero_grad()
        torch.nn.functional.binary_cross_entropy_with_logits(probe(X).squeeze(1), Y, weight=weight).backward()
        optimizer.step()
    return probe


# The probe is kept until the done captures' boxes change, so `make watch` only pays for the new photos.
key = hashlib.sha256("".join(sorted(done)).encode() + b"".join(
    (captures / f"{name}.tiles.json").read_bytes() for name in sorted(done))).hexdigest()
cache = captures / ".probe.pt"
saved = torch.load(cache) if cache.exists() else {}
if saved.get("key") == key:
    probe = torch.nn.Linear(saved["state"]["weight"].shape[1], 1).to(device)
    probe.load_state_dict(saved["state"])
else:
    probe = train(*examples())
    positives, negatives = examples(probe)
    print("learning from", len(positives), "tiles and", len(negatives), "others in", len(done), "captures", flush=True)
    probe = train(positives, negatives)
    torch.save({"key": key, "state": probe.state_dict()}, cache)


@torch.no_grad()
def detect(image):
    """Boxes over the threshold, most likely first. A box cut by an inner crop edge is left to the crop it's whole in,
    and one overlapping a likelier box, or mostly inside it, is dropped."""
    w, h = image.size
    found = []
    # The whole photo too, for tiles too large to sit whole in any crop.
    for x, y, s in [(0, 0, None)] + crops(w, h, overlap=True):
        embeds, boxes = embed(image if s is None else image.crop((x, y, x + s, y + s)))
        scores = torch.sigmoid(probe(embeds).squeeze(1)).cpu().tolist()
        for (bx, by, bw, bh), score in zip(boxes, scores):
            cut = s is not None and (
                (bx < 2 and x > 0) or (bx + bw > s - 2 and x + s < w) or (by < 2 and y > 0) or (by + bh > s - 2 and y + s < h))
            if score > threshold and not cut:
                found.append(([bx + x, by + y, bw, bh], score))
    kept = []
    for f in sorted(found, key=lambda f: -f[1]):
        if all(iou(f[0], k[0]) <= 0.1 and contained(f[0], k[0]) < 0.5 for k in kept):
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
        merged.append({**tile, "frame": box, "source": "owl", "confidence": score})
    merged += [t for t in unmatched if t.get("confirmed") and not any(iou(t["frame"], b) > 0 for b, _ in found)]
    (captures / f"{name}.tiles.json").write_text(json.dumps(merged, indent=2, sort_keys=True))
    print(name, len(current), "→", len(merged), "boxes", flush=True)
