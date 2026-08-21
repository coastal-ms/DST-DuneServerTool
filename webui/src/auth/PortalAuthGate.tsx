import { createContext, useContext, useEffect, useState, type FormEvent, type ReactNode } from 'react'
import { Icon } from '../components/Icon'
import {
  changePortalPassword,
  getPortalAuthStatus,
  loginPortal,
  logoutPortal,
  type PortalAuthStatus,
} from '../api/portalAuth'

interface PortalAuthContextValue {
  status: PortalAuthStatus
  logout: () => Promise<void>
}

const PortalAuthContext = createContext<PortalAuthContextValue | null>(null)

export function usePortalAuth() {
  return useContext(PortalAuthContext)
}

function AuthFrame({ title, subtitle, children }: { title: string; subtitle: string; children: ReactNode }) {
  return (
    <main className="min-h-full flex items-center justify-center p-4">
      <section className="card w-full max-w-md p-6" aria-labelledby="portal-auth-title">
        <div className="flex items-center gap-3 mb-5">
          <img src="/logo.png" alt="" className="w-12 h-12 rounded-full" />
          <div>
            <h1 id="portal-auth-title" className="text-xl font-semibold">{title}</h1>
            <p className="text-sm text-text-muted">{subtitle}</p>
          </div>
        </div>
        {children}
      </section>
    </main>
  )
}

function Login({ onSuccess }: { onSuccess: (status: PortalAuthStatus) => void }) {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    setBusy(true)
    setError('')
    try {
      onSuccess(await loginPortal(username, password))
    } catch {
      setError('Invalid username or password.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthFrame title="Dune Server Tool" subtitle="Sign in to the Browser Portal">
      <form id="portal-login-form" name="portal-login" autoComplete="on" onSubmit={submit} className="space-y-4">
        {error && <div role="alert" className="text-sm text-danger bg-danger/10 border border-danger/40 rounded-lg px-3 py-2">{error}</div>}
        <div>
          <label htmlFor="portal-username" className="block text-sm font-medium mb-1">Username</label>
          <input id="portal-username" name="username" type="text" inputMode="text" autoCapitalize="none" spellCheck={false} autoComplete="username" maxLength={64} required autoFocus value={username} onChange={e => setUsername(e.target.value)} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text" />
        </div>
        <div>
          <label htmlFor="portal-password" className="block text-sm font-medium mb-1">Password</label>
          <input id="portal-password" name="password" type="password" autoComplete="current-password" maxLength={128} required value={password} onChange={e => setPassword(e.target.value)} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text" />
        </div>
        <button type="submit" disabled={busy} className="btn-primary w-full justify-center">
          <Icon name={busy ? 'Loader2' : 'LogIn'} className={busy ? 'animate-spin' : ''} />
          {busy ? 'Signing in...' : 'Sign in'}
        </button>
        <p className="text-xs text-text-dim">Forgotten passwords are reset by the server host in Settings.</p>
      </form>
    </AuthFrame>
  )
}

function ForcedPasswordChange({ username, onSuccess }: { username: string; onSuccess: () => void }) {
  const [currentPassword, setCurrentPassword] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (newPassword !== confirm) { setError('New passwords do not match.'); return }
    if (newPassword.length < 12) { setError('Use at least 12 characters.'); return }
    setBusy(true)
    setError('')
    try {
      await changePortalPassword(currentPassword, newPassword)
      onSuccess()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Password change failed.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <AuthFrame title="Change your password" subtitle="Replace the one-time password before continuing">
      <form id="portal-password-change-form" name="portal-password-change" autoComplete="on" onSubmit={submit} className="space-y-4">
        <input
          id="portal-password-change-username"
          name="username"
          type="text"
          autoComplete="username"
          value={username}
          readOnly
          tabIndex={-1}
          aria-hidden="true"
          className="sr-only"
        />
        {error && <div role="alert" className="text-sm text-danger bg-danger/10 border border-danger/40 rounded-lg px-3 py-2">{error}</div>}
        <div>
          <label htmlFor="portal-current-password" className="block text-sm font-medium mb-1">One-time password</label>
          <input id="portal-current-password" name="current-password" type="password" autoComplete="current-password" maxLength={128} required value={currentPassword} onChange={e => setCurrentPassword(e.target.value)} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text" />
        </div>
        <div>
          <label htmlFor="portal-new-password" className="block text-sm font-medium mb-1">New password</label>
          <input id="portal-new-password" name="new-password" type="password" autoComplete="new-password" minLength={12} maxLength={128} required value={newPassword} onChange={e => setNewPassword(e.target.value)} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text" />
        </div>
        <div>
          <label htmlFor="portal-confirm-password" className="block text-sm font-medium mb-1">Confirm new password</label>
          <input id="portal-confirm-password" name="confirm-new-password" type="password" autoComplete="new-password" minLength={12} maxLength={128} required value={confirm} onChange={e => setConfirm(e.target.value)} className="w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text" />
        </div>
        <button type="submit" disabled={busy} className="btn-primary w-full justify-center">
          {busy ? 'Changing...' : 'Change password'}
        </button>
      </form>
    </AuthFrame>
  )
}

export function PortalAuthGate({ children }: { children: ReactNode }) {
  const [status, setStatus] = useState<PortalAuthStatus | null>(null)
  const [error, setError] = useState('')

  const refresh = async () => {
    try {
      setStatus(await getPortalAuthStatus())
      setError('')
    } catch {
      setError('Unable to reach Dune Server Tool.')
    }
  }

  useEffect(() => { void refresh() }, [])
  useEffect(() => {
    const accountSession = !!(status?.accountLoginEnabled && status.authenticated && status.account)
    ;(window as unknown as { __dunePortalAccountSession?: boolean }).__dunePortalAccountSession = accountSession
    if (accountSession) sessionStorage.removeItem('dune.token')
    return () => {
      ;(window as unknown as { __dunePortalAccountSession?: boolean }).__dunePortalAccountSession = false
    }
  }, [status])

  if (error) {
    return <AuthFrame title="Connection unavailable" subtitle={error}><button className="btn-primary" onClick={() => void refresh()}>Try again</button></AuthFrame>
  }
  if (!status) {
    return <div className="min-h-full flex items-center justify-center text-text-muted"><Icon name="Loader2" className="animate-spin mr-2" /> Checking access...</div>
  }
  if (!status.accountLoginEnabled) return <>{children}</>
  if (!status.authenticated) return <Login onSuccess={setStatus} />
  if (status.mustChangePassword) {
    return <ForcedPasswordChange username={status.account?.username ?? ''} onSuccess={() => void refresh()} />
  }
  const logout = async () => {
    await logoutPortal()
    await refresh()
  }
  return <PortalAuthContext.Provider value={{ status, logout }}>{children}</PortalAuthContext.Provider>
}
