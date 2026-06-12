# DST test suite

Two suites, one runner.

## Layout

| Suite | Tech | Location | Covers |
|---|---|---|---|
| Server (PowerShell) | Pester 5 | `tests/*.Tests.ps1` | `app/server/lib/*.ps1`, `app/server/routes/*.ps1` |
| WebUI (TypeScript) | Vitest 3 + jsdom | `webui/tests/**/*.test.ts` | `webui/src/api/gameplay.ts` |

## Running

### Everything

```pwsh
pwsh -NoProfile -File Run-AllTests.ps1
```

Flags: `-SkipServer`, `-SkipWebUI`, `-CI` (emits NUnit XML for the server side).

### Server only

```pwsh
pwsh -NoProfile -File tests\Run-Tests.ps1
pwsh -NoProfile -File tests\Run-Tests.ps1 -Path tests\Schema.Tests.ps1
pwsh -NoProfile -File tests\Run-Tests.ps1 -Tag Rmq
```

### WebUI only

```pwsh
cd webui
npm test            # one-shot
npm run test:watch  # watch mode
```

## Prereqs (one-time)

```pwsh
# Pester 5 (PowerShell 7 ships only legacy Pester 3.4)
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber

# Webui deps (vitest, jsdom, testing-library are already in package.json)
cd webui ; npm install
```

## What each file covers

**Server side** (`tests/`):

- `PlayersWrites.Tests.ps1` — pure helpers (`ConvertTo-DuneSqlString`, `ConvertTo-DunePgTextArray`, `Get-DuneSqlAffected`) + `Invoke-DunePlayerUpdateTags` with mocked SQL.
- `Rmq.Tests.ps1` — `Send-DuneRmqServerCommand` + `Send-DuneRmqCourierMessage` envelope construction: Version=2 wrapper, AuthToken, exchange/routing-key embedding, base64 body, MsgId prefix, escape handling.
- `Schema.Tests.ps1` — regression-locks the Phase A schema fixes (no `actors.account_id`, no `fge.id`, no `fge.properties`, `FLevelComponent` indexed as `->1`, `player_state` has no `account_id`, etc.).
- `ServerLoad.Tests.ps1` — smoke: every lib + route file parses and dot-sources cleanly.
- `_TestHelpers.ps1` — shared `Import-DstLib` (promotes lib functions to global so Pester `It` blocks see them) + `Register-DstStubs` (HTTP server shims).
- `Run-Tests.ps1` — Pester runner wrapper.

**Webui side** (`webui/tests/`):

- `api/gameplay.test.ts` — every wrapper in `src/api/gameplay.ts` is fenced against URL drift + body-shape drift by stubbing `fetch` globally and asserting request URL, method, JSON body, and headers (Accept / Content-Type / X-Dune-Token).
- `setup.ts` — registers `@testing-library/jest-dom` matchers and clears `sessionStorage` between tests.

## Adding tests

- **New server endpoint**: add an `It` block in `PlayersWrites.Tests.ps1` (or a sibling) using the `Import-DstLib` pattern from `_TestHelpers.ps1`. Mock `Invoke-DuneSqlQuery` for SQL writes.
- **New webui API wrapper**: add an `it()` in the matching `describe` block in `webui/tests/api/gameplay.test.ts` and assert the URL + body shape.
- **New schema invariant** (e.g., column rename): add a regex assertion in `Schema.Tests.ps1` so future refactors can't silently undo it.

## Gotchas

- Pester 5 evaluates `It` blocks in a different scope from `BeforeAll`. Use the `Import-DstLib` helper (it promotes new functions to global scope) instead of bare `. $libPath`.
- Pester's `Should -Match` does NOT populate `$Matches` in the calling scope. Use `[regex]::Match(...)` if you need captured groups.
- Vitest test files live under `webui/tests/` (NOT `webui/src/`) so `tsc -b` (which is part of `npm run build`) won't typecheck them.
- `Headers` normalizes names to lowercase: assert `headers['content-type']`, not `headers['Content-Type']`.
