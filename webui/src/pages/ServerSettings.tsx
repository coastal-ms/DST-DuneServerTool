import { useCallback, useEffect, useRef, useState } from 'react'
import { api, PlayerGuardCancelledError, withOnlinePlayerGuard } from '../api/client'
import { Icon } from '../components/Icon'
import { PageHeader } from '../components/PageHeader'
import { useStatus } from '../hooks/useStatus'
import { OfficialRetailServerSettingsCard } from './gameconfig/OfficialRetailServerSettingsCard'
import { ServerIniBackups } from './gameconfig/ServerIniBackups'
import { RegisTankSetup } from './gameconfig/RegisTankSetup'
import { GameConfig } from './GameConfig'
import { StartupSettingsSync } from './gameconfig/StartupSettingsSync'
import { ConfirmationModal } from '../components/ConfirmationModal'
import { SettingsApplyContext, type SettingsDraft } from './gameconfig/settingsApplyContext'
import type { StatusSnapshot } from '../api/types'

type LaunchResult = {
  ok: boolean
  name: string
  mode: string
  pid: number | null
  started: string
}

export function AdvancedServerSettings() { return <ServerSettings initialSection="advanced" /> }

export function ServerSettings({ initialSection = 'official' }: { initialSection?: 'official' | 'advanced' } = {}) {
  const { status, forceRefresh } = useStatus()
  const [launchingStop, setLaunchingStop] = useState(false)
  const [launchingStart, setLaunchingStart] = useState(false)
  const [startRequested, setStartRequested] = useState(false)
  const [settingsBusy, setSettingsBusy] = useState(true)
  const [tankSetupBusy, setTankSetupBusy] = useState(false)
  const [stopRequested, setStopRequested] = useState(false)
  const [stopError, setStopError] = useState<string | null>(null)
  const [stopMessage, setStopMessage] = useState<string | null>(null)
  const [section, setSection] = useState<'official' | 'advanced' | 'client' | 'tools' | 'maintenance'>(initialSection)
  const drafts = useRef(new Map<string, SettingsDraft>())
  const [summary, setSummary] = useState<{ changes: SettingsDraft['changes']; ready: boolean }>({ changes: [], ready: false })
  const [reviewOpen, setReviewOpen] = useState(false)
  const [applying, setApplying] = useState(false)
  const applyingRef = useRef(false)
  const reviewingRef = useRef(false)
  const [managed, setManaged] = useState<boolean | null>(null)
  const [startAfterApply, setStartAfterApply] = useState(false)
  const operation = useRef<AbortController | null>(null)
  useEffect(() => () => operation.current?.abort(), [])
  const register = useCallback((id: string, draft: SettingsDraft | null) => {
    if (draft) drafts.current.set(id, draft)
    else drafts.current.delete(id)
    const entries = [...drafts.current.values()]
    const changed = entries.filter(entry => entry.changes.length > 0)
    const next = { changes: entries.flatMap(entry => entry.changes), ready: entries.length === 2 && (changed.length ? changed : entries).every(entry => entry.ready) }
    setSummary(previous => JSON.stringify(previous) === JSON.stringify(next) ? previous : next)
  }, [])

  const review = async () => {
    if (applyingRef.current || reviewingRef.current) return
    reviewingRef.current = true
    setStopError(null)
    try {
      const preference = await api<{ enabled: boolean }>('/api/gameconfig/retail-startup-sync')
      if (typeof preference.enabled !== 'boolean') throw new Error('Configuration management status is unavailable. Try again before applying.')
      setManaged(preference.enabled)
      setStartAfterApply(preference.enabled)
      setReviewOpen(true)
    } catch (e) { setStopError(e instanceof Error ? e.message : String(e)) }
    finally { reviewingRef.current = false }
  }

  const applyReviewed = async () => {
    if (applyingRef.current || !summary.ready || managed === null) return
    applyingRef.current = true
    const controller = new AbortController()
    operation.current = controller
    setApplying(true); setReviewOpen(false); setStopError(null); setStopMessage(null)
    const selected = [...drafts.current.entries()].filter(([, draft]) => draft.changes.length > 0)
    const saved: string[] = []
    let stoppedForApply = false
    let writesAttempted = false
    try {
      const preference = await api<{ enabled: boolean }>('/api/gameconfig/retail-startup-sync', { signal: controller.signal })
      if (preference.enabled !== managed) throw new Error('Configuration management changed. Review the apply plan again.')
      for (const [, draft] of selected) await draft.validate?.()
      let current = await api<StatusSnapshot>('/api/status/refresh', { method: 'POST', signal: controller.signal })
      if (!current.vm?.running || !['running', 'stopped'].includes(current.bg?.state ?? '')) throw new Error('Wait until the battlegroup is running or fully stopped, then review again.')
      if (current.bg?.state !== 'stopped' || current.bg.gameServers?.length !== 0) {
        await withOnlinePlayerGuard(force => api(`/api/commands/run/stop${force ? '?force=true' : ''}`, { method: 'POST', signal: controller.signal }))
        stoppedForApply = true
        setStopMessage('Stopping the battlegroup before saving the reviewed changes…')
        const deadline = Date.now() + 180_000
        while (current.bg?.state !== 'stopped' || current.bg.gameServers?.length !== 0) {
          if (Date.now() > deadline) throw new Error('Timed out waiting for every server pod to stop. No settings were saved. Check Server Health before retrying.')
          await new Promise<void>((resolve, reject) => {
            const timer = window.setTimeout(() => { controller.signal.removeEventListener('abort', abort); resolve() }, 1000)
            const abort = () => { window.clearTimeout(timer); reject(new Error('Settings apply cancelled. Check Server Health before retrying.')) }
            controller.signal.addEventListener('abort', abort, { once: true })
            if (controller.signal.aborted) abort()
          })
          current = await api<StatusSnapshot>('/api/status/refresh', { method: 'POST', signal: controller.signal })
          if (!current.vm?.running) throw new Error('The server became unavailable. No further settings were saved.')
        }
      }
      // Recheck the files after stopping, before the first write. Never replace a
      // manual edit with an older form snapshot.
      for (const [, draft] of selected) await draft.validate?.()
      for (const [id, draft] of selected) {
        if (controller.signal.aborted) throw new Error('Settings apply cancelled.')
        writesAttempted = true
        await draft.apply(); saved.push(id)
      }
      if (controller.signal.aborted) throw new Error('Settings apply cancelled before deployment.')
      if (managed && startAfterApply) {
        const result = await withOnlinePlayerGuard(force => api<{ message: string }>(`/api/gameconfig/reload-pods${force ? '?force=true' : ''}`, {
          method: 'POST', body: JSON.stringify({ startStopped: true }), signal: controller.signal,
        }))
        setStopMessage(`${saved.length ? 'Reviewed settings saved. ' : ''}${result.message} Check Server Health for readiness.`)
      } else {
        setStopMessage(managed
          ? 'Reviewed settings saved. The battlegroup remains stopped; use Review & Apply with Start afterward when ready.'
          : 'Settings saved to files only. DST management is off; deployment remains under your manual control. The battlegroup remains stopped.')
      }
      try { await forceRefresh() } catch { setStopError('The apply sequence finished, but status refresh failed. Check Server Health for readiness.') }
    } catch (e) {
      if (e instanceof PlayerGuardCancelledError) setStopMessage(saved.length ? 'Reviewed changes saved; server start was cancelled. The battlegroup remains stopped.' : 'Apply cancelled. No settings were saved.')
      else { setStopMessage(null); setStopError(`${e instanceof Error ? e.message : String(e)}${saved.length ? ` Already saved: ${saved.join(', ')}.` : ''}${writesAttempted ? ' Some file writes may have completed. Remaining drafts are retained; the battlegroup was not started. Refresh affected files before retrying.' : stoppedForApply ? ' The stop command was sent; no settings were saved. Check Server Health.' : ''}`) }
    } finally {
      operation.current = null; applyingRef.current = false; setApplying(false)
    }
  }
  const stopRefreshInFlight = useRef(false)
  const vmRunning = status?.vm?.running === true
  const bgState = status?.bg?.state ?? 'unknown'
  const serverPodCount = status?.bg?.gameServers?.length ?? null
  const fullyStopped = bgState === 'stopped' && serverPodCount === 0
  const canStop = !applying && !launchingStop && !launchingStart && !stopRequested && !startRequested
  const settingsRefreshKey = `${bgState}:${serverPodCount ?? 'unknown'}`
  const canStart = !applying
    && !settingsBusy
    && !tankSetupBusy
    && !launchingStop
    && !launchingStart
    && !startRequested
  const handleSettingsActionStateChange = useCallback((busy: boolean) => {
    setSettingsBusy(busy)
  }, [])

  useEffect(() => {
    if (fullyStopped && stopRequested) {
      setStopRequested(false)
      setStopError(null)
      setStopMessage('Battlegroup stopped. Reviewed server settings can now be saved.')
    }
  }, [fullyStopped, stopRequested])

  useEffect(() => {
    if (!stopRequested || fullyStopped) return
    if (!vmRunning || !['running', 'stopping', 'stopped'].includes(bgState)) {
      setStopRequested(false)
      setStopError(`Stop launched, but status polling ended because the battlegroup is ${vmRunning ? bgState : 'unavailable'}. Check the console for authoritative progress.`)
      return
    }
    let cancelled = false
    let timer: number
    const refreshUntilFullyStopped = async () => {
      if (stopRefreshInFlight.current) {
        if (!cancelled) timer = window.setTimeout(() => void refreshUntilFullyStopped(), 1000)
        return
      }
      stopRefreshInFlight.current = true
      try {
        await forceRefresh()
      } catch (e) {
        setStopError(`Stop launched, but status refresh failed: ${e instanceof Error ? e.message : String(e)}`)
      } finally {
        stopRefreshInFlight.current = false
        if (!cancelled) timer = window.setTimeout(() => void refreshUntilFullyStopped(), 1000)
      }
    }
    timer = window.setTimeout(() => void refreshUntilFullyStopped(), 1000)
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [bgState, forceRefresh, fullyStopped, stopRequested, vmRunning])

  useEffect(() => {
    if (bgState === 'running' && startRequested) {
      setStartRequested(false)
      setStopMessage('Battlegroup reports running. Check Server Health for map readiness.')
    }
  }, [bgState, startRequested])

  useEffect(() => {
    if (!startRequested || bgState === 'running') return
    let cancelled = false
    let timer: number
    const refreshUntilRunning = async () => {
      try {
        await forceRefresh()
      } catch (e) {
        setStopError(`Start launched, but status refresh failed: ${e instanceof Error ? e.message : String(e)}`)
      } finally {
        if (!cancelled) timer = window.setTimeout(() => void refreshUntilRunning(), 1000)
      }
    }
    timer = window.setTimeout(() => void refreshUntilRunning(), 1000)
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [bgState, forceRefresh, startRequested])

  const stopBattlegroup = async () => {
    if (!canStop) return
    setLaunchingStop(true)
    setStopError(null)
    setStopMessage(null)
    try {
      await withOnlinePlayerGuard(force =>
        api<LaunchResult>(`/api/commands/run/stop${force ? '?force=true' : ''}`, { method: 'POST' }),
      )
      setStopRequested(true)
      setStopMessage('Stop launched. Settings can be saved after the battlegroup is fully stopped and all server pods exit.')
      stopRefreshInFlight.current = true
      try {
        await forceRefresh()
      } catch (e) {
        setStopError(`Stop launched, but status refresh failed: ${e instanceof Error ? e.message : String(e)}`)
      } finally {
        stopRefreshInFlight.current = false
      }
    } catch (e) {
      if (e instanceof PlayerGuardCancelledError) return
      setStopError(`Stop failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setLaunchingStop(false)
    }
  }

  const startBattlegroup = async () => {
    if (!canStart) return
    setLaunchingStart(true)
    setStopError(null)
    setStopMessage(null)
    try {
      await api<LaunchResult>('/api/commands/run/start', { method: 'POST' })
      setStartRequested(true)
      setStopMessage('Start launched. Waiting for the battlegroup to report running.')
      try {
        await forceRefresh()
      } catch (e) {
        setStopError(`Start launched, but status refresh failed: ${e instanceof Error ? e.message : String(e)}`)
      }
    } catch (e) {
      setStopError(`Start failed: ${e instanceof Error ? e.message : String(e)}`)
    } finally {
      setLaunchingStart(false)
    }
  }

  const stopLabel = launchingStop
    ? 'Launching stop…'
    : stopRequested || bgState === 'stopping'
      ? 'Stopping battlegroup…'
      : bgState === 'starting'
        ? 'Battlegroup starting…'
        : bgState === 'updating'
          ? 'Battlegroup updating…'
          : 'Stop Battlegroup'

  return (
    <div className={stopMessage || stopError ? '[&_[data-section-nav-id]]:scroll-mt-80' : '[&_[data-section-nav-id]]:scroll-mt-48'} onWheelCapture={event => {
      const input = event.target instanceof Element ? event.target.closest('input[type="number"], input[type="range"]') : null
      if (input instanceof HTMLInputElement && input === document.activeElement
        && input.dataset.settingsFineWheel !== 'true') input.blur()
    }}>
      <PageHeader
        title="Server Settings"
        icon="ServerCog"
        description="Official and advanced server controls, with one review of changes and where they apply. Player-PC compatibility is separate."
      />
      <div className="card mb-4 p-4">
        <p className="mb-3 text-sm text-text-muted">Official controls affect all players through ServerCustomSettings.ini. Advanced controls use server Game/Engine settings and startup commands where needed. Existing values and manual configuration are preserved; the game determines each control’s actual effect.</p>
        <div className="flex flex-wrap gap-2" aria-label="Settings sections">
          {(['official', 'advanced', 'client', 'tools', 'maintenance'] as const).map(key => <button key={key} type="button" aria-pressed={section === key} disabled={applying || reviewOpen} className={section === key ? 'btn-primary' : 'btn-secondary'} onClick={() => setSection(key)}>{({ official: 'Official server controls', advanced: 'Advanced server controls', client: 'Player compatibility', tools: 'Specialized controls', maintenance: 'Management & recovery' })[key]}</button>)}
        </div>
      </div>
      <div className="mb-4 rounded-lg border border-border bg-surface p-3 text-sm" role="note">
        {section === 'client' ? <>
          <strong>This PC's game files only</strong>
          <p className="mt-1 text-xs text-text-muted">Writes this PC's game-client files, not the selected server's files. The same files are used on your DST server and other servers. Some Engine.ini settings are evaluated by each player's client independently, so server values do not always win. The effect depends on the setting; other players' files are unchanged.</p>
        </> : section === 'official' || section === 'advanced' ? <>
          <strong>Selected server's files</strong>
          <p className="mt-1 text-xs text-text-muted">These controls configure the DST server you are managing and can affect everyone connected to it. Review & Apply writes the server configuration while the battlegroup is stopped. It does not edit the game-client files on this PC or any player's PC.</p>
        </> : <>
          <strong>{section === 'tools' ? 'Targets vary by tool' : 'Selected server management'}</strong>
          <p className="mt-1 text-xs text-text-muted">Read each action's target before applying it. Specialized tools identify whether they change server files, the DST host PC, or the server database. These actions are separate from player game-client compatibility files.</p>
        </>}
      </div>
      <div role="region" aria-label="Settings actions" className="sticky top-16 z-20 mb-4 flex flex-wrap items-center gap-3 rounded-lg border border-border bg-base/95 p-3 shadow-lg backdrop-blur-sm">
          <button className="btn-primary" type="button" disabled={!vmRunning || !summary.ready || applying || reviewOpen || launchingStart || launchingStop || stopRequested || startRequested || tankSetupBusy} onClick={() => void review()}>{applying ? 'Applying settings…' : 'Review & Apply'}{summary.changes.length > 0 ? ` (${summary.changes.length})` : ''}</button>
          <span className="text-xs text-text-muted">Review exact changes, server stop, and whether to start afterward. Local player files are never included.</span>
          {stopError && (
            <div className="flex w-full min-w-0 items-start gap-2 rounded-lg border border-danger/40 bg-danger/10 p-3 text-sm text-danger" role="alert">
              <Icon name="AlertCircle" size={14} className="mt-0.5 shrink-0" /><span className="min-w-0 break-words">{stopError}</span>
            </div>
          )}
          {stopMessage && (
            <div className="flex w-full min-w-0 items-start gap-2 rounded-lg border border-success/40 bg-success/10 p-3 text-sm text-success" role="status">
              <Icon name={applying ? 'Loader2' : 'CheckCircle2'} size={14} className={applying ? 'mt-0.5 shrink-0 animate-spin' : 'mt-0.5 shrink-0'} /><span className="min-w-0 break-words">{stopMessage}</span>
            </div>
          )}
      </div>
      <div hidden={section !== 'maintenance'}>
      <div className="card mb-4 flex flex-wrap items-center justify-between gap-3 border-warning/30 p-4">
        <div className="min-w-0">
          <div className="text-sm font-semibold text-text">Manual battlegroup stop</div>
          <div className="mt-1 text-xs text-text-muted">
            Current state: <span className="font-mono">{bgState}</span>
            {serverPodCount !== null ? ` · ${serverPodCount} server pod${serverPodCount === 1 ? '' : 's'}` : ''}
          </div>
        </div>
        <div className="flex items-center gap-2">
          <span className="pill-info"><Icon name="SquareTerminal" size={10} /> Console</span>
          <button
            type="button"
            className="btn-danger"
            disabled={!canStop}
            onClick={() => void stopBattlegroup()}
            title={canStop
              ? 'Stop the battlegroup using DST’s guarded stop command'
              : `Stop is unavailable while the battlegroup is ${bgState}`}
          >
            <Icon
              name={launchingStop || stopRequested || bgState === 'stopping' ? 'Loader2' : 'Square'}
              size={14}
              className={launchingStop || stopRequested || bgState === 'stopping' ? 'animate-spin' : ''}
            />
            {stopLabel}
          </button>
        </div>
      </div>
      <div className="card mb-4 flex flex-wrap items-center justify-between gap-3 border-success/30 p-4">
        <div className="min-w-0">
          <div className="text-sm font-semibold text-text">Start battlegroup</div>
          <div className="mt-1 text-xs text-text-muted">
            Start uses DST’s existing command and reports its authoritative availability response.
          </div>
        </div>
        <div className="flex items-center gap-2">
          <span className="pill-info"><Icon name="SquareTerminal" size={10} /> Console</span>
          <button
            type="button"
            className="btn-primary"
            disabled={!canStart}
            onClick={() => void startBattlegroup()}
            title={settingsBusy
              ? 'Wait for the current settings action to finish'
              : 'Start the battlegroup using DST’s existing start command'}
          >
            <Icon
              name={launchingStart || startRequested ? 'Loader2' : 'Play'}
              size={14}
              className={launchingStart || startRequested ? 'animate-spin' : ''}
            />
            {launchingStart
              ? 'Launching start…'
              : startRequested
                ? 'Starting battlegroup…'
                : 'Start Battlegroup'}
          </button>
        </div>
      </div>
      </div>
      <SettingsApplyContext.Provider value={{ register, review: () => void review(), locked: applying || reviewOpen }}>
      <fieldset disabled={applying || reviewOpen} className="min-w-0">
      <div hidden={section !== 'maintenance'}>
        <StartupSettingsSync onBusyChange={setTankSetupBusy} />
        <ServerIniBackups vmRunning={vmRunning} />
        <RegisTankSetup vmRunning={vmRunning} stopped={fullyStopped} onBusyChange={setTankSetupBusy} />
      </div>
      <div hidden={section !== 'official'}>
      <OfficialRetailServerSettingsCard
        vmRunning={vmRunning}
        statusRefreshKey={settingsRefreshKey}
        onActionStateChange={handleSettingsActionStateChange}
      />
      </div>
      <div hidden={!['client', 'advanced', 'tools'].includes(section)}><GameConfig embedded section={section === 'client' ? 'client' : section === 'tools' ? 'tools' : 'advanced'} /></div>
      </fieldset>
      </SettingsApplyContext.Provider>
      {reviewOpen && <ConfirmationModal title="Review server settings" description={managed ? 'DST will stop every map, save only the reviewed changes, and prepare the required server configuration. Connected players will disconnect.' : 'DST management is off. This saves files only, after stopping the battlegroup; it does not restore deployment or startup injections.'} confirmLabel={managed && startAfterApply ? 'Save & start battlegroup' : 'Save files; leave stopped'} onCancel={() => setReviewOpen(false)} onConfirm={() => void applyReviewed()}>
        <div className="space-y-3 text-sm">
          {summary.changes.length === 0 && <p>No draft changes. This applies the settings already saved on the server.</p>}
          {summary.changes.map((change, index) => <div key={index} className="border-b border-border pb-2"><strong>{change.label}</strong><div className="text-xs text-text-muted">{change.target}</div><div className="break-all font-mono text-xs">{change.before || '(unset)'} → {change.after || '(unset)'}</div></div>)}
          {managed && <label className="flex gap-2"><input type="checkbox" checked={startAfterApply} onChange={e => setStartAfterApply(e.target.checked)} />Start afterward and deploy saved server settings</label>}
          <p className="text-xs text-text-muted">Unchanged values, unknown settings and player-PC files are preserved. A successful save does not prove an in-game effect.</p>
        </div>
      </ConfirmationModal>}
    </div>
  )
}
