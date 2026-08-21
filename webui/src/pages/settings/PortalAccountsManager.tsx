import { useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { api } from '../../api/client'
import {
  createPortalAccount,
  deletePortalAccount,
  getPortalAccounts,
  resetPortalAccountPassword,
  revokePortalAccountSessions,
  setPortalAccountMode,
  updatePortalAccount,
  verifyPortalOwner,
  type PortalAccountsState,
} from '../../api/remoteAccess'

interface PlayerOption {
  account_id: number
  name: string
}

export function PortalAccountsManager() {
  const [state, setState] = useState<PortalAccountsState | null>(null)
  const [players, setPlayers] = useState<PlayerOption[]>([])
  const [username, setUsername] = useState('')
  const [role, setRole] = useState<'owner' | 'admin'>('admin')
  const [characterId, setCharacterId] = useState('')
  const [explicitPassword, setExplicitPassword] = useState('')
  const [oneTimePassword, setOneTimePassword] = useState('')
  const [passwordCopied, setPasswordCopied] = useState(false)
  const [copyError, setCopyError] = useState('')
  const [verifyUsername, setVerifyUsername] = useState('')
  const [verifyPassword, setVerifyPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  const [nativeRetirementAcknowledged, setNativeRetirementAcknowledged] = useState(false)

  const load = async () => {
    const next = await getPortalAccounts()
    setState(next)
    const owners = next.accounts.filter(account => account.role === 'owner' && account.enabled)
    const preferredOwner = owners.find(account => account.locallyVerified) ?? owners[0]
    if (preferredOwner) {
      setVerifyUsername(current => {
        const currentOwner = owners.find(account => account.username === current)
        return currentOwner?.locallyVerified ? current : preferredOwner.username
      })
    }
  }

  useEffect(() => {
    void load().catch(e => setError(e instanceof Error ? e.message : String(e)))
    void api<{ players: PlayerOption[] }>('/api/gameplay/players')
      .then(result => setPlayers(result.players ?? []))
      .catch(() => setPlayers([]))
  }, [])

  const run = async (action: () => Promise<void>) => {
    setBusy(true); setError(''); setMessage('')
    try { await action(); await load() } catch (e) { setError(e instanceof Error ? e.message : String(e)) } finally { setBusy(false) }
  }

  const create = () => run(async () => {
    const player = players.find(p => String(p.account_id) === characterId)
    const hasOwner = state?.accounts.some(account => account.role === 'owner' && account.enabled) ?? false
    const result = await createPortalAccount({
      username,
      role: hasOwner ? role : 'owner',
      password: explicitPassword || undefined,
      gameCharacterId: characterId,
      gameCharacterLabel: player?.name ?? '',
    })
    setOneTimePassword(result.oneTimePassword)
    setVerifyUsername(result.account.username)
    setPasswordCopied(false)
    setCopyError('')
    setUsername(''); setExplicitPassword(''); setCharacterId('')
    setMessage(`${hasOwner ? 'Account' : 'First Owner'} created. Copy the one-time password now; it cannot be recovered.`)
  })

  const copyOneTimePassword = async () => {
    if (!oneTimePassword) return
    setCopyError('')
    try {
      await navigator.clipboard.writeText(oneTimePassword)
      setPasswordCopied(true)
      window.setTimeout(() => setPasswordCopied(false), 2000)
    } catch {
      setPasswordCopied(false)
      setCopyError('Could not copy automatically. Select the password above and copy it manually.')
    }
  }

  const verify = () => run(async () => {
    await verifyPortalOwner(verifyUsername, verifyPassword)
    setVerifyPassword('')
    setMessage('Owner password verified locally on this host. Account login can now be enabled.')
  })

  const toggleMode = (enabled: boolean) => run(async () => {
    await setPortalAccountMode(enabled, enabled && nativeRetirementAcknowledged)
    setMessage(enabled
      ? 'Account login enabled. Browser Portal links are now token-free and require sign-in.'
      : 'Account login disabled. Existing magic-link behavior is restored.')
  })

  const enabledOwners = state?.accounts.filter(account => account.role === 'owner' && account.enabled) ?? []
  const verifiedOwner = enabledOwners.find(account => account.locallyVerified)
  const selectedOwner = verifiedOwner ?? enabledOwners[0]
  const ownerVerified = !!verifiedOwner
  const setupStep = !selectedOwner ? 1 : ownerVerified ? 4 : oneTimePassword ? 2 : 3
  const modeEnabled = !!state?.accountLoginEnabled

  const createForm = (firstOwner: boolean) => (
    <div className="space-y-3">
      <div className="grid gap-3 sm:grid-cols-2">
        <div>
          <label htmlFor="portal-account-username" className="block text-sm font-medium mb-1">Username</label>
          <input id="portal-account-username" maxLength={64} value={username} onChange={e => setUsername(e.target.value)} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border" placeholder="Character name or login" />
        </div>
        {!firstOwner && (
          <div>
            <label htmlFor="portal-account-role" className="block text-sm font-medium mb-1">Role</label>
            <select id="portal-account-role" value={role} onChange={e => setRole(e.target.value as 'owner' | 'admin')} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border">
              <option value="admin">Admin</option><option value="owner">Owner</option>
            </select>
          </div>
        )}
        <div>
          <label htmlFor="portal-account-character" className="block text-sm font-medium mb-1">Linked game character (optional)</label>
          <select id="portal-account-character" value={characterId} onChange={e => {
            setCharacterId(e.target.value)
            if (!username) setUsername(players.find(p => String(p.account_id) === e.target.value)?.name ?? '')
          }} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border">
            <option value="">No character link</option>
            {players.map(player => <option key={player.account_id} value={String(player.account_id)}>{player.name}</option>)}
          </select>
        </div>
        <div>
          <label htmlFor="portal-account-password" className="block text-sm font-medium mb-1">Initial password (optional)</label>
          <input id="portal-account-password" type="password" minLength={12} maxLength={128} value={explicitPassword} onChange={e => setExplicitPassword(e.target.value)} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border" placeholder="Leave blank to generate securely" />
        </div>
      </div>
      <button className="btn-primary" disabled={busy || username.trim().length < 3} onClick={() => void create()}>
        <Icon name="Plus" size={14} /> {firstOwner ? 'Create first Owner' : 'Create account'}
      </button>
    </div>
  )

  const passwordPanel = oneTimePassword && (
    <div className="bg-warning/10 border border-warning/40 rounded-lg p-3">
      <div className="font-semibold text-warning text-sm">One-time password — shown once</div>
      <p className="text-xs text-text-muted mt-1">Store this password now. DST cannot recover it after you leave this step.</p>
      <code className="block select-all break-all mt-2 text-base">{oneTimePassword}</code>
      <div className="flex flex-wrap gap-2 mt-2">
        <button type="button" className="btn-secondary" onClick={() => { void copyOneTimePassword() }}>
          <Icon name={passwordCopied ? 'Check' : 'Copy'} size={14} /> {passwordCopied ? 'Copied' : 'Copy one-time password'}
        </button>
        <button type="button" className="btn-primary" onClick={() => { setOneTimePassword(''); setPasswordCopied(false); setCopyError('') }}>
          I stored it — continue
        </button>
      </div>
      <div aria-live="polite" className={`mt-2 text-xs ${copyError ? 'text-danger' : 'text-success'}`}>
        {copyError || (passwordCopied ? 'One-time password copied to the clipboard.' : '')}
      </div>
    </div>
  )

  const accountList = (
    <div className="space-y-2">
      {state?.accounts.map(account => (
        <div key={account.id} className="bg-surface-2 border border-border rounded-lg p-3 flex flex-wrap items-center gap-2">
          <div className="min-w-40 flex-1">
            <div className="font-medium">{account.username} <span className="pill-muted ml-1">{account.role}</span></div>
            <div className="text-xs text-text-dim">
              {account.gameCharacterLabel ? `Linked: ${account.gameCharacterLabel}` : 'No character link'}
              {account.mustChangePassword ? ' — password change required' : ''}
              {account.locallyVerified ? ' — owner password verified locally' : ''}
            </div>
          </div>
          <button className="btn-secondary" disabled={busy} onClick={() => void run(async () => {
            const result = await resetPortalAccountPassword(account.id)
            setOneTimePassword(result.oneTimePassword)
            setVerifyUsername(account.username)
            setPasswordCopied(false)
            setCopyError('')
            setMessage('Password reset. All sessions for this account were revoked.')
          })}>Reset password</button>
          <button className="btn-ghost" disabled={busy} onClick={() => void run(async () => { await revokePortalAccountSessions(account.id); setMessage('Sessions revoked.') })}>Revoke sessions</button>
          <button className="btn-ghost" disabled={busy} onClick={() => void run(async () => { await updatePortalAccount(account.id, { enabled: !account.enabled }) })}>{account.enabled ? 'Disable' : 'Enable'}</button>
          <button className="btn-danger" disabled={busy} onClick={() => {
            if (window.confirm(`Delete portal account "${account.username}"?`)) void run(async () => { await deletePortalAccount(account.id) })
          }}>Delete</button>
        </div>
      ))}
    </div>
  )

  return (
    <section className="border-t border-border pt-5 space-y-4" aria-labelledby="portal-accounts-title">
      <div>
        <h3 id="portal-accounts-title" className="font-semibold flex items-center gap-2"><Icon name="Users" size={16} /> Browser Portal accounts</h3>
        <p className="text-xs text-text-dim mt-1">
          Optional local sign-in for the existing full portal. Owner and admin currently have the same portal capabilities;
          a read-only role is not offered because the existing API does not safely enforce it route by route.
        </p>
      </div>
      {error && <div role="alert" className="text-sm text-danger bg-danger/10 border border-danger/40 rounded-lg px-3 py-2">{error}</div>}
      {message && <div className="text-sm text-success bg-success/10 border border-success/30 rounded-lg px-3 py-2">{message}</div>}
      {!modeEnabled ? (
        <div className="space-y-4">
          <ol className="grid gap-2 sm:grid-cols-4" aria-label="Account login setup progress">
            {['Create Owner', 'Store password', 'Verify locally', 'Enable login'].map((label, index) => {
              const number = index + 1
              const complete = number < setupStep
              return <li key={label} className={`rounded-lg border p-2 text-xs ${number === setupStep ? 'border-accent bg-accent/10 text-text' : 'border-border text-text-muted'}`}>
                <span aria-hidden="true">{complete ? '✓' : number}.</span> {label}
              </li>
            })}
          </ol>

          <div className="bg-surface-2/60 border border-border rounded-lg p-4 space-y-3">
            {setupStep === 1 && <>
              <div className="font-semibold">Step 1 — Create the first Owner</div>
              <p className="text-sm text-text-muted">The first account is always an Owner. DST securely generates its one-time password by default.</p>
              {createForm(true)}
            </>}
            {setupStep === 2 && <>
              <div className="font-semibold">Step 2 — Store the one-time password</div>
              {passwordPanel}
            </>}
            {setupStep === 3 && <>
              <div className="font-semibold">Step 3 — Verify the Owner locally</div>
              <p className="text-sm text-text-muted">This checks only that the Owner password works on this host. It does not claim that remote access is working.</p>
              <div className="grid gap-2 sm:grid-cols-2">
                <label className="text-sm">Owner username
                  <input aria-label="Owner username to verify" value={verifyUsername} onChange={e => setVerifyUsername(e.target.value)} className="mt-1 w-full px-3 py-2 rounded-lg bg-surface-2 border border-border" />
                </label>
                <label className="text-sm">Paste the one-time password
                  <input aria-label="Paste the one-time password" type="password" autoComplete="current-password" value={verifyPassword} onChange={e => setVerifyPassword(e.target.value)} className="mt-1 w-full px-3 py-2 rounded-lg bg-surface-2 border border-border" />
                </label>
              </div>
              <div className="flex flex-wrap gap-2">
                <button className="btn-primary" disabled={busy || !verifyUsername || !verifyPassword} onClick={() => void verify()}>Verify Owner password locally</button>
                {selectedOwner && <button className="btn-ghost" disabled={busy} onClick={() => void run(async () => {
                  const result = await resetPortalAccountPassword(selectedOwner.id)
                  setOneTimePassword(result.oneTimePassword)
                  setPasswordCopied(false)
                  setCopyError('')
                })}>Generate a new one-time password</button>}
              </div>
            </>}
            {setupStep === 4 && <>
              <div className="font-semibold">Step 4 — Enable account login</div>
              {passwordPanel}
              <p className="text-sm text-text-muted">
                The Browser Portal QR and link become a stable token-free login URL. Existing magic-link browser sessions stop working.
                You can always use local Settings to Disable account login and restore legacy links.
              </p>
              <div className="text-sm text-success">✓ Owner password verified locally on this host: {verifiedOwner?.username}</div>
              <label className="flex items-start gap-2 rounded-lg border border-warning/40 bg-warning/10 p-3 text-xs text-text-muted">
                <input
                  type="checkbox"
                  checked={nativeRetirementAcknowledged}
                  onChange={e => setNativeRetirementAcknowledged(e.target.checked)}
                  className="mt-0.5"
                />
                <span>
                  I understand that paired native mobile apps stop working while account login is enabled.
                  The current app sends only the browser-spoofable X-Dune-Token header, so it cannot be safely exempted.
                  Disable account login locally to restore native-app and legacy magic-link access.
                </span>
              </label>
              <button className="btn-primary" disabled={busy || !nativeRetirementAcknowledged} onClick={() => void toggleMode(true)}>Enable account login</button>
            </>}
          </div>

          {state && state.accounts.length > 0 && (
            <details className="border border-border rounded-lg p-3">
              <summary className="font-medium cursor-pointer">Account management</summary>
              <div className="mt-3">{accountList}</div>
            </details>
          )}
        </div>
      ) : (
        <div className="space-y-4">
          <div className="border border-success/40 bg-success/10 rounded-lg p-4 space-y-2">
            <div className="font-semibold text-success flex items-center gap-2"><Icon name="Check" size={16} /> Account login Enabled</div>
            <p className="text-sm text-text-muted">Use the Browser Portal QR or link above. It is now a stable token-free URL; users sign in with their portal account.</p>
            <button className="btn-danger" disabled={busy} onClick={() => void toggleMode(false)}>Emergency: Disable account login</button>
            <p className="text-xs text-text-dim">Disabling locally immediately revokes account sessions and restores legacy magic-link access.</p>
          </div>
          {passwordPanel}
          <div className="border border-border rounded-lg p-4 space-y-3">
            <div>
              <div className="font-semibold">Create another account</div>
              <p className="text-xs text-text-dim">Owner and Admin currently have the same portal capabilities.</p>
            </div>
            {createForm(false)}
          </div>
          <div>
            <div className="font-semibold mb-2">Manage accounts</div>
            {accountList}
          </div>
        </div>
      )}
    </section>
  )
}
