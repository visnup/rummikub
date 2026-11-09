const valid = /^([kbor](1[0-3]|[1-9])|j)$/;
const ink = { k: "#111", b: "#0a62d0", o: "#e07800", r: "#d0102a", j: "#d0102a" };
/** Which way is up, by orientation: the quarter turns clockwise that make the tile upright. */
const arrows = ["↑", "←", "↓", "→"];
const turn = (turns, key) => ((turns || 0) + (key === "ArrowLeft" ? 1 : 3)) % 4;
/** A tile's value and orientation, as both pages label it. */
const label = t => `${t.tile}${arrows[t.turns || 0]}`;
/** Turns the typed box red a moment, for a key that does nothing. */
const flash = () => { const el = document.getElementById("typed"); el.style.background = "#d33"; setTimeout(() => el.style.background = "#111", 300); };
