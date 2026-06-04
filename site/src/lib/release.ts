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
