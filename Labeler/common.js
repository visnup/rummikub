const valid = /^([kbor](1[0-3]|[1-9])|j)$/;
/** What typing sets, confirmed: a tile, or `?` for one too cut off or blurred to read. */
const typedFields = typed => typed === "?" || valid.test(typed) ? { tile: typed, confirmed: true } : null;
const ink = { k: "#111", b: "#0a62d0", o: "#e07800", r: "#d0102a", j: "#d0102a" };
/** Which way is up, by orientation: the quarter turns clockwise that make the tile upright. */
const arrows = ["↑", "←", "↓", "→"];
const turn = (turns, key) => ((turns || 0) + (key === "ArrowLeft" ? 1 : 3)) % 4;
/** A tile's value and orientation, as both pages label it. */
const label = t => `${t.tile}${arrows[t.turns || 0]}`;
/** The switch at the top of the list between the two pages, with this one current. */
const pages = here => {
  const el = document.createElement("div");
  el.className = "pages";
  for (const [href, text] of [["/captures", "Captures"], ["/values", "Values"]]) {
    el.append(Object.assign(document.createElement("a"), { href, textContent: text, className: href === here ? "current" : "" }));
  }
  return el;
};
/** Turns the typed box red a moment, for a key that does nothing. */
const flash = () => { const el = document.getElementById("typed"); el.style.background = "#d33"; setTimeout(() => el.style.background = "#111", 300); };
