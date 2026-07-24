// Identifies canonical Funcom backup/restore "operation pods" so the Pods
// page can label them clearly instead of showing an unqualified red Error
// row that reads as a live server problem. These are the exact same
// one-shot `battlegroup backup` / `battlegroup import` terminal pods that
// the Database page finds, retains, and prunes under "Completed backup &
// restore pods" — this regex is intentionally identical to the one in
// Database.tsx so both pages agree on what counts as an operation pod.
//   sh-368927b88f3e203b-hinnar-dump-20260718-040000-pod   -> backup, 2026-07-18 04:00:00 UTC
//   sh-368927b88f3e203b-hinnar-import-20260720-040000-pod -> restore, 2026-07-20 04:00:00 UTC
const OP_POD_RE = /-(dump|import)-(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-pod$/

export type BackupOpKind = 'dump' | 'import'

export interface BackupOpPodInfo {
  /** 'dump' = backup job, 'import' = restore job. */
  kind: BackupOpKind
  /** UTC timestamp parsed from the pod name's embedded YYYYMMDD-HHMMSS. */
  timestamp: Date
}

/**
 * Returns backup/restore metadata for a pod name matching the canonical
 * `*-dump-YYYYMMDD-HHMMSS-pod` / `*-import-YYYYMMDD-HHMMSS-pod` pattern, or
 * `null` if the name doesn't match (i.e. it's an ordinary long-running pod).
 */
export function getBackupOpPodInfo(name: string): BackupOpPodInfo | null {
  if (!name) return null
  const m = name.match(OP_POD_RE)
  if (!m) return null
  const kind = m[1] as BackupOpKind
  const timestamp = new Date(Date.UTC(+m[2]!, +m[3]! - 1, +m[4]!, +m[5]!, +m[6]!, +m[7]!))
  return { kind, timestamp }
}

/** Human label for a backup-op kind, for badges/copy. */
export function backupOpKindLabel(kind: BackupOpKind): string {
  return kind === 'dump' ? 'Backup' : 'Restore'
}

/**
 * True when a pod's status text represents a terminal failure. Mirrors the
 * "danger" branch of Pods.tsx's statusTone() so callers can ask "is this
 * failed?" without re-deriving the tone string.
 */
export function isFailedPodStatus(status: string): boolean {
  return /(crash|error|failed|backoff|imagepull|evicted|oomkilled)/i.test(status || '')
}
