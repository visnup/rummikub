# /// script
# requires-python = ">=3.12"
# dependencies = ["huggingface_hub", "pillow"]
# ///
"""Turns christophrus/rummikub into a Create ML detection set of one "tile" class: uv run Labeler/bootstrap.py

Its photos are 9248×5204, so each is shrunk to 1920 on its long side as it's downloaded and the original deleted. It's
GPL-3.0, so a model trained on it only pre-labels our captures; the app's model is trained on ours alone."""

import json
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from huggingface_hub import HfApi, hf_hub_download
from PIL import Image, ImageOps

repo = "christophrus/rummikub"
out = Path(__file__).parent.parent / "Bootstrap"
out.mkdir(exist_ok=True)
images = [f for f in HfApi().list_repo_files(repo, repo_type="dataset") if f.startswith("train/images/")]


def convert(name: str) -> dict | None:
    stem = Path(name).stem
    target = out / f"{stem}.jpg"
    with tempfile.TemporaryDirectory() as tmp:
        labels = Path(hf_hub_download(repo, f"train/labels/{stem}.txt", repo_type="dataset", local_dir=tmp)).read_text()
        if not target.exists():
            # YOLO's labels are for the image as EXIF says to show it.
            image = ImageOps.exif_transpose(Image.open(hf_hub_download(repo, name, repo_type="dataset", local_dir=tmp)))
            image.thumbnail((1920, 1920))
            image.convert("RGB").save(target, quality=90)
    width, height = Image.open(target).size
    boxes = []
    for line in labels.splitlines():
        _, cx, cy, w, h = map(float, line.split())
        coordinates = {"x": (cx - w / 2) * width, "y": (cy - h / 2) * height, "width": w * width, "height": h * height}
        boxes.append({"label": "tile", "coordinates": coordinates})
    return {"image": target.name, "annotations": boxes} if boxes else None


with ThreadPoolExecutor(8) as pool:
    annotations = [a for a in pool.map(convert, images) if a]
(out / "annotations.json").write_text(json.dumps(annotations))
print(len(annotations), "images,", sum(len(a["annotations"]) for a in annotations), "tiles")
