# DST Site

Marketing + docs site for the Dune Server Tool. Built with **Astro 7 + React-free islands + Tailwind v4**, designed to deploy as a static site to GitHub Pages (or anywhere that serves a folder of HTML).

This site lives inside the main `DST-DuneServerTool` repo so that:

- Screenshots in `../docs/img/` and the canonical `../CHANGELOG.md` are pulled in at build time — no duplication, the site always reflects what's in the repo.
- The download button uses the triggering stable release payload for release-triggered Pages builds, avoiding the GitHub API's eventual-consistency window; push and manual builds retain the latest-release API fallback.

## Local dev

Requires **Node 22.19+**.

```powershell
cd site
npm ci
npm run dev
```

Then open <http://localhost:4321/DST-DuneServerTool/> (the `/DST-DuneServerTool/` base path matches the eventual GitHub Pages URL; set `SITE_BASE=/` in env if you switch to a custom domain).

The `predev` and `prebuild` hooks copy canonical `../docs/img/*.png` into
`public/screenshots/` (gitignored) and generate full-size and 800px WebP variants
with Sharp. The site serves the responsive WebP images; README keeps the
canonical PNG links.

## Public screenshot provenance

The v15 set contains eleven actual source-run UI captures. They use only
offline, built-in fictional demo, and shipped static states, never personal
servers or successful simulated writes:

| Asset | Captured state |
| --- | --- |
| `command-deck.png` | Optional World view; illustrative globe, no reported maps |
| `server-health.png` | Classic default; no connected VM |
| `dd-seed-maps.png` | Static DD Atlas seed 0; no current server seed |
| `gameplay-admin.png` | Players; the shipped fictional demo roster |
| `blueprints.png` | Empty demo catalogue; import unavailable |
| `solo-mode.png` | First use; no save loaded |
| `game-config.png` | Safety and connection controls; no live INI |
| `commands.png` | Shipped command catalogue; VM-dependent actions unavailable |
| `database.png` | Restore guidance and offline database controls |
| `settings.png` | Unconfigured host; legacy Cloudflare disabled |
| `browser-portal.png` | Phone sign-in, empty fields; no remote session |

Desktop captures are 1600 x 1000, except Classic Server Health at 1600 x 960;
the phone capture is 390 x 844. Captions distinguish these states from field
evidence. The Atlas filename is retained for existing links, but the public
feature name is **DD Atlas**.

To refresh, build `webui` and serve **only** `webui\dist` with an isolated local
static server. Do not use the WebUI Vite dev server: its API proxy can reach a
running personal backend. Install the existing Playwright capture dependency
inside `tools\playwright-capture`, then from the repository root run:

```powershell
node tools\playwright-capture\offline.js --url http://127.0.0.1:5415 --browser msedge
```

The offline harness blocks external traffic, WebSockets, and backend writes.
It reads only reviewed literal demo functions and the static command catalogue
from source, without loading the backend. Monaco assets come from the installed
WebUI dependency rather than its CDN. Unavailable data remains unavailable.
The DOM redaction pass removes sample IDs and identifying connection details.
Review every resulting PNG and the emitted capture audit before publishing.
Use `--out <review-directory>` to inspect candidates before replacing
`docs\img`; `--only <comma-separated-filenames>` recaptures a subset.
Do not use the separate legacy `capture.js` for public captures: it expects a
live installed application and its local configuration.

The homepage landscape and social graphic are original decorative vector
illustrations, not screenshots, game geography, or borrowed game art.

## Build / preview

```powershell
npm run build
npm run preview
```

`dist/` contains the deployable static site.

## Environment knobs

| Env var       | Default                                  | Purpose                                                            |
| ------------- | ---------------------------------------- | ------------------------------------------------------------------ |
| `SITE_URL`    | `https://coastal-ms.github.io`           | Origin used for canonical URLs and OG tags.                        |
| `SITE_BASE`   | `/DST-DuneServerTool/`                   | Path prefix (matches the project-pages URL). Set to `/` on apex.   |
| `GITHUB_TOKEN`| _(none)_                                 | Optional — raises the GitHub API rate limit during the release fetch. |

## Pages

| Route         | Source                                | Notes                                              |
| ------------- | ------------------------------------- | -------------------------------------------------- |
| `/`           | `src/pages/index.astro`               | Product overview, download, and capability summary. |
| `/features`   | `src/pages/features.astro`            | Eleven-surface v15 tour with explicit capture provenance. |
| `/market`     | `src/pages/market.astro`              | Player/admin guide to Exchange and Duke Market Bot. |
| `/install`    | `src/pages/install.astro`             | Install paths, requirements, and local file paths. |
| `/testing`    | `src/pages/testing.astro`             | Live list of active named test releases.           |
| `/remote`     | `src/pages/remote.astro`              | Remote portal security and setup guide.            |
| `/changelog`  | `src/pages/changelog.astro`           | Renders `../CHANGELOG.md` at build time.           |
| `/community`  | `src/pages/community.astro`           | Discord support and community overview.            |
| `/about`      | `src/pages/about.astro`               | Project history, author, and technical stack.      |
| `/404`        | `src/pages/404.astro`                 | GitHub Pages serves it on missing routes.          |

## SEO

- **`og.png`** — 1200×630 Open Graph image at `public/og.png`, generated from `src/og/og-source.svg`. Regenerate with `npm run build:og` (uses the existing Sharp dependency). The generated social image is committed; responsive screenshot variants are generated during the site build.
- **`robots.txt`** — `public/robots.txt`, allows everything, points crawlers at the sitemap.
- **`sitemap-index.xml`** — auto-generated by `@astrojs/sitemap` on every build. Excludes the 404 page.
- **Canonical URLs + Twitter/Open Graph meta** — emitted by `src/layouts/Base.astro` on every page. Pass `ogImage` as a layout prop to override per-page.

## Folder layout

```
site/
├── astro.config.mjs      Astro config (Tailwind plugin, sitemap, base path)
├── package.json
├── tsconfig.json
├── public/
│   ├── favicon.svg
│   ├── og.png            generated from src/og/og-source.svg (committed)
│   ├── robots.txt
│   └── screenshots/      auto-synced from ../docs/img (gitignored)
├── scripts/
│   ├── sync-images.mjs   prebuild hook
│   └── build-og.mjs      run on demand: `npm run build:og`
└── src/
    ├── components/
    │   ├── DownloadButton.astro
    │   ├── PageHeader.astro
    │   └── Screenshot.astro
    ├── layouts/
    │   └── Base.astro    site shell (header, footer, OG/Twitter meta, canonical)
    ├── lib/
    │   ├── changelog.ts  reads ../CHANGELOG.md
    │   └── release.ts    fetches GitHub release info at build time
    ├── og/
    │   └── og-source.svg source for the OG/social preview image
    ├── pages/            (see table above)
    └── styles/
        └── global.css    Tailwind v4 entry + design tokens
```

## Deployment

`.github/workflows/deploy-site.yml` builds and publishes the site to GitHub
Pages when a site file, `CHANGELOG.md`, or a screenshot changes on `main`.
It can also be run manually from the Actions tab. The workflow installs locked
dependencies, builds `site/dist/`, uploads the Pages artifact, and deploys it to
<https://coastal-ms.github.io/DST-DuneServerTool/>.

```powershell
npm run build
```
