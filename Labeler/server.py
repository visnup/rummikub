# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow"]
# ///
"""Serves the labeler's pages for Captures/, saves each capture's <name>.tiles.json, and takes captures the app pushes:
uv run Labeler/server.py"""

import io
import json
import re
import threading
from functools import lru_cache
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote

from PIL import Image

root = Path(__file__).parent
captures = root.parent / "Captures"


def inside(name: str, suffix: str) -> Path | None:
    """A capture's file, if it's inside Captures/."""
    path = (captures / (name + suffix)).resolve()
    return path if path.is_relative_to(captures.resolve()) else None


def pngs() -> list[Path]:
    return sorted(captures.glob("*.png")) + sorted(captures.glob("unlabeled/*.png"))


def write_tiles(path: Path, tiles: list[dict]):
    path.write_text(json.dumps(tiles, indent=2, sort_keys=True) + "\n")


def info(png: Path) -> dict:
    notes = png.with_suffix(".json")
    return json.loads(notes.read_text()) if notes.exists() else {}


def layout(png: Path) -> str | None:
    return info(png).get("layout")


def looking(png: Path) -> str | None:
    """"rack" or "table", the first word of the .txt."""
    txt = png.with_suffix(".txt")
    words = txt.read_text().split(maxsplit=1) if txt.exists() else []
    return words[0] if words else None


def truth(png: Path) -> list[str] | None:
    """The true tiles, or None when they're unknown: an "As read" capture in unlabeled/, or with none written."""
    txt = png.with_suffix(".txt")
    if not txt.exists():
        return None
    tiles = " ".join(txt.read_text().splitlines()[1:]).split()
    return None if layout(png) in ("As read", None) and (png.parent.name == "unlabeled" or not tiles) else tiles


# What each layout writes as the truth, as the app's Game.Layout does.
melds = {"Full set": [" ".join(f"{c}{v}" for v in range(1, 14)) for c in "kkbboorr"] + ["j j"], "No tiles": []}


# Captures whose boxes have all been checked: one around every tile and nothing else.
boxed = captures / "boxed.txt"
# Done captures looked over again where the models disagree with them, as `check` lists in .check.json.
checked = captures / "checked.txt"
# Captures deleted, which the app's pushes don't bring back.
removed = captures / ".removed"


def names(path: Path) -> set[str]:
    return set(path.read_text().split()) if path.exists() else set()


def disagreements() -> dict:
    path = captures / ".check.json"
    return json.loads(path.read_text()) if path.exists() else {}


numbered = captures / "ids.txt"
# The values page saves without waiting, so two saves, from it or the capture page, can reach the same file at once.
writing = threading.Lock()


@lru_cache(maxsize=6)
def photo(path: Path) -> Image.Image:
    image = Image.open(path).convert("RGB")
    image.load()
    return image


def values() -> list[dict]:
    """Every tile with a value, done captures or not, for the values page."""
    photos = pngs()
    number = ids(photos)
    out = []
    for png in photos:
        name = str(png.relative_to(captures).with_suffix(""))
        path = png.with_suffix(".tiles.json")
        for t in json.loads(path.read_text()) if path.exists() else []:
            if t.get("tile", "?") != "?":
                out.append({"name": name, "id": number.get(name.removeprefix("unlabeled/")), "frame": t["frame"],
                            "tile": t["tile"], "turns": t.get("turns", 0), "confirmed": bool(t.get("confirmed")),
                            "odds": t.get("odds")})
    return out


def ids(pngs: list[Path]) -> dict[str, int]:
    """A number for each capture to talk about it by, from 1 in the order first seen, never reused."""
    known = numbered.read_text().split() if numbered.exists() else []
    new = sorted({p.stem for p in pngs} - set(known))
    if new:
        known += new
        numbered.write_text("".join(f"{n}\n" for n in known))
    return {n: i + 1 for i, n in enumerate(known)}


