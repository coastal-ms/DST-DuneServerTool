import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const [downloadButton, baseLayout, homepage, installPage, releasesPage] = await Promise.all([
  readFile(new URL("../src/components/DownloadButton.astro", import.meta.url), "utf8"),
  readFile(new URL("../src/layouts/Base.astro", import.meta.url), "utf8"),
  readFile(new URL("../src/pages/index.astro", import.meta.url), "utf8"),
  readFile(new URL("../src/pages/install.astro", import.meta.url), "utf8"),
  readFile(new URL("../src/pages/testing.astro", import.meta.url), "utf8"),
]);

assert.ok(
  downloadButton.includes(
    'const releasesUrl = "https://github.com/coastal-ms/DST-DuneServerTool/releases";',
  ),
);
assert.ok(downloadButton.includes('destination?: "installer" | "releases";'));
assert.ok(downloadButton.includes('destination === "installer" ? await getLatestRelease() : null'));
assert.ok(downloadButton.includes('const primaryHref = release?.installerUrl ?? releasesUrl;'));
assert.ok(downloadButton.includes('const notesHref = release?.htmlUrl ?? releasesUrl;'));
assert.ok(downloadButton.includes('"Download latest stable for Windows"'));
assert.ok(downloadButton.includes('"Browse downloads for Windows"'));
assert.ok(downloadButton.includes('"Stable release notes →"'));
assert.ok(downloadButton.includes('"View latest release notes →"'));

assert.ok(homepage.includes('<DownloadButton destination="releases" />'));
assert.doesNotMatch(homepage, /releases\/tag\/v|releases\/download\/v/);
assert.ok(installPage.includes("<DownloadButton />"));

assert.match(baseLayout, /\{ href: "testing", label: "Latest Releases" \}/);
assert.match(releasesPage, /title="Latest Releases — DST"/);

console.log("Release navigation checks passed.");
