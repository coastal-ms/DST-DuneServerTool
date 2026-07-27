// Reads the repo CHANGELOG.md at build time and exposes its raw content.
// Rendered on /changelog via Astro's built-in markdown.

import { readFile } from "node:fs/promises";
import { join } from "node:path";

const CHANGELOG_PATH = join(process.cwd(), "..", "CHANGELOG.md");

export async function getChangelog(): Promise<string> {
  try {
    return await readFile(CHANGELOG_PATH, "utf8");
  } catch (err) {
    console.warn("[changelog] read failed:", err);
    return "# Changelog\n\n_Changelog could not be loaded._";
  }
}
