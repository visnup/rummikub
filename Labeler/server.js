/** The labeler's API on Vite's dev server: the pages' reads and saves of Captures/, crops for the values page, and
 * captures the app pushes. */
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, appendFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import sharp from "sharp";

const captures = resolve(import.meta.dirname, "../Captures");
// Captures whose boxes have all been checked: one around every tile and nothing else.
const boxed = join(captures, "boxed.txt");
// Done captures looked over again where the models disagree with them, as `check` lists in .check.json.
const checked = join(captures, "checked.txt");
// Captures deleted, which the app's pushes don't bring back.
const removed = join(captures, ".removed");
const numbered = join(captures, "ids.txt");

// What each layout writes as the truth, as the app's Game.Layout does.
const melds = {
  "Full set": [..."kkbboorr"].map(c => Array.from({ length: 13 }, (_, i) => `${c}${i + 1}`).join(" ")).concat("j j"),
  "No tiles": [],
};

/** A capture's file, if it's inside Captures/. */
const inside = (name, suffix) => {
  const path = resolve(captures, name + suffix);
  return path.startsWith(captures + "/") ? path : null;
};
const read = path => existsSync(path) ? readFileSync(path, "utf8") : null;
const readJSON = (path, otherwise) => existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : otherwise;
const sorted = v => Array.isArray(v) ? v.map(sorted)
  : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map(k => [k, sorted(v[k])])) : v;
const writeJSON = (path, v) => writeFileSync(path, JSON.stringify(sorted(v), null, 2) + "\n");
const lines = list => list.map(l => `${l}\n`).join("");
const names = path => new Set((read(path) ?? "").split(/\s+/).filter(Boolean));
const without = (path, ext) => path.slice(0, -ext.length);

const pngs = () => ["", "unlabeled/"].flatMap(dir => {
  const full = join(captures, dir);
  return existsSync(full) ? readdirSync(full).filter(f => f.endsWith(".png")).sort().map(f => join(full, f)) : [];
});
const stem = png => basename(png, ".png");
const nameOf = png => without(relative(captures, png), ".png");
const info = png => readJSON(without(png, ".png") + ".json", {});

/** The true tiles, or null when they're unknown: an "As read" capture in unlabeled/, or with none written. */
function truth(png) {
  const txt = read(without(png, ".png") + ".txt");
  if (txt === null) return null;
  const tiles = txt.split("\n").slice(1).join(" ").split(/\s+/).filter(Boolean);
  const layout = info(png).layout;
  return (layout === "As read" || layout == null) && (basename(dirname(png)) === "unlabeled" || !tiles.length) ? null : tiles;
}

/** A number for each capture to talk about it by, from 1 in the order first seen, never reused. */
function ids(photos) {
  const known = (read(numbered) ?? "").split(/\s+/).filter(Boolean), seen = new Set(known);
  const added = [...new Set(photos.map(stem))].filter(s => !seen.has(s)).sort();
  if (added.length) {
    known.push(...added);
    writeFileSync(numbered, lines(known));
  }
  return Object.fromEntries(known.map((n, i) => [n, i + 1]));
}

function summary(png, number, check, done, looked) {
  const name = nameOf(png), tiles = readJSON(without(png, ".png") + ".tiles.json", []), notes = info(png);
  return {
    id: number, name, truth: truth(png), layout: notes.layout ?? null,
    tags: (notes.notes || "").split(/\s+/).filter(Boolean), boxes: tiles.length, racks: tiles.filter(t => t.rack).length, confirmed: tiles.filter(t => t.confirmed).length, boxed: done.has(name),
    check: check[name] ?? null, checked: looked.has(name), modified: statSync(png).mtimeMs / 1000,
  };
}

/** Every tile with a value, done captures or not, for the values page. */
function values() {
  const photos = pngs(), number = ids(photos);
  return photos.flatMap(png => {
    const name = nameOf(png);
    return readJSON(without(png, ".png") + ".tiles.json", []).filter(t => (t.tile ?? "?") !== "?").map(t => ({
      name, id: number[stem(png)] ?? null, frame: t.frame, tile: t.tile, turns: t.turns ?? 0,
      confirmed: !!t.confirmed, odds: t.odds ?? null, rack: !!t.rack,
    }));
  });
}

// The last few photos decoded, since the values page asks for many crops of each.
const decoded = new Map();
function photo(path) {
  if (!decoded.has(path)) {
    decoded.set(path, sharp(path).removeAlpha().raw().toBuffer({ resolveWithObject: true }));
    if (decoded.size > 6) decoded.delete(decoded.keys().next().value);
  }
  return decoded.get(path);
}

