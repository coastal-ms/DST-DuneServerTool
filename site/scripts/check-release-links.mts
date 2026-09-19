import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const releasesUrl = "https://github.com/coastal-ms/DST-DuneServerTool/releases";
const [downloadButton, baseLayout, releasesPage] = await Promise.all([
  readFile(new URL("../src/components/DownloadButton.astro", import.meta.url), "utf8"),
  readFile(new URL("../src/layouts/Base.astro", import.meta.url), "utf8"),
  readFile(new URL("../src/pages/testing.astro", import.meta.url), "utf8"),
]);

assert.match(downloadButton, new RegExp(`const releasesUrl = "${releasesUrl}"`));
assert.match(downloadButton, /href=\{releasesUrl\}/);
assert.match(downloadButton, /Download for Windows/);
assert.match(downloadButton, /View latest release notes →/);
assert.doesNotMatch(downloadButton, /getLatestRelease|formatDisplayVersion|versionLabel/);
assert.doesNotMatch(downloadButton, /releases\/tag\/v|releases\/download\/v/);

assert.match(baseLayout, /\{ href: "testing", label: "Latest Releases" \}/);
assert.match(releasesPage, /title="Latest Releases — DST"/);

console.log("Release navigation checks passed.");
