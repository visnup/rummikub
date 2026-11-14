import json
import math
from collections import Counter
from pathlib import Path


def group(captures: Path, name: str) -> str:
    """The recording a capture was taken during, else the capture itself. A recording's frames show the same tiles, so
    they go together."""
    notes = captures / f"{name}.json"
    return (json.loads(notes.read_text()).get("recording") if notes.exists() else None) or name


def held(captures: Path, name: str) -> bool:
    """Whether a capture is held out of training to score on, the same as Finder.isHeldOut: a fifth of them, by a
    hash of its group's name, so a recording's frames are held out together."""
    h = 14695981039346656037
    for b in group(captures, name).encode():
        h = ((h ^ b) * 1099511628211) % 2**64
    return h % 5 == 0


def weights(captures: Path, names: list[str]) -> dict[str, float]:
    """How often to draw each capture in training: a recording's n frames 1/√n each, so 36 count as 6 captures."""
    groups = {n: group(captures, n) for n in names}
    counts = Counter(groups.values())
    return {n: 1 / math.sqrt(counts[g]) for n, g in groups.items()}
