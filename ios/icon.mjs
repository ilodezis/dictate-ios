// Renders the iOS app icon: a white waveform on the coral-to-magenta gradient of the macOS icon,
// plus the dark (coloured glyph on transparent) and tinted (white glyph on transparent) variants.
// Run: npm i --no-save sharp && node ios/icon.mjs
import sharp from "sharp";
import { fileURLToPath } from "node:url";

const S = 1024;
const out = process.env.ICON_OUT ?? fileURLToPath(new URL("App/Assets.xcassets/AppIcon.appiconset/", import.meta.url));

function bars(fill) {
  const heights = [230, 470, 660, 400, 210], w = 96, gap = 56;
  let x = S / 2 - (heights.length * w + (heights.length - 1) * gap) / 2;
  return heights.map((h) => {
    const bar = `<rect x="${x}" y="${S / 2 - h / 2}" width="${w}" height="${h}" rx="${w / 2}" fill="${fill}"/>`;
    x += w + gap;
    return bar;
  }).join("");
}

const gradient = (id, top, bottom) =>
  `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="0" y1="150" x2="0" y2="874">` +
  `<stop offset="0" stop-color="${top}"/><stop offset="1" stop-color="${bottom}"/></linearGradient>`;

const svg = (body) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="${S}" height="${S}"><defs>` +
  gradient("light", "#FF7A54", "#D62978") + gradient("dark", "#FF8A5C", "#F0388A") +
  `</defs>${body}</svg>`;

const variants = {
  // Full bleed, no alpha: iOS masks it and rejects transparency on the default icon.
  "icon.png": svg(`<rect width="${S}" height="${S}" fill="url(#light)"/>${bars("#FFFFFF")}`),
  // iOS puts its own dark backdrop behind these two.
  "icon-dark.png": svg(bars("url(#dark)")),
  "icon-tinted.png": svg(bars("#FFFFFF")),
};

for (const [name, source] of Object.entries(variants)) {
  let image = sharp(Buffer.from(source));
  if (name === "icon.png") image = image.flatten({ background: "#D62978" }).removeAlpha();
  await image.png().toFile(out + name);
  console.log(name);
}
