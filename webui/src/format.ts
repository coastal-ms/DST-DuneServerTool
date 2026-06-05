// Display formatting for the Dune Server Tool's own version.
// Plain semver with a "v" prefix — matches git tags and what users see in
// the GitHub releases list. The on-disk version stays purely numeric
// (e.g. 11.0.0) so the updater's [System.Version] / semver comparisons
// keep working; this helper just prefixes the "v" for UI display.
//   11.0.0 -> "v11.0.0"
//   11.0.1 -> "v11.0.1"
//   10.1.2 -> "v10.1.2"

export function fmtToolVersion(v?: string | null): string {
  if (!v) return ''
  const s = String(v).replace(/^v/i, '').trim()
  if (!s) return ''
  return `v${s}`
}