def summary(png: Path, number: int, check: dict, done: set[str], looked: set[str]) -> dict:
    name = str(png.relative_to(captures).with_suffix(""))
    tiles = json.loads(png.with_suffix(".tiles.json").read_text()) if png.with_suffix(".tiles.json").exists() else []
    return {
        "id": number,
        "name": name,
        "truth": truth(png),
        "layout": layout(png),
        "looking": looking(png),
        "tags": (info(png).get("notes") or "").split(),
        "boxes": len(tiles),
        "boxed": name in done,
        "check": check.get(name),
        "checked": name in looked,
        "modified": png.stat().st_mtime,
    }


class Handler(SimpleHTTPRequestHandler):
    def send_json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # /captures/48 is capture #48 in the labeler, /values/r6 the r6s in the values page.
        if self.path == "/":
            self.send_response(302)
            self.send_header("Location", "/captures")
            return self.end_headers()
        if re.fullmatch(r"/captures(/\d+)?", self.path):
            self.path = "/captures.html"
        if re.fullmatch(r"/values(/\w+)?", self.path):
            self.path = "/values.html"
        if self.path == "/api/values":
            return self.send_json(values())
        if self.path.startswith("/api/crop/"):
            return self.crop()
        if self.path == "/api/captures":
            photos = pngs()
            number, check, done, looked = ids(photos), disagreements(), names(boxed), names(checked)
            return self.send_json([summary(p, number[p.stem], check, done, looked) for p in photos])
        if self.path.startswith("/api/tiles/"):
            path = inside(unquote(self.path.removeprefix("/api/tiles/")), ".tiles.json")
            if path is None:
                return self.send_error(403)
            return self.send_json(json.loads(path.read_text()) if path.exists() else [])
        return super().do_GET()

    def crop(self):
        """A tile's box from its capture, with a little around it: GET /api/crop/<name>?f=x,y,w,h."""
        name, _, query = self.path.removeprefix("/api/crop/").partition("?")
        path = inside(unquote(name), ".png")
        if path is None or not path.exists():
            return self.send_error(404)
        x, y, w, h = (float(v) for v in parse_qs(query)["f"][0].split(","))
        m = max(w, h) * 0.15
        tile = photo(path).crop((round(x - m), round(y - m), round(x + w + m), round(y + h + m)))
        tile.thumbnail((192, 192))
        out = io.BytesIO()
        tile.save(out, "JPEG", quality=85)
        body = out.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "image/jpeg")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=3600")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        """Marks a capture's boxes done, or looked over where the models disagree, or not: POST
        /api/boxed/<name>?done=0, /api/checked/<name>. Or changes tiles, as `change` says, or a layout."""
        if self.path == "/api/tiles":
            return self.change()
        if self.path.startswith("/api/layout/"):
            return self.relayout()
        if self.path.startswith("/api/looking/"):
            return self.relook()
        kind, _, rest = self.path.removeprefix("/api/").partition("/")
        path = {"boxed": boxed, "checked": checked}.get(kind)
        if path is None:
            return self.send_error(404)
        name, _, query = unquote(rest).partition("?")
        listed = names(path) - {name} if query == "done=0" else names(path) | {name}
        path.write_text("".join(f"{n}\n" for n in sorted(listed)))
        self.send_json({kind: name in listed})

    def do_PUT(self):
        if self.path.startswith("/api/capture/"):
            return self.receive()
        path = inside(unquote(self.path.removeprefix("/api/tiles/")), ".tiles.json") if self.path.startswith("/api/tiles/") else None
        if path is None:
            return self.send_error(403)
        tiles = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with writing:
            write_tiles(path, tiles)
        self.send_json({"saved": len(tiles)})

    def change(self):
        """Changes tiles, each the one at its capture's "frame": POST /api/tiles with [{name, frame, …fields}]. Each
        capture's file is written once."""
        changes = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with writing:
            changed = self.apply(changes)
        self.send_json({"changed": changed})

    @staticmethod
    def apply(changes: list[dict]) -> int:
        by_name = {}
        for c in changes:
            by_name.setdefault(c.pop("name"), []).append(c)
        changed = 0
        for name, fields in by_name.items():
            path = inside(name, ".tiles.json")
            if path is None or not path.exists():
                continue
            tiles = json.loads(path.read_text())
            for f in fields:
                frame = f.pop("frame")
                tile = next((t for t in tiles if t["frame"] == frame), None)
                if tile is not None:
                    tile.update(f, source="hand")
                    tile.pop("odds", None)
                    changed += 1
            write_tiles(path, tiles)
        return changed

    def relayout(self):
        """Sets what a capture was meant to show: POST /api/layout/<name> with "Full set", "No tiles" or "As read".
        The first two write their truth, and "As read" clears it, to be written by hand."""
        png = inside(unquote(self.path.removeprefix("/api/layout/")), ".png")
        new = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if png is None or not png.exists() or new not in (*melds, "As read"):
            return self.send_error(400)
        notes, txt = png.with_suffix(".json"), png.with_suffix(".txt")
        notes.write_text(json.dumps({**info(png), "layout": new}, indent=2, sort_keys=True) + "\n")
        first = txt.read_text().splitlines()[0] if txt.exists() else ""
        txt.write_text("".join(f"{line}\n" for line in [first, *melds.get(new, [])]))
        self.send_json({"layout": new, "truth": truth(png)})

    def relook(self):
        """Sets whether a capture shows the rack or the table: POST /api/looking/<name> with "rack" or "table". It's the
        first word of the .txt, before the tilt, and "looking" in the .json."""
        png = inside(unquote(self.path.removeprefix("/api/looking/")), ".png")
        new = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if png is None or not png.exists() or new not in ("rack", "table"):
            return self.send_error(400)
        txt = png.with_suffix(".txt")
        lines = txt.read_text().splitlines() if txt.exists() else [""]
        lines[0] = " ".join([new, *lines[0].split()[1:]])
        txt.write_text("".join(f"{line}\n" for line in lines))
        png.with_suffix(".json").write_text(json.dumps({**info(png), "looking": new}, indent=2, sort_keys=True) + "\n")
        self.send_json({"looking": new})

    def do_DELETE(self):
        """Deletes a capture: DELETE /api/capture/<name>. Its files go to the Trash, and .removed keeps the app from
        pushing it again."""
        name = unquote(self.path.removeprefix("/api/capture/"))
        if not re.fullmatch(r"(unlabeled/)?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", name):
            return self.send_error(400)
        stem = name.removeprefix("unlabeled/")
        trash = Path.home() / ".Trash"
        for f in (captures / name).parent.glob(stem + ".*"):
            f.rename(trash / f.name)
        with open(removed, "a") as f:
            f.write("".join(f"{stem}.{ext}\n" for ext in ("png", "txt", "json")))
        for path in (boxed, checked):
            path.write_text("".join(f"{n}\n" for n in sorted(names(path) - {name})))
        self.send_json({"deleted": name})

    def receive(self):
        """A capture file pushed from the app: PUT /api/capture/<time>.png|txt|json. One already here is kept. Once a
        capture's photo arrives, after its notes, an "As read" one goes to unlabeled/ until its truth is written."""
        name = unquote(self.path.removeprefix("/api/capture/"))
        if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\.(png|txt|json)", name):
            return self.send_error(400)
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if name in names(removed) or (captures / name).exists() or (captures / "unlabeled" / name).exists():
            return self.send_json({"kept": name})
        (captures / name).write_bytes(body)
        base = captures / name.rsplit(".", 1)[0]
        notes = base.with_suffix(".json")
        if name.endswith(".png") and notes.exists() and json.loads(notes.read_text()).get("layout") == "As read":
            for f in captures.glob(base.name + ".*"):
                f.rename(captures / "unlabeled" / f.name)
        self.send_json({"saved": name})

    def translate_path(self, path):
        """/photos/… from Captures/, anything else from beside this file, and nothing outside either."""
        path = unquote(path.split("?")[0])
        base = captures if path.startswith("/photos/") else root
        full = (base / path.removeprefix("/photos").lstrip("/")).resolve()
        return str(full) if full.is_relative_to(base.resolve()) else str(root / "missing")


# On the local network too, so the phone can push captures.
ThreadingHTTPServer(("", 8765), Handler).serve_forever()
