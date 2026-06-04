// Copies the repo's docs/img/*.png screenshots into site/public/screenshots/
// so they can be served as static assets at /screenshots/*.png.
// Runs before `dev` and `build` via npm hooks.

import { readdir, mkdir, copyFile, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC = join(__dirname, "..", "..", "docs", "img");
const DEST = join(__dirname, "..", "public", "screenshots");

async function main() {
  try {
    await stat(SRC);
  } catch {
    console.warn(`[sync-images] source dir missing: ${SRC} — skipping.`);
    return;
  }
  await mkdir(DEST, { recursive: true });
  const entries = await readdir(SRC, { withFileTypes: true });
  let copied = 0;
  for (const e of entries) {
    if (!e.isFile()) continue;
    if (!/\.(png|jpe?g|webp|gif|svg)$/i.test(e.name)) continue;
    await copyFile(join(SRC, e.name), join(DEST, e.name));
    copied++;
  }
  console.log(`[sync-images] copied ${copied} file(s) → ${DEST}`);
}

main().catch((err) => {
  console.error("[sync-images] failed:", err);
  process.exit(1);
});
