import { useEffect, useMemo, useState } from 'react'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { Icon } from '../../components/Icon'
import { getRetailServerSettings, saveRetailServerSettings } from '../../api/gameconfig'
import type { RetailServerSetting, RetailServerSettingsResponse } from '../../api/types'

export function OfficialRetailServerSettingsCard({ vmRunning }: { vmRunning: boolean }) {
  const [state, setState] = useState<RetailServerSettingsResponse | null>(null)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})

  const load = async () => {
    if (!vmRunning) return
    setLoading(true)
    setError(null)
    try {
      const next = await getRetailServerSettings()
      setState(next)
      setValues(Object.fromEntries((next.settings ?? []).map(setting => [setting.key, setting.value])))
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    void load()
    // The card owns its endpoint so it can move to a dedicated page without
    // changing the Retail settings API or coupling to legacy Game Config state.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vmRunning])

  const groups = useMemo(() => {
    const grouped = new Map<string, RetailServerSetting[]>()
    for (const setting of state?.settings ?? []) {
      const values = grouped.get(setting.group) ?? []
      values.push(setting)
      grouped.set(setting.group, values)
    }
    return [...grouped.entries()]
  }, [state])
  const updates = useMemo(() => Object.fromEntries(
    (state?.settings ?? [])
      .filter(setting => setting.editable && (values[setting.key] ?? setting.value) !== setting.value)
      .map(setting => [setting.key, values[setting.key] ?? setting.value]),
  ), [state, values])
  const dirtyCount = Object.keys(updates).length
  const canSave = state?.available === true
    && state.target.stopped === true
    && state.target.serverPodCount === 0
    && dirtyCount > 0
    && !saving

  const save = async () => {
    if (!state?.revision || !canSave) return
    setSaving(true)
    setError(null)
    setMessage(null)
    try {
      const result = await saveRetailServerSettings(state.revision, updates)
      const nextSettings = result.settings
      setState(previous => previous ? {
        ...previous,
        readOnly: false,
        source: 'funcom-servergroup-user-ini-config',
        authority: 'Funcom BattleGroup operator configuration',
        revision: result.revision,
        settings: nextSettings,
        target: {
          ...previous.target,
          upstreamConfigured: true,
          upstreamMountPath: '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer',
          upstreamFileName: 'ServerCustomSettings.ini',
        },
      } : previous)
      setValues(Object.fromEntries(nextSettings.map(setting => [setting.key, setting.value])))
      setMessage(`${result.applied} setting${result.applied === 1 ? '' : 's'} saved with backup ${result.backup.path}. Start the battlegroup to apply them.`)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setSaving(false)
    }
  }

  return (
    <CollapsibleCard
      id="gameconfig.officialRetailServerSettings"
      icon="ServerCog"
      iconClassName="text-accent-bright shrink-0"
      title="Official Retail Server Settings"
      titleClassName="text-sm font-semibold text-text"
      className="mb-4 border-accent/30"
      headerClassName="px-4 pt-4 pb-2"
      bodyClassName="px-4 pb-4"
      headerRight={(
        <>
          <span className="pill-info" title="Saved through Funcom's BattleGroup operator configuration">
            <Icon name="ShieldCheck" size={12} /> Operator managed
          </span>
          <button
            type="button"
            className="btn-secondary"
            onClick={() => void load()}
            disabled={!vmRunning || loading}
          >
            <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14} className={loading ? 'animate-spin' : ''} />
            Refresh
          </button>
          <button
            type="button"
            className="btn-primary"
            onClick={() => void save()}
            disabled={!canSave}
            title={state?.target.stopped
              ? 'Save changed settings to Funcom operator configuration'
              : 'Stop the battlegroup fully before saving'}
          >
            <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
            {saving ? 'Saving…' : `Save${dirtyCount ? ` (${dirtyCount})` : ''}`}
          </button>
        </>
      )}
    >
      <div className="mb-3 rounded-lg border border-warning/30 bg-warning/5 p-3 text-xs text-text-muted">
        <strong className="text-text">Funcom operator-managed settings.</strong>{' '}
        These values drive the greyed-out multiplayer Server Settings preview. Direct file edits are regenerated.
        DST saves only through the BattleGroup&apos;s official <span className="font-mono">global.userIniConfig</span>{' '}
        source, while the battlegroup is fully stopped.
      </div>
      {state?.available && !state.target.stopped && (
        <div className="mb-3 border-y border-border py-2 text-xs text-text-muted">
          Stop the battlegroup to unlock edits. Saving creates a timestamped copy of the complete current file;
          start the battlegroup afterward to mount the new settings into every game pod.
        </div>
      )}

      {!vmRunning && (
        <div className="text-sm text-text-muted">Start the battlegroup to read its official Retail Server Settings.</div>
      )}
      {error && (
        <div className="rounded-lg border border-danger/40 bg-danger/10 p-3 text-sm text-danger">
          <Icon name="AlertCircle" size={14} className="inline mr-2" />{error}
        </div>
      )}
      {message && (
        <div className="mb-3 rounded-lg border border-success/40 bg-success/10 p-3 text-sm text-success">
          <Icon name="ShieldCheck" size={14} className="inline mr-2" />{message}
        </div>
      )}
      {vmRunning && loading && !state && (
        <div className="space-y-2" aria-label="Loading official Retail settings">
          <div className="h-4 w-48 animate-pulse bg-surface-2" />
          <div className="h-10 w-full animate-pulse bg-surface-2" />
          <div className="h-10 w-full animate-pulse bg-surface-2" />
        </div>
      )}
      {state && !state.available && (
        <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm text-warning">
          {state.reason ?? 'The Funcom runtime settings file is unavailable.'}
        </div>
      )}
      {state?.available && (
        <>
          <div className="mb-3 grid gap-1 text-[11px] text-text-dim">
            {!state.target.upstreamConfigured && (
              <div><span className="text-text-muted">Generated File Browser output:</span> <span className="font-mono">{state.target.path}</span></div>
            )}
            <div><span className="text-text-muted">Game pod:</span> <span className="font-mono">{state.target.gamePath}</span></div>
            <div>
              <span className="text-text-muted">Source:</span> {state.authority}
              {state.modifiedAt ? ` • updated ${new Date(state.modifiedAt).toLocaleString()}` : ''}
            </div>
            <div>
              <span className="text-text-muted">Durable operator field:</span>{' '}
              <span className="font-mono">{state.target.upstreamField}</span>{' '}
              <span className={state.target.upstreamConfigured ? 'text-success' : 'text-warning'}>
                • {state.target.upstreamConfigured ? 'configured' : 'not configured'}
              </span>
            </div>
            {state.target.upstreamConfigured && (
              <div>
                <span className="text-text-muted">Operator mount:</span>{' '}
                <span className="font-mono">{state.target.upstreamMountPath}/{state.target.upstreamFileName}</span>
              </div>
            )}
          </div>

          {state.malformedLines.length > 0 && (
            <div className="mb-3 rounded-lg border border-warning/40 bg-warning/10 p-3 text-xs text-warning">
              {state.malformedLines.length} non-comment line{state.malformedLines.length === 1 ? '' : 's'} could not be parsed and remain visible only in the source file.
            </div>
          )}

          <div className="space-y-3">
            {groups.map(([group, settings]) => (
              <section key={group}>
                <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-text-muted">{group}</h3>
                <div className="border-y border-border">
                  {settings.map(setting => (
                    <div
                      key={setting.key}
                      className={`grid gap-2 border-b border-border/70 px-1 py-2.5 last:border-b-0 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center ${
                        !setting.supported || !setting.valid ? 'bg-warning/5' : ''
                      }`}
                    >
                      <div className="min-w-0">
                        <div className="text-sm font-medium text-text">{setting.label}</div>
                        <div className="mt-0.5 break-all font-mono text-[10px] text-text-dim">{setting.key}</div>
                        {setting.key === 'bIsBuildingRestrictionsEnabled' && (
                          <div className="mt-1 text-[11px] text-text-muted">
                            Controls general building restrictions. It does not override permanent POI or other restricted no-build zones.
                          </div>
                        )}
                        {setting.inverted && (
                          <div className="mt-1 text-[11px] text-text-muted">
                            Inverted game key: raw <span className="font-mono">{setting.value}</span> means {setting.displayValue.toLowerCase()}.
                          </div>
                        )}
                        {!setting.supported && (
                          <div className="mt-1 text-[11px] text-warning">Unknown current-Retail key retained read-only.</div>
                        )}
                        {!setting.valid && (
                          <div className="mt-1 text-[11px] text-warning">{setting.validationError}</div>
                        )}
                      </div>
                      <div className="flex items-center gap-2 sm:justify-end">
                        <span className="text-[10px] uppercase tracking-wide text-text-dim">{setting.type}</span>
                        {setting.type === 'bool' && setting.editable ? (
                          <select
                            aria-label={setting.label}
                            value={values[setting.key] ?? setting.value}
                            onChange={event => setValues(previous => ({ ...previous, [setting.key]: event.target.value }))}
                            disabled={!state.target.stopped || state.target.serverPodCount !== 0 || saving}
                            className="min-w-28 border border-border bg-surface px-2 py-1 text-xs font-semibold text-text disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            <option value={setting.inverted ? 'False' : 'True'}>Enabled</option>
                            <option value={setting.inverted ? 'True' : 'False'}>Disabled</option>
                          </select>
                        ) : setting.type === 'select' && setting.editable ? (
                          <select
                            aria-label={setting.label}
                            value={values[setting.key] ?? setting.value}
                            onChange={event => setValues(previous => ({ ...previous, [setting.key]: event.target.value }))}
                            disabled={!state.target.stopped || state.target.serverPodCount !== 0 || saving}
                            className="min-w-36 border border-border bg-surface px-2 py-1 text-xs text-text disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            {setting.options.map(option => <option key={option} value={option}>{option}</option>)}
                          </select>
                        ) : (setting.type === 'int' || setting.type === 'float') && setting.editable ? (
                          <input
                            aria-label={setting.label}
                            type="number"
                            step={setting.type === 'int' ? 1 : 'any'}
                            value={values[setting.key] ?? setting.value}
                            onChange={event => setValues(previous => ({ ...previous, [setting.key]: event.target.value }))}
                            disabled={!state.target.stopped || state.target.serverPodCount !== 0 || saving}
                            className="w-28 border border-border bg-surface px-2 py-1 text-right text-xs text-text focus:outline-none focus:ring-2 focus:ring-ibad disabled:cursor-not-allowed disabled:opacity-60"
                          />
                        ) : (
                          <span className="min-w-20 border border-border bg-surface px-2 py-1 text-center text-xs font-semibold text-text">
                            {setting.displayValue}
                          </span>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              </section>
            ))}
          </div>
        </>
      )}
    </CollapsibleCard>
  )
}
