// Renders src/og/og-source.svg → public/og.png at the canonical 1200x630
// Open Graph dimensions. Run on-demand (`npm run build:og`); the resulting
// PNG is committed so production builds don't need sharp at build time.

import { readFile, writeFile, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC = join(__dirname, "..", "src", "og", "og-source.svg");
const DEST_DIR = join(__dirname, "..", "public");
const DEST = join(DEST_DIR, "og.png");

const svg = await readFile(SRC);
await mkdir(DEST_DIR, { recursive: true });
await sharp(svg, { density: 192 })
  .resize(1200, 630, { fit: "cover" })
  .png({ quality: 90, compressionLevel: 9 })
  .toFile(DEST);

console.log(`[build-og] wrote ${DEST}`);