/** A tile's box from its capture, with a little around it, black past the photo's edge. */
async function crop(path, [x, y, w, h]) {
  const { data, info: { width, height, channels } } = await photo(path), m = Math.max(w, h) * 0.15;
  const [l, t, r, b] = [x - m, y - m, x + w + m, y + h + m].map(Math.round);
  const left = Math.max(l, 0), top = Math.max(t, 0), right = Math.min(r, width), bottom = Math.min(b, height);
  return sharp(data, { raw: { width, height, channels } })
    .extract({ left, top, width: right - left, height: bottom - top })
    .extend({ left: left - l, top: top - t, right: r - right, bottom: b - bottom, background: "black" })
    .resize(192, 192, { fit: "inside", withoutEnlargement: true })
    .jpeg({ quality: 85 }).toBuffer();
}

/** Changes tiles, each the one at its capture's "frame". Each capture's file is written once. */
function apply(changes) {
  const byName = Map.groupBy(changes, c => c.name);
  let changed = 0;
  for (const [name, fields] of byName) {
    const path = inside(name, ".tiles.json");
    if (!path || !existsSync(path)) continue;
    const tiles = readJSON(path);
    for (const { name: _, frame, ...f } of fields) {
      const tile = tiles.find(t => t.frame.every((v, i) => v === frame[i]));
      if (!tile) continue;
      Object.assign(tile, f, { source: "hand" });
      delete tile.odds;
      if (tile.rack === false) delete tile.rack;
      changed++;
    }
    writeJSON(path, tiles);
  }
  return changed;
}

const body = req => new Promise((done, fail) => {
  const chunks = [];
  req.on("data", c => chunks.push(c)).on("end", () => done(Buffer.concat(chunks))).on("error", fail);
});
/** Compressed, which matters over the VPN: /api/values is 2.6 MB as JSON. Brotli where the browser takes it, but
 * browsers offer it only over HTTPS, so over plain HTTP it's gzip. */
const json = (res, v) => {
  res.setHeader("Content-Type", "application/json");
  const text = JSON.stringify(v), accepts = res.req.headers["accept-encoding"] ?? "";
  if (text.length < 1024) return res.end(text);
  if (/\bbr\b/.test(accepts)) {
    res.setHeader("Content-Encoding", "br");
    return res.end(brotliCompressSync(text, { params: { [constants.BROTLI_PARAM_QUALITY]: 5 } }));
  }
  if (/\bgzip\b/.test(accepts)) {
    res.setHeader("Content-Encoding", "gzip");
    return res.end(gzipSync(text));
  }
  res.end(text);
};

/** A capture's photo as WebP, made once and kept in .web/ until the PNG changes: 290 kB against the PNG's 2.6 MB. */
const web = join(captures, ".web");
async function webp(png) {
  const path = join(web, relative(captures, png).replaceAll("/", "-").replace(/\.png$/, ".webp"));
  if (!existsSync(path) || statSync(path).mtimeMs < statSync(png).mtimeMs) {
    mkdirSync(web, { recursive: true });
    await sharp(png).webp({ quality: 90 }).toFile(path);
  }
  return readFileSync(path);
}
const fail = (res, status) => {
  res.statusCode = status;
  res.end();
};

