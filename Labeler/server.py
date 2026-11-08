# /// script
# requires-python = ">=3.12"
# ///
"""Serves the labeling page for Captures/, saves each capture's <name>.tiles.json, and takes captures the app pushes:
uv run Labeler/server.py"""

import json
import re
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

root = Path(__file__).parent
captures = root.parent / "Captures"


def truth(png: Path) -> list[str] | None:
    """The true tiles, or None when they're unknown, as for captures in unlabeled/."""
    txt = png.with_suffix(".txt")
    if png.parent.name == "unlabeled" or not txt.exists():
        return None
    return " ".join(txt.read_text().splitlines()[1:]).split()


boxed = captures / "boxed.txt"


def done() -> set[str]:
    """Captures whose boxes have all been checked: one around every tile and nothing else."""
    return set(boxed.read_text().split()) if boxed.exists() else set()


def summary(png: Path) -> dict:
    name = str(png.relative_to(captures).with_suffix(""))
    tiles = json.loads(png.with_suffix(".tiles.json").read_text()) if png.with_suffix(".tiles.json").exists() else []
    return {
        "name": name,
        "truth": truth(png),
        "boxes": len(tiles),
        "boxed": name in done(),
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

    def labels(self) -> Path | None:
        """The labels file the path names, if it's inside Captures/."""
        path = (captures / (unquote(self.path.removeprefix("/api/tiles/")) + ".tiles.json")).resolve()
        return path if path.is_relative_to(captures.resolve()) else None

    def do_GET(self):
        if self.path == "/":
            self.path = "/index.html"
        if self.path == "/api/captures":
            pngs = sorted(captures.glob("*.png")) + sorted(captures.glob("unlabeled/*.png"))
            return self.send_json([s for s in map(summary, pngs) if s["truth"] != []])
        if self.path.startswith("/api/tiles/"):
            path = self.labels()
            if path is None:
                return self.send_error(403)
            return self.send_json(json.loads(path.read_text()) if path.exists() else [])
        return super().do_GET()

    def do_POST(self):
        """Marks a capture's boxes done, or not: POST /api/boxed/<name>?done=0."""
        if not self.path.startswith("/api/boxed/"):
            return self.send_error(404)
        name, _, query = unquote(self.path.removeprefix("/api/boxed/")).partition("?")
        names = done() - {name} if query == "done=0" else done() | {name}
        boxed.write_text("".join(f"{n}\n" for n in sorted(names)))
        self.send_json({"boxed": name in names})

    def do_PUT(self):
        if self.path.startswith("/api/capture/"):
            return self.receive()
        path = self.labels() if self.path.startswith("/api/tiles/") else None
        if path is None:
            return self.send_error(403)
        tiles = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        path.write_text(json.dumps(tiles, indent=2, sort_keys=True) + "\n")
        self.send_json({"saved": len(tiles)})

    def receive(self):
        """A capture file pushed from the app: PUT /api/capture/<time>.png|txt|json. One already here is kept. Once a
        capture's photo arrives, after its notes, an "As read" one goes to unlabeled/ until its truth is written."""
        name = unquote(self.path.removeprefix("/api/capture/"))
        if not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\.(png|txt|json)", name):
            return self.send_error(400)
        body = self.rfile.read(int(self.headers["Content-Length"]))
        removed = (captures / ".removed").read_text().split() if (captures / ".removed").exists() else []
        if name in removed or (captures / name).exists() or (captures / "unlabeled" / name).exists():
            return self.send_json({"kept": name})
        (captures / name).write_bytes(body)
        base = captures / name.rsplit(".", 1)[0]
        notes = base.with_suffix(".json")
        if name.endswith(".png") and notes.exists() and json.loads(notes.read_text()).get("layout") == "As read":
            for f in captures.glob(base.name + ".*"):
                f.rename(captures / "unlabeled" / f.name)
        self.send_json({"saved": name})

    def translate_path(self, path):
        """/captures/… from Captures/, anything else from beside this file, and nothing outside either."""
        path = unquote(path.split("?")[0])
        base = captures if path.startswith("/captures/") else root
        full = (base / path.removeprefix("/captures").lstrip("/")).resolve()
        return str(full) if full.is_relative_to(base.resolve()) else str(root / "missing")


# On the local network too, so the phone can push captures.
ThreadingHTTPServer(("", 8765), Handler).serve_forever()
