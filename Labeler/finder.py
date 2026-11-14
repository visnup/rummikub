# /// script
# requires-python = ">=3.12"
# dependencies = ["coremltools", "pillow", "scipy", "torch", "torchvision", "transformers"]
# ///
"""Trains a tile finder and writes it as <captures>/Tiles-new.mlpackage, its checkpoint as .finder-new, beside the
kept ones, which `make keep-finder` replaces with them: D-FINE (Apache 2.0), fine-tuned
from COCO as one class at 640 px, on random squares of the done captures that aren't held out and of every photo in
the other folders with a .tiles.json, like the outside sets `outside.py` converts.

  uv run Labeler/finder.py <captures> [<folder>...]

MINUTES (60) bounds training; on the held-out captures 4 minutes found 854 of 1013 tiles, 15 found 894, 60 found
950. SIZE (small) picks the D-FINE size, PRETRAINED (coco) its pretraining (obj365, obj2coco), and QUARTERS (4) trains on that many quarters of our captures, nested, for a
learning curve. SNAPSHOTS ("15 30") also saves the checkpoint at those minutes, beside it as .finder-new-15 and so on,
for a curve over run lengths.
"""

import json
import os
import random
import shutil
import sys
import time
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import torch

from held import held, weights
from PIL import Image
from torchvision.transforms.functional import pil_to_tensor

size = 640


def frames(labels: Path) -> list[list[float]]:
    return [t["frame"] for t in json.loads(labels.read_text())]


def examples(captures: Path, folders: list[Path]) -> list[tuple[Path, list[list[float]], float]]:
    """Each image, its boxes, and how often to draw it."""
    done = (captures / "boxed.txt").read_text().split()
    quarters = int(os.environ.get("QUARTERS", 4))
    names = [n for i, n in enumerate(sorted(n for n in done if not held(captures, n))) if i % 4 < quarters]
    weight = weights(captures, names)
    ours = [(captures / f"{n}.png", frames(captures / f"{n}.tiles.json"), weight[n]) for n in names]
    outside = [(jpg, frames(jpg.with_suffix(".tiles.json")), 1.0) for f in folders for jpg in sorted(f.glob("*.jpg"))]
    return [e for e in ours + outside if e[1]]


class Squares(torch.utils.data.IterableDataset):
    """Endless random squares: a fifth whole images squashed square, as `Finder` reads the whole frame, the rest a third
    to all of the short side, each at a random quarter turn. A tile the square cuts keeps its clipped box if over half
    of it is inside."""

    def __init__(self, items):
        self.items = items
        self.weights = [w for *_, w in items]

    def __iter__(self):
        rng = random.Random()
        while True:
            path, boxes, _ = rng.choices(self.items, self.weights)[0]
            try:
                image = Image.open(path).convert("RGB")
            except FileNotFoundError:  # deleted in the labeler while training
                continue
            w, h = image.size
            if rng.random() < 0.2:
                x, y, cw, ch = 0, 0, w, h
            else:
                cw = ch = int(min(w, h) * rng.uniform(1 / 3, 1))
                x, y = rng.randint(0, w - cw), rng.randint(0, h - ch)
            kept = []
            for bx, by, bw, bh in boxes:
                x0, y0, x1, y1 = max(bx, x), max(by, y), min(bx + bw, x + cw), min(by + bh, y + ch)
                if x1 > x0 and y1 > y0 and (x1 - x0) * (y1 - y0) > 0.5 * bw * bh:
                    kept.append([(x0 + x1) / 2 - x, (y0 + y1) / 2 - y, x1 - x0, y1 - y0])
            if not kept:
                continue
            pixels = pil_to_tensor(image.crop((x, y, x + cw, y + ch)).resize((size, size), Image.BILINEAR))
            b = torch.tensor(kept) / torch.tensor([cw, ch, cw, ch])
            for _ in range(rng.randrange(4)):  # counterclockwise
                pixels = pixels.rot90(1, (1, 2))
                b = torch.stack([b[:, 1], 1 - b[:, 0], b[:, 3], b[:, 2]], 1)
            yield pixels, b.clamp(0, 1)


def collate(batch):
    pixels = torch.stack([p for p, _ in batch]).float() / 255
    return pixels, [{"class_labels": torch.zeros(len(b), dtype=torch.long), "boxes": b} for _, b in batch]