async function api(req, res, path, query) {
  const { method } = req, rest = prefix => decodeURIComponent(path.slice(prefix.length));
  if (method === "GET" && path === "/api/values") return json(res, values());
  // Each value's held-out errors, as `score` last wrote them.
  if (method === "GET" && path === "/api/score") return json(res, readJSON(join(captures, ".score.json"), {}));
  if (method === "GET" && path === "/api/captures") {
    const photos = pngs(), number = ids(photos), check = readJSON(join(captures, ".check.json"), {});
    const done = names(boxed), looked = names(checked);
    return json(res, photos.map(p => summary(p, number[stem(p)], check, done, looked)));
  }
  if (method === "GET" && path.startsWith("/api/crop/")) {
    const png = inside(rest("/api/crop/"), ".png");
    if (!png || !existsSync(png)) return fail(res, 404);
    res.setHeader("Content-Type", "image/jpeg");
    // A capture's pixels never change, and the box is in the URL.
    res.setHeader("Cache-Control", "max-age=31536000, immutable");
    return res.end(await crop(png, query.get("f").split(",").map(Number)));
  }
  if (path.startsWith("/api/tiles/")) {
    const file = inside(rest("/api/tiles/"), ".tiles.json");
    if (!file) return fail(res, 403);
    if (method === "GET") return json(res, readJSON(file, []));
    if (method === "PUT") {
      const tiles = JSON.parse(await body(req));
      writeJSON(file, tiles);
      return json(res, { saved: tiles.length });
    }
  }
  if (method === "POST" && path === "/api/tiles") return json(res, { changed: apply(JSON.parse(await body(req))) });

  // Sets what a capture was meant to show: "Full set" and "No tiles" write their truth, and "As read" clears it, to
  // be written by hand.
  if (method === "POST" && path.startsWith("/api/layout/")) {
    const png = inside(rest("/api/layout/"), ".png"), layout = JSON.parse(await body(req));
    if (!png || !existsSync(png) || !(layout in melds || layout === "As read")) return fail(res, 400);
    const base = without(png, ".png");
    writeJSON(base + ".json", { ...info(png), layout });
    writeFileSync(base + ".txt", lines([(read(base + ".txt") ?? "").split("\n")[0], ...melds[layout] ?? []]));
    return json(res, { layout, truth: truth(png) });
  }
  // Marks a capture's boxes done, or looked over where the models disagree, or not (?done=0).
  const listed = { "/api/boxed/": boxed, "/api/checked/": checked };
  for (const [prefix, file] of Object.entries(listed)) {
    if (method !== "POST" || !path.startsWith(prefix)) continue;
    const name = rest(prefix), all = names(file);
    query.get("done") === "0" ? all.delete(name) : all.add(name);
    writeFileSync(file, lines([...all].sort()));
    return json(res, { [prefix.slice(5, -1)]: all.has(name) });
  }

  // Deletes a capture: its files go to the Trash, and .removed keeps the app from pushing it again.
  if (method === "DELETE" && path.startsWith("/api/capture/")) {
    const name = rest("/api/capture/");
    if (!/^(unlabeled\/)?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(name)) return fail(res, 400);
    const time = basename(name), dir = dirname(join(captures, name));
    const recording = readJSON(join(dir, `${time}.json`), {}).recording;
    for (const f of readdirSync(dir).filter(f => f.startsWith(time + "."))) renameSync(join(dir, f), join(homedir(), ".Trash", f));
    appendFileSync(removed, lines(["png", "txt", "json"].map(ext => `${time}.${ext}`)));
    // A recording's log goes with the last of its captures.
    const log = `${recording}.jsonl`;
    if (recording && existsSync(join(captures, log)) &&
        ![captures, join(captures, "unlabeled")].some(d => readdirSync(d).some(f => f.endsWith("Z.json") && readJSON(join(d, f), {}).recording === recording))) {
      renameSync(join(captures, log), join(homedir(), ".Trash", log));
      appendFileSync(removed, lines([log]));
    }
    for (const file of [boxed, checked]) {
      const all = names(file);
      all.delete(name);
      writeFileSync(file, lines([...all].sort()));
    }
    return json(res, { deleted: name });
  }
  // A capture file pushed from the app, or a recording's log (.jsonl). One already here is kept. Once a capture's photo arrives, after its notes, an
  // "As read" one goes to unlabeled/ until its truth is written.
  if (method === "PUT" && path.startsWith("/api/capture/")) {
    const name = rest("/api/capture/");
    if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\.(png|txt|json|jsonl)$/.test(name)) return fail(res, 400);
    const data = await body(req);
    if (names(removed).has(name) || existsSync(join(captures, name)) || existsSync(join(captures, "unlabeled", name)))
      return json(res, { kept: name });
    writeFileSync(join(captures, name), data);
    const time = name.slice(0, name.lastIndexOf("."));
    if (name.endsWith(".png") && readJSON(join(captures, time + ".json"), {}).layout === "As read")
      for (const f of readdirSync(captures).filter(f => f.startsWith(time + ".")))
        renameSync(join(captures, f), join(captures, "unlabeled", f));
    return json(res, { saved: name });
  }
  fail(res, 404);
}

export default () => ({
  name: "labeler",
  configureServer(server) {
    server.middlewares.use(async (req, res, next) => {
      const url = new URL(req.url, "http://labeler"), path = url.pathname;
      try {
        if (path === "/") {
          res.writeHead(302, { Location: "/captures" });
          return res.end();
        }
        // /captures/48 is capture #48 in the labeler, /values/r6 the r6s in the values page.
        if (/^\/captures(\/\d+)?$/.test(path)) req.url = "/captures.html";
        else if (/^\/values(\/\w+)?$/.test(path)) req.url = "/values.html";
        else if (path.startsWith("/photos/") && path.endsWith(".webp")) {
          const png = inside(decodeURIComponent(path.slice("/photos/".length, -".webp".length)), ".png");
          if (!png || !existsSync(png)) return fail(res, 404);
          res.setHeader("Content-Type", "image/webp");
          res.setHeader("Cache-Control", "max-age=31536000, immutable");
          return res.end(await webp(png));
        } else if (path.startsWith("/api/")) return await api(req, res, path, url.searchParams);
        next();
      } catch (e) {
        next(e);
      }
    });
  },
});
