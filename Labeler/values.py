# /// script
# requires-python = ">=3.12"
# dependencies = ["coremltools", "pillow", "torch", "torchvision"]
# ///
"""Trains Values, which reads a tile crop, its orientation (the quarter turns clockwise that make it upright), and
whether it stands on a rack or lies on the table: MobileNetV3 (ImageNet) at 128 px with a head for each, on
`.crops/upright` at random orientations, for MINUTES (5) on the Mac's GPU. Prints, each epoch, the held-out confirmed
tiles read right at their labeled boxes. Converts to `Values.mlpackage`, an image classifier whose classes are tiles
at an orientation, on the table or a rack ("k6@2", "k6@2@rack"), each p(tile)·p(orientation)·p(rack), and
writes `.crops/outside.turns`, the orientation it gives each outside crop, for `crops.py`'s next run.
uv run Labeler/values.py <captures>"""

import json
import os
import random
import sys
import time
from pathlib import Path

import torch
import torchvision
from PIL import Image
from torchvision.transforms import v2

from held import held

captures = Path(sys.argv[1])
crops = captures / ".crops"
SIZE = 128
tiles = sorted(p.name for p in (crops / "upright").iterdir())
index = {t: i for i, t in enumerate(tiles)}
# 1 stands on a rack, 0 lies on the table, -1 unknown and left out of that loss.
stands = dict(line.split("\t") for line in (crops / "stands.tsv").read_text().splitlines()) if (crops / "stands.tsv").exists() else {}
train = [(p, index[p.parent.name], {"rack": 1, "table": 0}.get(stands.get(f"{p.parent.name}/{p.name}"), -1))
         for p in (crops / "upright").glob("*/*.jpg")]
jitter = v2.Compose([
    v2.RandomResizedCrop(SIZE, scale=(0.8, 1), ratio=(0.8, 1.25)),
    v2.ColorJitter(0.3, 0.3, 0.3, 0.03),
    v2.RandomApply([v2.GaussianBlur(5, (0.1, 1.5))], p=0.3),
])
to_tensor = v2.Compose([v2.Resize((SIZE, SIZE)), v2.ToImage(), v2.ToDtype(torch.float32, scale=True)])
mean, std = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1), torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)


class Train(torch.utils.data.Dataset):
    def __len__(self):
        return len(train)

    def __getitem__(self, i):
        path, tile, stand = train[i]
        turn = random.randrange(4)
        # rotate(90·k) is counterclockwise, so k clockwise quarter turns make it upright again.
        return to_tensor(jitter(Image.open(path).convert("RGB").rotate(90 * turn))), tile, turn, stand


class Values(torch.nn.Module):
    """Normalizes, as Core ML gets pixels in 0…1, and returns the tile, orientation, and table-or-rack logits."""

    def __init__(self, weights=None):
        super().__init__()
        self.net = torchvision.models.mobilenet_v3_large(weights=weights)
        self.net.classifier = torch.nn.Sequential(
            torch.nn.Linear(self.net.classifier[0].in_features, 512), torch.nn.Hardswish(), torch.nn.Dropout(0.2),
            torch.nn.Linear(512, len(tiles) + 4 + 2))
        self.register_buffer("mean", mean)
        self.register_buffer("std", std)

    def forward(self, x):
        out = self.net((x - self.mean) / self.std)
        n = len(tiles)
        return out[:, :n], out[:, n:n + 4], out[:, n + 4:]


def held_out():
    test = []
    for name in (captures / "boxed.txt").read_text().split():
        if not held(name):
            continue
        labels = [t for t in json.loads((captures / f"{name}.tiles.json").read_text())
                  if t.get("confirmed") and t.get("tile") in index]
        image = Image.open(captures / f"{name}.png").convert("RGB") if labels else None
        for t in labels:
            x, y, w, h = t["frame"]
            c = image.crop((max(0, round(x)), max(0, round(y)), min(image.width, round(x + w)), min(image.height, round(y + h))))
            stand = int(bool(t.get("rack")))
            if min(c.size) >= 8:
                test.append((to_tensor(c), index[t["tile"]], t.get("turns", 0), stand))
    return test


