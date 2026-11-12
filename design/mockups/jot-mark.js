// Locked Jot mark (11 Nov): long-comma j at 10°, medium overhang; colour Cyan & ink.
window.JOT = {
  cyan: "#18CFFF", cyanText: "#007CA6", jOnWhite: "#00A6D6", ink: "#0A1620",
  shape: "M12.5 0 C12.5 32 5 62 -14.66 75.5 A6 6 0 0 1 -19.34 64.5 C-8 58 -3 28 -4.28 11.75 A12.5 12.5 0 1 1 12.5 0 Z",
};
JOT.glyph = (c, dx = 0) => `<g transform="translate(${6.5 + dx} -8) rotate(-10)"><path d="${JOT.shape}" fill="${c}"/></g>`;
JOT.ot = (c) => `<circle cx="48" cy="25" r="19.5" fill="none" stroke="${c}" stroke-width="13"/><path d="M89 -14 V34 a15 15 0 0 0 15 15 h4" fill="none" stroke="${c}" stroke-width="13" stroke-linecap="round"/><path d="M78 4 H106" stroke="${c}" stroke-width="11" stroke-linecap="round"/>`;
JOT.wordmark = (j, ot, h) => `<svg viewBox="-30 -40 144 120" height="${h}" style="display:block">${JOT.glyph(j, -5.95)}${JOT.ot(ot)}</svg>`;
// Quote pair sized into a 100 box (fit after insert with JOT.fit()).
JOT.pair = (c) => `<g class="jot-pair"><g>${JOT.glyph(c)}</g><g transform="translate(31 0)">${JOT.glyph(c)}</g></g>`;
JOT.fit = () => document.querySelectorAll(".jot-pair").forEach((g) => { const b = g.getBBox(), s = Math.min(60 / b.width, 68 / b.height); g.setAttribute("transform", `translate(${20 + (60 - b.width * s) / 2 - b.x * s} ${16 + (68 - b.height * s) / 2 - b.y * s}) scale(${s})`); });
JOT.icon = (mode, size) => mode === "light"
  ? `<svg viewBox="0 0 100 100" width="${size}" height="${size}" style="display:block;border-radius:${size * .225}px"><defs><linearGradient id="jt${size}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#46DAFF"/><stop offset="1" stop-color="#18CFFF"/></linearGradient></defs><rect width="100" height="100" fill="url(#jt${size})"/>${JOT.pair(JOT.ink)}</svg>`
  : `<svg viewBox="0 0 100 100" width="${size}" height="${size}" style="display:block;border-radius:${size * .225}px;background:#000">${JOT.pair(JOT.cyan)}</svg>`;
