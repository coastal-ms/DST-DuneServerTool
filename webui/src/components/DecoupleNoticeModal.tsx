import { useEffect, useState } from 'react'
import { Icon } from './Icon'
import { getMigrationNotice, ackMigrationNotice, type MigrationNotice } from '../api/update'
import { isLocalViewer } from '../util/viewer'

// Blocking, one-time notice shown to anyone upgrading across the dune-admin
// decoupling (pre-12.x -> 12.x). It explains that DST no longer bundles or
// launches dune-admin, points them at the standalone portal, and shows where
// their old dune-admin folder lives so they can still run it. The update flow
// is gated server-side until this is acknowledged, and the overlay sits above
// the whole app so it can't be skipped.
//
// Host-only: launching dune-admin and the folder path are concerns for the
// machine running the server, not a remote Tailscale / LAN viewer. Remote
// viewers are never shown the notice (and the backend refuses to hand them the
// path or accept their acknowledgement).
export function DecoupleNoticeModal() {
  const [notice, setNotice] = useState<MigrationNotice | null>(null)
  const [acked, setAcked] = useState(false)
  const [working, setWorking] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!isLocalViewer()) return
    let cancelled = false
    getMigrationNotice()
      .then((n) => { if (!cancelled) setNotice(n) })
      .catch(() => { /* never block the app on a failed check */ })
    return () => { cancelled = true }
  }, [])

  if (!isLocalViewer()) return null
  if (!notice || !notice.needed || acked) return null

  const portalUrl = notice.portalUrl || 'https://dune-admin.layout.tools'
  const folder = notice.duneAdminFolder?.trim()

  const onCopy = async () => {
    if (!folder) return
    try {
      await navigator.clipboard.writeText(folder)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch { /* clipboard may be unavailable; the path is still shown */ }
  }

  const onAck = async () => {
    setWorking(true)
    setErr(null)
    try {
      await ackMigrationNotice()
      setAcked(true)
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setWorking(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[10000] flex items-center justify-center bg-slate-950/80 p-4 backdrop-blur-sm">
      <div className="w-full max-w-lg rounded-xl border border-amber-400/30 bg-slate-900 shadow-2xl">
        <div className="flex items-start gap-3 border-b border-slate-700/60 px-6 py-4">
          <div className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-amber-400/15">
            <Icon name="TriangleAlert" size={20} className="text-amber-300" />
          </div>
          <div>
            <h2 className="text-lg font-semibold text-amber-100">
              Dune Server Tool is now standalone
            </h2>
            <p className="text-xs text-amber-200/70">
              Please read this one-time notice before continuing.
            </p>
          </div>
        </div>

        <div className="max-h-[60vh] overflow-y-auto px-6 py-4 text-sm leading-relaxed text-slate-300 space-y-3">
          <p>
            Dune Server Tool is no longer bundled with <strong className="text-white">Dune-Admin</strong>.
            The built-in <strong className="text-white">launch commands for Dune-Admin have been removed</strong>,
            and Dune-Admin is now a completely separate application.
          </p>

          <p>
            You can still use Dune-Admin — it just runs on its own now. Going forward:
          </p>
          <ol className="list-decimal space-y-1 pl-5">
            <li>
              Launch <strong className="text-white">dune-admin</strong> from its folder
              {folder ? ' (shown below)' : ''}.
            </li>
            <li>
              Then open the portal at{' '}
              <a
                href={portalUrl}
                target="_blank"
                rel="noreferrer"
                className="font-medium text-amber-300 underline hover:text-amber-200"
              >
                {portalUrl}
              </a>{' '}
              if it doesn't open in your browser automatically.
            </li>
          </ol>

          {folder ? (
            <div className="rounded-lg border border-slate-700/60 bg-slate-950/60 px-3 py-2">
              <div className="mb-1 text-xs font-semibold uppercase tracking-wide text-slate-400">
                Your Dune-Admin folder
              </div>
              <div className="flex items-center gap-2">
                <code className="min-w-0 flex-1 break-all font-mono text-xs text-amber-100">
                  {folder}
                </code>
                <button
                  type="button"
                  onClick={() => { void onCopy() }}
                  className="flex shrink-0 items-center gap-1 rounded-md border border-slate-600 px-2 py-1 text-xs text-slate-300 hover:bg-slate-800"
                  title="Copy folder path"
                >
                  <Icon name={copied ? 'Check' : 'Copy'} size={13} />
                  {copied ? 'Copied' : 'Copy'}
                </button>
              </div>
            </div>
          ) : (
            <p className="rounded-lg border border-slate-700/60 bg-slate-950/60 px-3 py-2 text-xs text-slate-400">
              We couldn't find a saved Dune-Admin folder for this install. Launch
              Dune-Admin from wherever you keep it, then open{' '}
              <a
                href={portalUrl}
                target="_blank"
                rel="noreferrer"
                className="text-amber-300 underline hover:text-amber-200"
              >
                {portalUrl}
              </a>.
            </p>
          )}

          <div className="flex flex-wrap items-center gap-2 pt-1">
            <a
              href={portalUrl}
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1.5 rounded-md border border-amber-400/40 bg-amber-400/10 px-3 py-1.5 text-xs font-medium text-amber-100 hover:bg-amber-400/20"
            >
              <Icon name="ExternalLink" size={14} />
              Open Dune-Admin portal
            </a>
          </div>

          {err && (
            <p className="text-xs text-red-300">
              Couldn't save your acknowledgement: {err}. Please try again.
            </p>
          )}
        </div>

        <div className="flex justify-end border-t border-slate-700/60 px-6 py-3">
          <button
            type="button"
            onClick={() => { void onAck() }}
            disabled={working}
            className="rounded-md bg-amber-400 px-4 py-1.5 text-sm font-semibold text-amber-950 hover:bg-amber-300 disabled:cursor-wait disabled:opacity-60"
          >
            {working ? 'Saving…' : 'I understand — continue'}
          </button>
        </div>
      </div>
    </div>
  )
}
