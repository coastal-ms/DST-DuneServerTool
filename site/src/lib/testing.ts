export interface GitHubReleaseAsset {
  name?: string;
  browser_download_url?: string;
}

export interface GitHubTestRelease {
  tag_name?: string;
  name?: string;
  body?: string;
  html_url?: string;
  published_at?: string;
  prerelease?: boolean;
  draft?: boolean;
  assets?: GitHubReleaseAsset[];
}

export interface ActiveTestRelease {
  tag: string;
  name: string;
  notes: string;
  htmlUrl: string;
  installerUrl: string;
  publishedAt: string | null;
}

export function isStableMirror(release: GitHubTestRelease): boolean {
  const text = `${release.name ?? ""}\n${release.body ?? ""}`;
  return /\b(?:test|stable)\s+mirror\b/i.test(text);
}

export function getActiveTestReleases(
  releases: GitHubTestRelease[],
): ActiveTestRelease[] {
  return releases
    .filter((release) => {
      if (!release.prerelease || release.draft || isStableMirror(release)) {
        return false;
      }
      return release.assets?.some(
        (asset) =>
          asset.name === "DuneServerSetup.exe" &&
          Boolean(asset.browser_download_url),
      );
    })
    .map((release) => {
      const installer = release.assets?.find(
        (asset) => asset.name === "DuneServerSetup.exe",
      );
      return {
        tag: release.tag_name ?? "untagged-test",
        name: release.name || release.tag_name || "DST test build",
        notes: release.body?.trim() || "No testing notes were provided.",
        htmlUrl:
          release.html_url ??
          "https://github.com/coastal-ms/DST-DuneServerTool/releases",
        installerUrl: installer?.browser_download_url ?? "",
        publishedAt: release.published_at ?? null,
      };
    })
    .sort((a, b) => {
      const at = a.publishedAt ? Date.parse(a.publishedAt) : 0;
      const bt = b.publishedAt ? Date.parse(b.publishedAt) : 0;
      return bt - at;
    });
}
