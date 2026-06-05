import { Icon } from '../../components/Icon'

// Shown when the remote portal middleware returns 401 — typically because
// the user isn't authenticated through Cloudflare Access (header missing)
// or the operator hasn't enabled the remote portal yet (ACL owner empty).
//
// Issue #74 (v11.1.0).
export function LoginRequired() {
  return (
    <div className="text-center py-12 space-y-4">
      <Icon name="ShieldAlert" size={48} className="text-warning mx-auto" />
      <h2 className="text-xl font-semibold">Authentication required</h2>
      <p className="text-text-muted max-w-md mx-auto">
        Your Cloudflare Access session has expired, or your email isn&apos;t on the
        remote-portal allow-list. Sign in again through the same hostname and
        try once more.
      </p>
      <p className="text-text-dim text-xs">
        If you&apos;re the server owner, open the desktop portal and check
        Settings → Remote Access.
      </p>
    </div>
  )
}
