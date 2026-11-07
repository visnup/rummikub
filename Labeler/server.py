# /// script
# requires-python = ">=3.12"
# ///
"""Serves the labeling page for Captures/ and saves each capture's <name>.tiles.json: uv run Labeler/server.py"""

import json
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
        "confirmed": sum(1 for t in tiles if t.get("confirmed")),
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
        path = self.labels() if self.path.startswith("/api/tiles/") else None
        if path is None:
            return self.send_error(403)
        tiles = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        path.write_text(json.dumps(tiles, indent=2, sort_keys=True) + "\n")
        self.send_json({"saved": len(tiles)})

    def translate_path(self, path):
        """/captures/… from Captures/, anything else from beside this file, and nothing outside either."""
        path = unquote(path.split("?")[0])
        base = captures if path.startswith("/captures/") else root
        full = (base / path.removeprefix("/captures").lstrip("/")).resolve()
        return str(full) if full.is_relative_to(base.resolve()) else str(root / "missing")


ThreadingHTTPServer(("localhost", 8765), Handler).serve_forever()
