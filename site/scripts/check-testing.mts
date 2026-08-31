import assert from "node:assert/strict";
import {
  getActiveTestReleases,
  getLatestStableRelease,
  type GitHubTestRelease,
} from "../src/lib/testing.ts";

const releases: GitHubTestRelease[] = [
  {
    tag_name: "v15.0.0-test1",
    name: "stable channel mirror",
    prerelease: true,
    published_at: "2026-08-31T03:00:00Z",
    assets: [{ name: "DuneServerSetup.exe", browser_download_url: "https://x/mirror.exe" }],
  },
  {
    tag_name: "v15.0.0-test3",
    prerelease: true,
    published_at: "2026-08-31T02:00:00Z",
    assets: [{ name: "DuneServerSetup.exe", browser_download_url: "https://x/test3.exe" }],
  },
  {
    tag_name: "v14.0.5",
    prerelease: false,
    published_at: "2026-08-31T01:00:00Z",
    assets: [{ name: "DuneServerSetup.exe", browser_download_url: "https://x/stable.exe" }],
  },
  {
    tag_name: "v15.0.0-test2",
    prerelease: true,
    published_at: "2026-08-30T02:00:00Z",
    assets: [{ name: "DuneServerSetup.exe", browser_download_url: "https://x/test2.exe" }],
  },
  {
    tag_name: "v15.0.0-test1-old",
    prerelease: true,
    published_at: "2026-08-29T02:00:00Z",
    assets: [{ name: "DuneServerSetup.exe", browser_download_url: "https://x/test1.exe" }],
  },
];

assert.equal(getLatestStableRelease(releases)?.tag, "v14.0.5");
assert.deepEqual(
  getActiveTestReleases(releases).map((release) => release.tag),
  ["v15.0.0-test3", "v15.0.0-test2"],
);

console.log("Testing release retention checks passed.");
