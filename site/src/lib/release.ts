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

const REPO = "coastal-ms/DST-DuneServerTool";
const FALLBACK: LatestRelease = {
  tag: "latest",
  version: "latest",
  htmlUrl: `https://github.com/${REPO}/releases/latest`,
  installerUrl: `https://github.com/${REPO}/releases/latest/download/DuneServerSetup.exe`,
  publishedAt: null,
};

export async function getLatestRelease(): Promise<LatestRelease> {
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
// Convention: the current major series (10) is shown as the Roman numeral "X",
// with the minor.patch suffix in parentheses. Examples:
//   "10.2.4" -> "X (2.4)"
//   "10.0"   -> "X"
//   "10"     -> "X"
//   "9.1.2"  -> "v9.1.2"   (other majors untouched)
//   "latest" -> "the latest release"
export function formatDisplayVersion(version: string): string {
  if (!version || version === "latest") return "the latest release";
  const cleaned = version.replace(/^v/, "");
  const parts = cleaned.split(".");
  if (parts[0] === "10") {
    const rest = parts.slice(1).join(".").replace(/(\.0)+$/, "");
    return rest ? `X (${rest})` : "X";
  }
  return `v${cleaned}`;
}
