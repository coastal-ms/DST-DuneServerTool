import { QRCodeSVG } from 'qrcode.react'
import { usePortalAuth } from '../../auth/PortalAuthGate'
import { isLocalViewer } from '../../util/viewer'

export function remoteMapLink(origin: string, accountLogin: boolean, existingKey = '') {
  const url = new URL('/map?view=live', origin)
  if (!accountLogin && existingKey) url.searchParams.set('key', existingKey)
  return url.toString()
}

/** Reuse this viewer's portal access; never create or transfer an account session. */
export function RemoteMapQr() {
  const auth = usePortalAuth()
  if (isLocalViewer()) return null
  const accountLogin = !!auth?.status.accountLoginEnabled
  const existingKey = accountLogin ? '' : new URL(window.location.href).searchParams.get('key') || window.__duneRemoteToken || ''
  const url = remoteMapLink(window.location.origin, accountLogin, existingKey)
  return (
    <figure className="m-0 w-40 shrink-0 text-center" aria-label="Open map on phone or tablet">
      <div className="inline-flex rounded-lg bg-white p-2">
        <QRCodeSVG value={url} size={112} marginSize={4} title="Scan to open the live map" />
      </div>
      <figcaption className="mt-1 text-xs text-text-muted">
        Open map on phone or tablet
        {accountLogin && <span className="block text-text-dim">Sign in on that device.</span>}
      </figcaption>
    </figure>
  )
}
