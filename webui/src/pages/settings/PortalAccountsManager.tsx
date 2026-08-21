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
  const [verifyUsername, setVerifyUsername] = useState('')
  const [verifyPassword, setVerifyPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')

  const load = async () => {
    const next = await getPortalAccounts()
    setState(next)
    if (!verifyUsername) {
      const owner = next.accounts.find(a => a.role === 'owner' && a.enabled)
      if (owner) setVerifyUsername(owner.username)
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
    const result = await createPortalAccount({
      username,
      role,
      password: explicitPassword || undefined,
      gameCharacterId: characterId,
      gameCharacterLabel: player?.name ?? '',
    })
    setOneTimePassword(result.oneTimePassword)
    setUsername(''); setExplicitPassword(''); setCharacterId('')
    setMessage('Account created. Copy the one-time password now; it cannot be recovered.')
  })

  const verify = () => run(async () => {
    await verifyPortalOwner(verifyUsername, verifyPassword)
    setVerifyPassword('')
    setMessage('Owner login verified locally. Account-login mode can now be enabled.')
  })

  const toggleMode = (enabled: boolean) => run(async () => {
    await setPortalAccountMode(enabled)
    setMessage(enabled
      ? 'Account login enabled. Browser Portal links are now token-free and require sign-in.'
      : 'Account login disabled. Existing magic-link behavior is restored.')
  })

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
      {oneTimePassword && (
        <div className="bg-warning/10 border border-warning/40 rounded-lg p-3">
          <div className="font-semibold text-warning text-sm">One-time password - shown once</div>
          <code className="block select-all break-all mt-2 text-base">{oneTimePassword}</code>
          <button className="btn-secondary mt-2" onClick={() => { void navigator.clipboard.writeText(oneTimePassword) }}><Icon name="Copy" size={14} /> Copy</button>
          <button className="btn-ghost mt-2" onClick={() => setOneTimePassword('')}>Dismiss</button>
        </div>
      )}
      <div className="grid gap-3 sm:grid-cols-2">
        <div>
          <label htmlFor="portal-account-username" className="block text-sm font-medium mb-1">Username</label>
          <input id="portal-account-username" maxLength={64} value={username} onChange={e => setUsername(e.target.value)} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border" placeholder="Character name or login" />
        </div>
        <div>
          <label htmlFor="portal-account-role" className="block text-sm font-medium mb-1">Role</label>
          <select id="portal-account-role" value={role} onChange={e => setRole(e.target.value as 'owner' | 'admin')} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border">
            <option value="admin">Admin</option><option value="owner">Owner</option>
          </select>
        </div>
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
      <button className="btn-primary" disabled={busy || username.trim().length < 3} onClick={() => void create()}><Icon name="Plus" size={14} /> Create account</button>

      <div className="space-y-2">
        {state?.accounts.map(account => (
          <div key={account.id} className="bg-surface-2 border border-border rounded-lg p-3 flex flex-wrap items-center gap-2">
            <div className="min-w-40 flex-1">
              <div className="font-medium">{account.username} <span className="pill-muted ml-1">{account.role}</span></div>
              <div className="text-xs text-text-dim">
                {account.gameCharacterLabel ? `Linked: ${account.gameCharacterLabel}` : 'No character link'}
                {account.mustChangePassword ? ' - password change required' : ''}
                {account.locallyVerified ? ' - locally verified' : ''}
              </div>
            </div>
            <button className="btn-secondary" disabled={busy} onClick={() => void run(async () => {
              const result = await resetPortalAccountPassword(account.id)
              setOneTimePassword(result.oneTimePassword)
              setMessage('Password reset. All sessions for this account were revoked.')
            })}>Reset password</button>
            <button className="btn-ghost" disabled={busy} onClick={() => void run(async () => { await revokePortalAccountSessions(account.id); setMessage('Sessions revoked.') })}>Revoke sessions</button>
            <button className="btn-ghost" disabled={busy} onClick={() => void run(async () => { await updatePortalAccount(account.id, { enabled: !account.enabled }) })}>{account.enabled ? 'Disable' : 'Enable'}</button>
            <button className="btn-danger" disabled={busy} onClick={() => {
              if (window.confirm(`Delete portal account "${account.username}"?`)) void run(async () => { await deletePortalAccount(account.id) })
            }}>Delete</button>
          </div>
        ))}
        {state && state.accounts.length === 0 && <p className="text-sm text-text-muted">No portal accounts yet.</p>}
      </div>

      <div className="bg-surface-2/60 border border-border rounded-lg p-3 space-y-3">
        <div className="font-medium text-sm">Safe enablement check</div>
        <p className="text-xs text-text-dim">Verify an enabled owner's current one-time password from this host before enabling. This prevents a bad account setup from stranding the host.</p>
        <div className="grid gap-2 sm:grid-cols-2">
          <input aria-label="Owner username to verify" value={verifyUsername} onChange={e => setVerifyUsername(e.target.value)} className="px-3 py-2 rounded-lg bg-surface-2 border border-border" placeholder="Owner username" />
          <input aria-label="Owner password to verify" type="password" value={verifyPassword} onChange={e => setVerifyPassword(e.target.value)} className="px-3 py-2 rounded-lg bg-surface-2 border border-border" placeholder="Owner password" />
        </div>
        <div className="flex flex-wrap gap-2">
          <button className="btn-secondary" disabled={busy || !verifyUsername || !verifyPassword} onClick={() => void verify()}>Verify owner login</button>
          {state?.accountLoginEnabled
            ? <button className="btn-danger" disabled={busy} onClick={() => void toggleMode(false)}>Disable account login</button>
            : <button className="btn-primary" disabled={busy} onClick={() => void toggleMode(true)}>Enable account login</button>}
        </div>
      </div>
    </section>
  )
}
