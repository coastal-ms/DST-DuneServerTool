// Display formatting for the Dune Server Tool's own version.
// The on-disk / git-tag version stays numeric (e.g. 11.0.0) so the updater's
// [System.Version] / semver comparisons keep working; we only stylize it for
// display. Major versions render as Roman numerals (X, XI, XII, …); the
// minor.patch suffix is shown in parentheses for any non-.0.0 release.
//   11.0.0 -> "XI"
//   11.0.1 -> "XI (0.1)"
//   10.1.2 -> "X (1.2)"
const ROMAN_MAJORS: Record<number, string> = {
  10: 'X', 11: 'XI', 12: 'XII', 13: 'XIII', 14: 'XIV', 15: 'XV',
  16: 'XVI', 17: 'XVII', 18: 'XVIII', 19: 'XIX', 20: 'XX',
}

export function fmtToolVersion(v?: string | null): string {
  if (!v) return ''
  const s = String(v).replace(/^v/i, '').trim()
  const m = s.match(/^(\d+)\.(\d+)\.(\d+)/)
  if (!m) return s
  const major = parseInt(m[1], 10)
  const minor = parseInt(m[2], 10)
  const patch = parseInt(m[3], 10)
  const label = ROMAN_MAJORS[major] ?? String(major)
  if (minor === 0 && patch === 0) return label
  return `${label} (${minor}.${patch})`
}