@torch.no_grad()
def predict(model, images, device):
    model.eval()
    out = [model(torch.stack(images[i:i + 256]).to(device)) for i in range(0, len(images), 256)]
    model.train()
    return tuple(torch.cat([o[j] for o in out]).cpu() for j in range(3))


def convert(model):
    import coremltools as ct

    class Joint(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.model = model

        def forward(self, x):
            tile, turn, stand = self.model(x)
            joint = tile.softmax(1)[:, :, None, None] * turn.softmax(1)[:, None, :, None] * stand.softmax(1)[:, None, None, :]
            return joint.reshape(1, -1)

    traced = torch.jit.trace(Joint().cpu().eval(), torch.rand(1, 3, SIZE, SIZE))
    ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, SIZE, SIZE), scale=1 / 255)],
        classifier_config=ct.ClassifierConfig([f"{t}@{k}{'@rack' * s}" for t in tiles for k in range(4) for s in range(2)]),
        minimum_deployment_target=ct.target.iOS17,
    ).save(captures / "Values.mlpackage")


if __name__ == "__main__":
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    test = held_out()
    model = Values(weights="IMAGENET1K_V2").to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3, weight_decay=1e-4)
    loader = torch.utils.data.DataLoader(Train(), batch_size=128, shuffle=True, num_workers=8, persistent_workers=True)
    loss = torch.nn.CrossEntropyLoss(label_smoothing=0.05, ignore_index=-1)
    # Table tiles outnumber the rack's several to one, and alone taught it that every tile lies flat.
    counts = [max(1, sum(s == k for *_, s in train)) for k in (0, 1)]
    stood = torch.nn.CrossEntropyLoss(weight=torch.tensor([1 / c for c in counts]).to(device) * sum(counts) / 2,
                                      label_smoothing=0.05, ignore_index=-1)
    start, total, epoch = time.time(), float(os.environ.get("MINUTES", 5)) * 60, 0
    while time.time() - start < total:
        for x, tile, turn, stand in loader:
            for g in optimizer.param_groups:
                g["lr"] = 1e-3 * max(0.02, 1 - (time.time() - start) / total)
            t, k, s = model(x.to(device))
            l = loss(t, tile.to(device)) + loss(k, turn.to(device))
            if (stand >= 0).any():
                l = l + stood(s, stand.to(device))
            optimizer.zero_grad()
            l.backward()
            optimizer.step()
            if time.time() - start > total:
                break
        epoch += 1
        t, k, s = predict(model, [x for x, *_ in test], device)
        right = sum(a == b for a, (_, b, _, _) in zip(t.argmax(1).tolist(), test))
        turned = sum(a == c for a, (_, _, c, _) in zip(k.argmax(1).tolist(), test))
        known = [(a, d) for a, (*_, d) in zip(s.argmax(1).tolist(), test) if d >= 0]
        racks = [a for a, d in known if d == 1]
        print(f"epoch {epoch} {time.time() - start:.0f}s: held out, {right} of {len(test)} tiles right, {turned} orientations, "
              f"{sum(a == d for a, d in known)} of {len(known)} rack or table ({sum(racks)} of {len(racks)} rack)", flush=True)

    outside = sorted((crops / "outside").glob("*/*.jpg"))
    _, k, _ = predict(model, [to_tensor(Image.open(p).convert("RGB")) for p in outside], device)
    share, turn = k.softmax(1).max(1)
    with open(crops / "outside.turns", "w") as f:
        for p, t, s in zip(outside, turn.tolist(), share.tolist()):
            print(f"{p.parent.name}/{p.name}", t, f"{s:.3f}", sep="\t", file=f)
    convert(model.cpu())
