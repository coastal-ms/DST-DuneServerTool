// Build-time helper: fetches the latest GitHub release for the repo so the
// site's Download button always points at the current `DuneServerSetup.exe`.
// Runs in Astro's frontmatter at build time — never in the browser.

export interface LatestRelease {
  tag: string;
  version: string;
  htmlUrl: string;
  installerUrl: string | null;
  publishedAt: string | null;
}

export interface ReleaseEvent {
  tag_name?: string;
  html_url?: string;
  published_at?: string | null;
  prerelease?: boolean;
  assets?: Array<{ name?: string; browser_download_url?: string }>;
}

const REPO = "coastal-ms/DST-DuneServerTool";
const FALLBACK: LatestRelease = {
  tag: "latest",
  version: "latest",
  htmlUrl: `https://github.com/${REPO}/releases/latest`,
  installerUrl: `https://github.com/${REPO}/releases/latest/download/DuneServerSetup.exe`,
  publishedAt: null,
};

export function releaseFromEvent(event: ReleaseEvent): LatestRelease | null {
  if (event.prerelease || !event.tag_name) return null;

  return {
    tag: event.tag_name,
    version: event.tag_name.replace(/^v/, ""),
    htmlUrl: event.html_url ?? `https://github.com/${REPO}/releases`,
    installerUrl:
      event.assets?.find(
        (asset) =>
          asset.name === "DuneServerSetup.exe" &&
          Boolean(asset.browser_download_url),
      )?.browser_download_url ?? null,
    publishedAt: event.published_at ?? null,
  };
}

export async function getLatestRelease(): Promise<LatestRelease> {
  if (process.env.GITHUB_EVENT_NAME === "release") {
    const serializedEvent = process.env.DST_RELEASE_EVENT;
    if (serializedEvent) {
      try {
        const release = releaseFromEvent(
          JSON.parse(serializedEvent) as ReleaseEvent,
        );
        if (release) return release;
      } catch (err) {
        console.warn("[release] event payload parse failed:", err);
      }
    }
  }

  try {
    const headers: Record<string, string> = {
      Accept: "application/vnd.github+json",
      "User-Agent": "dst-site-build",
    };
    if (process.env.GITHUB_TOKEN) {
      headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
    }
    const res = await fetch(
      `https://api.github.com/repos/${REPO}/releases/latest`,
      { headers },
    );
    if (!res.ok) {
      console.warn(
        `[release] GitHub API returned ${res.status}; using fallback URLs.`,
      );
      return FALLBACK;
    }
    const data = (await res.json()) as {
      tag_name?: string;
      html_url?: string;
      published_at?: string;
      assets?: Array<{ name: string; browser_download_url: string }>;
    };
    const tag = data.tag_name ?? "latest";
    const installer =
      data.assets?.find((a) => a.name === "DuneServerSetup.exe")
        ?.browser_download_url ?? FALLBACK.installerUrl;
    return {
      tag,
      version: tag.replace(/^v/, ""),
      htmlUrl: data.html_url ?? FALLBACK.htmlUrl,
      installerUrl: installer,
      publishedAt: data.published_at ?? null,
    };
  } catch (err) {
    console.warn("[release] fetch failed:", err);
    return FALLBACK;
  }
}

// Renders a version string for display in the site UI (everywhere except the
// changelog / release-notes page, which prints raw tags from CHANGELOG.md).
// Plain semver with a "v" prefix to match git tags.
// Examples:
//   "11.0.0" -> "v11.0.0"
//   "11.0.1" -> "v11.0.1"
//   "10.2.4" -> "v10.2.4"
//   "latest" -> "the latest release"

export function formatDisplayVersion(version: string): string {
  if (!version || version === "latest") return "the latest release";
  const cleaned = version.replace(/^v/, "");
  return `v${cleaned}`;
}
