import { readFile } from "node:fs/promises";
import { join } from "node:path";

const CHANGELOG_PATH = join(process.cwd(), "..", "CHANGELOG.md");
const DETAILED_RELEASE_MAJOR = 13;
const NUMERIC_RELEASE_HEADING = /^## \[(\d+)\.[^\]]+\][^\r\n]*$/gm;
const LEGACY_SUMMARY = `## Legacy releases (v1-v12)

Earlier releases established DST's core server-management experience and expanded it through successive administration and reliability improvements.

- **v12** — Major expansion of gameplay administration and supporting server workflows.
- **v9-v11** — Iterative additions and refinements across configuration, diagnostics, and operator workflows.
- **v1-v8** — Foundation releases for setup, updates, the desktop app, and core server management.

[View the complete changelog on GitHub](https://github.com/coastal-ms/DST-DuneServerTool/blob/main/CHANGELOG.md) for every legacy release and patch.`;

export function trimChangelogForSite(source: string): string {
  const firstLegacyRelease = [...source.matchAll(NUMERIC_RELEASE_HEADING)].find(
    (match) => Number(match[1]) < DETAILED_RELEASE_MAJOR,
  );

  if (firstLegacyRelease?.index === undefined) {
    return source;
  }

  return `${source.slice(0, firstLegacyRelease.index).trimEnd()}\n\n${LEGACY_SUMMARY}\n`;
}

export async function getChangelog(): Promise<string> {
  try {
    const source = await readFile(CHANGELOG_PATH, "utf8");
    return trimChangelogForSite(source);
  } catch (err) {
    console.warn("[changelog] read failed:", err);
    return "# Changelog\n\n_Changelog could not be loaded._";
  }
}
