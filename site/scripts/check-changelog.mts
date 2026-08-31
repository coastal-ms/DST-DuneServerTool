import assert from "node:assert/strict";
import { trimChangelogForSite } from "../src/lib/changelog.ts";

const source = `# Changelog

Introductory copy.

## [Unreleased]

- Pending change.

## [14.2.0] - 2026-08-20

- Recent release.

## [13.0.0] - 2026-07-30

- Oldest detailed release.

## [12.21.3] - 2026-07-27

- Legacy detail that should be removed.

## [14.0.0] - unexpected ordering

- Content after the cutoff should not return.
`;

const trimmed = trimChangelogForSite(source);
assert.match(trimmed, /^# Changelog/m);
assert.match(trimmed, /^## \[Unreleased\]/m);
assert.match(trimmed, /^## \[14\.2\.0\]/m);
assert.match(trimmed, /^## \[13\.0\.0\]/m);
assert.doesNotMatch(trimmed, /^## \[12\.21\.3\]/m);
assert.doesNotMatch(trimmed, /Legacy detail that should be removed/);
assert.doesNotMatch(trimmed, /unexpected ordering/);
assert.match(trimmed, /^## Legacy releases \(v1-v12\)$/m);
assert.match(
  trimmed,
  /https:\/\/github\.com\/coastal-ms\/DST-DuneServerTool\/blob\/main\/CHANGELOG\.md/,
);

const currentOnly = `# Changelog

## [Unreleased]

## [13.0.0] - 2026-07-30
`;
assert.equal(trimChangelogForSite(currentOnly), currentOnly);

const malformed = `# Changelog

## [Unreleased]

## Legacy archive
`;
assert.equal(trimChangelogForSite(malformed), malformed);

console.log("Changelog transformation checks passed.");