def train(items, checkpoint: Path, minutes: float):
    from transformers import DFineForObjectDetection

    print(len(items), "images,", sum(len(b) for _, b, _ in items), "tiles", flush=True)
    model = DFineForObjectDetection.from_pretrained(
        f"ustc-community/dfine-{os.environ.get('SIZE', 'small')}-{os.environ.get('PRETRAINED', 'coco')}", num_labels=1, id2label={0: "tile"},
        label2id={"tile": 0}, ignore_mismatched_sizes=True,
    ).to("mps")
    backbone = [p for n, p in model.named_parameters() if "backbone" in n]
    rest = [p for n, p in model.named_parameters() if "backbone" not in n]
    optimizer = torch.optim.AdamW([{"params": backbone, "lr": 1e-5}, {"params": rest, "lr": 1e-4}], weight_decay=1e-4)
    loader = torch.utils.data.DataLoader(
        Squares(items), batch_size=8, collate_fn=collate, num_workers=8, persistent_workers=True, prefetch_factor=4
    )
    model.train()
    start, losses = time.time(), []
    # The rate is constant, so a snapshot at 30 minutes stands in for a 30-minute run.
    snapshots = sorted(float(m) for m in os.environ.get("SNAPSHOTS", "").split())
    for step, (pixels, labels) in enumerate(loader):
        labels = [{k: v.to("mps") for k, v in l.items()} for l in labels]
        loss = model(pixel_values=pixels.to("mps"), labels=labels).loss
        optimizer.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 0.1)
        optimizer.step()
        losses.append(loss.item())
        if step % 200 == 0:
            print(f"step {step} loss {sum(losses) / len(losses):.2f} {time.time() - start:.0f}s", flush=True)
            losses = []
        if snapshots and time.time() - start > snapshots[0] * 60:
            model.save_pretrained(checkpoint.with_name(f"{checkpoint.name}-{snapshots.pop(0):g}"))
        if time.time() - start > minutes * 60:
            break
    model.save_pretrained(checkpoint)


def convert(checkpoint: Path, package: Path):
    """640 px image in, `scores` and center `boxes` out, as `Finder` reads them. coremltools 9.0 can't convert D-FINE
    as it is, so the three parts it chokes on are swapped for equivalents."""
    import coremltools as ct
    import numpy as np
    from coremltools.converters.mil.frontend.torch import ops
    from coremltools.converters.mil.mil import Builder as mb
    from transformers import DFineForObjectDetection
    from transformers.models.d_fine import modeling_d_fine

    cast = ops._cast

    def scalar_cast(context, node, dtype, dtype_name):  # int() of a length-1 array
        x = ops._get_inputs(context, node, expected=1)[0]
        if x.can_be_folded_to_const() and getattr(x.val, "shape", ()) != ():
            context.add(mb.const(val=dtype(np.asarray(x.val).item()), name=node.name), node.name)
        else:
            cast(context, node, dtype, dtype_name)

    ops._cast = scalar_cast
    build = modeling_d_fine.build_2d_sinusoidal_position_embedding
    # Its float64 grid comes out int32; for a fixed input it's a constant anyway.
    modeling_d_fine.build_2d_sinusoidal_position_embedding = lambda *a, **k: torch.tensor(
        build(*a, **k).tolist(), dtype=torch.float32
    )

    def integral(self, corners, project):  # linear wants a 2D weight
        batch, queries, _ = corners.shape
        p = torch.softmax(corners.reshape(-1, self.max_num_bins + 1), dim=1)
        return (p * project.reshape(1, -1)).sum(-1).reshape(batch, queries, -1)

    modeling_d_fine.DFineIntegral.forward = integral

    class Outputs(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model

        def forward(self, pixels):
            out = self.model(pixel_values=pixels)
            return out.logits.sigmoid()[..., 0], out.pred_boxes

    # Anchors fixed at 640 px, else they're computed per input and don't convert.
    model = Outputs(DFineForObjectDetection.from_pretrained(checkpoint, anchor_image_size=[size, size]).eval())
    example = torch.rand(1, 3, size, size)
    ml = ct.convert(
        torch.jit.trace(model, example, strict=False),
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255)],
        outputs=[ct.TensorType(name="scores"), ct.TensorType(name="boxes")],
        minimum_deployment_target=ct.target.iOS18,
    )
    shutil.rmtree(package, ignore_errors=True)
    ml.save(package)


if __name__ == "__main__":
    captures = Path(sys.argv[1])
    checkpoint = captures / ".finder-new"
    train(examples(captures, [Path(f) for f in sys.argv[2:]]), checkpoint, float(os.environ.get("MINUTES", 60)))
    convert(checkpoint, captures / "Tiles-new.mlpackage")
