import { useCallback, useEffect, useState } from 'react'
import { api, PlayerGuardCancelledError, withOnlinePlayerGuard } from '../api/client'
import { Icon } from '../components/Icon'
import { PageHeader } from '../components/PageHeader'
import { useStatus } from '../hooks/useStatus'
import { OfficialRetailServerSettingsCard } from './gameconfig/OfficialRetailServerSettingsCard'

type LaunchResult = {
  ok: boolean
  name: string
  mode: string
  pid: number | null
  started: string
}

export function ServerSettings() {
  const { status, forceRefresh } = useStatus()
  const [launchingStop, setLaunchingStop] = useState(false)
  const [launchingStart, setLaunchingStart] = useState(false)
  const [startRequested, setStartRequested] = useState(false)
  const [settingsBusy, setSettingsBusy] = useState(true)
  const [settingsIdleKey, setSettingsIdleKey] = useState<string | null>(null)
  const [stopRequested, setStopRequested] = useState(false)
  const [stopError, setStopError] = useState<string | null>(null)
  const [stopMessage, setStopMessage] = useState<string | null>(null)
  const vmRunning = status?.vm?.running === true
  const bgState = status?.bg?.state ?? 'unknown'
  const serverPodCount = status?.bg?.gameServers?.length ?? null
  const fullyStopped = bgState === 'stopped' && serverPodCount === 0
  const showStop = vmRunning && !fullyStopped
  const canStop = bgState === 'running' && !launchingStop && !launchingStart && !stopRequested && !startRequested
  const showStart = vmRunning && fullyStopped
  const settingsRefreshKey = `${bgState}:${serverPodCount ?? 'unknown'}`
  const canStart = showStart
    && settingsIdleKey === settingsRefreshKey
    && !settingsBusy
    && !launchingStop
    && !launchingStart
    && !stopRequested
    && !startRequested
  const handleSettingsActionStateChange = useCallback((busy: boolean) => {
    setSettingsBusy(busy)
    if (!busy) setSettingsIdleKey(settingsRefreshKey)
  }, [settingsRefreshKey])

  useEffect(() => {
    if (fullyStopped && stopRequested) {
      setStopRequested(false)
      setStopMessage('Battlegroup stopped. Server settings are now unlocked.')
    }
  }, [fullyStopped, stopRequested])

  useEffect(() => {
    if (bgState === 'running' && startRequested) {
      setStartRequested(false)
      setStopMessage('Battlegroup started. Server settings are now active.')
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
      setStopMessage('Stop launched. Settings will unlock after the battlegroup is fully stopped and all server pods exit.')
      try {
        await forceRefresh()
      } catch (e) {
        setStopError(`Stop launched, but status refresh failed: ${e instanceof Error ? e.message : String(e)}`)
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
    <>
      <PageHeader
        title="Server Settings"
        icon="ServerCog"
        description="Official Retail settings from the battlegroup's ServerCustomSettings.ini file."
      />
      {showStop && (
        <div className="card mb-4 flex flex-wrap items-center justify-between gap-3 border-warning/30 p-4">
          <div className="min-w-0">
            <div className="text-sm font-semibold text-text">Battlegroup must be fully stopped to edit settings</div>
            <div className="mt-1 text-xs text-text-muted">
              Current state: <span className="font-mono">{bgState}</span>
              {serverPodCount !== null ? ` · ${serverPodCount} server pod${serverPodCount === 1 ? '' : 's'}` : ''}
            </div>
          </div>
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
      )}
      {showStart && (
        <div className="card mb-4 flex flex-wrap items-center justify-between gap-3 border-success/30 p-4">
          <div className="min-w-0">
            <div className="text-sm font-semibold text-text">Battlegroup is stopped</div>
            <div className="mt-1 text-xs text-text-muted">
              Edit and save settings below, then start the battlegroup here to apply them.
            </div>
          </div>
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
      )}
      {stopError && (
        <div className="card mb-4 flex items-center gap-2 border-danger/40 bg-danger/10 p-3 text-sm text-danger" role="alert">
          <Icon name="AlertCircle" size={14} /> {stopError}
        </div>
      )}
      {stopMessage && (
        <div className="card mb-4 flex items-center gap-2 border-success/40 bg-success/10 p-3 text-sm text-success" role="status">
          <Icon name="CheckCircle2" size={14} /> {stopMessage}
        </div>
      )}
      <OfficialRetailServerSettingsCard
        vmRunning={vmRunning}
        statusRefreshKey={settingsRefreshKey}
        onActionStateChange={handleSettingsActionStateChange}
      />
    </>
  )
}
