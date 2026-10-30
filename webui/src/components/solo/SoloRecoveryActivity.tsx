import type { SoloBackup } from '../../api/solo'

export function SoloRecoveryActivity({ backups, onOpenBackups }: { backups: SoloBackup[]; onOpenBackups: () => void }) {
  const recent = [...backups].sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt)).slice(0, 20)
  return <section className="card p-5">
    <h2 className="font-semibold">Recovery history</h2>
    <p className="mt-1 text-sm text-text-muted">Retained save backups for the connected Solo profile. Open Backups to validate, restore or manage them.</p>
    <button type="button" className="btn-secondary mt-3" onClick={onOpenBackups}>Open Backups</button>
    {recent.length === 0 ? <p className="mt-4 text-sm text-text-muted">No retained backups are available for this profile.</p>
      : <ul className="mt-4 divide-y divide-border">{recent.map(backup => <li key={backup.relativePath} className="flex flex-wrap justify-between gap-2 py-3 text-sm">
        <span className="break-all">{backup.name}</span>
        <time className="text-text-muted" dateTime={backup.modifiedAt}>{backup.modifiedAt}</time>
      </li>)}</ul>}
    {backups.length > recent.length && <p className="mt-2 text-xs text-text-muted">Showing the latest 20 of {backups.length} retained backups.</p>}
  </section>
}
