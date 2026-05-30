// Display formatting for the Dune Server Tool's own version.
// The on-disk / git-tag version stays numeric (e.g. 10.0.0) so the updater's
// [System.Version] / semver comparisons keep working; we only stylize it for
// display. Major 10 renders as the Roman numeral "X"; the minor.patch suffix
// is shown in parentheses for any non-.0.0 release.
//   10.0.0 -> "X"
//   10.0.1 -> "X (0.1)"
//   10.1.2 -> "X (1.2)"
export function fmtToolVersion(v?: string | null): string {
  if (!v) return ''
  const s = String(v).replace(/^v/i, '').trim()
  const m = s.match(/^(\d+)\.(\d+)\.(\d+)/)
  if (!m) return s
  const major = parseInt(m[1], 10)
  const minor = parseInt(m[2], 10)
  const patch = parseInt(m[3], 10)
  const label = major === 10 ? 'X' : String(major)
  if (minor === 0 && patch === 0) return label
  return `${label} (${minor}.${patch})`
}
