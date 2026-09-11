import assert from "node:assert/strict";
import {
  getLatestRelease,
  releaseFromEvent,
  type ReleaseEvent,
} from "../src/lib/release.ts";

const stableEvent: ReleaseEvent = {
  tag_name: "v15.0.5",
  html_url: "https://github.com/coastal-ms/DST-DuneServerTool/releases/tag/v15.0.5",
  published_at: "2026-09-10T04:00:00Z",
  prerelease: false,
  assets: [
    {
      name: "DuneServerSetup.exe",
      browser_download_url:
        "https://github.com/coastal-ms/DST-DuneServerTool/releases/download/v15.0.5/DuneServerSetup.exe",
    },
  ],
};

const originalEventName = process.env.GITHUB_EVENT_NAME;
const originalReleaseEvent = process.env.DST_RELEASE_EVENT;
const originalFetch = globalThis.fetch;

process.env.GITHUB_EVENT_NAME = "release";
process.env.DST_RELEASE_EVENT = JSON.stringify(stableEvent);
let fetchCalled = false;
globalThis.fetch = async () => {
  fetchCalled = true;
  throw new Error("stable release builds must not fetch /releases/latest");
};

assert.deepEqual(await getLatestRelease(), {
  tag: "v15.0.5",
  version: "15.0.5",
  htmlUrl: stableEvent.html_url,
  installerUrl: stableEvent.assets?.[0].browser_download_url,
  publishedAt: stableEvent.published_at,
});
assert.equal(fetchCalled, false);

assert.equal(
  releaseFromEvent({
    ...stableEvent,
    tag_name: "v15.0.5-test1",
    prerelease: true,
  }),
  null,
);

process.env.GITHUB_EVENT_NAME = "push";
delete process.env.DST_RELEASE_EVENT;
globalThis.fetch = async () =>
  new Response(
    JSON.stringify({
      tag_name: "v15.0.4",
      html_url:
        "https://github.com/coastal-ms/DST-DuneServerTool/releases/tag/v15.0.4",
      published_at: "2026-09-09T04:00:00Z",
      assets: [
        {
          name: "DuneServerSetup.exe",
          browser_download_url:
            "https://github.com/coastal-ms/DST-DuneServerTool/releases/download/v15.0.4/DuneServerSetup.exe",
        },
      ],
    }),
  );

assert.deepEqual(await getLatestRelease(), {
  tag: "v15.0.4",
  version: "15.0.4",
  htmlUrl:
    "https://github.com/coastal-ms/DST-DuneServerTool/releases/tag/v15.0.4",
  installerUrl:
    "https://github.com/coastal-ms/DST-DuneServerTool/releases/download/v15.0.4/DuneServerSetup.exe",
  publishedAt: "2026-09-09T04:00:00Z",
});

if (originalEventName === undefined) delete process.env.GITHUB_EVENT_NAME;
else process.env.GITHUB_EVENT_NAME = originalEventName;
if (originalReleaseEvent === undefined) delete process.env.DST_RELEASE_EVENT;
else process.env.DST_RELEASE_EVENT = originalReleaseEvent;
globalThis.fetch = originalFetch;

console.log("Release resolution checks passed.");
