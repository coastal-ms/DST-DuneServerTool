// Reads the repo CHANGELOG.md at build time and exposes its raw content.
// Rendered on /changelog via Astro's built-in markdown.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const CHANGELOG_PATH = join(__dirname, "..", "..", "..", "CHANGELOG.md");

export async function getChangelog(): Promise<string> {
  try {
    return await readFile(CHANGELOG_PATH, "utf8");
  } catch (err) {
    console.warn("[changelog] read failed:", err);
    return "# Changelog\n\n_Changelog could not be loaded._";
  }
}
