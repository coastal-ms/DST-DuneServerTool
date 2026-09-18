import { useEffect, useMemo, useState } from 'react'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { Icon } from '../../components/Icon'
import { getRetailServerSettings, saveRetailServerSettings } from '../../api/gameconfig'
import type { RetailServerSetting, RetailServerSettingsResponse } from '../../api/types'

const INTEGER_SLIDER_MIN = 0
const FLOAT_SLIDER_MIN = 0.1
const NUMERIC_SLIDER_MAX = 25
const FLOAT_DECIMAL_PLACES = 6

type RetailSettingGuidance = {
  defaultValue: string
  effect: string
}

// Patch 1.5 defaults from Red-Blink/dune-awakening-selfhost-docker at acc3d43c.
export const RETAIL_SETTING_GUIDANCE: Record<string, RetailSettingGuidance> = {
  DifficultyLevel: { defaultValue: 'Custom', effect: 'Selects the overall difficulty preset. Managed server settings use Custom.' },
  PVPMode: { defaultValue: 'Limited', effect: 'Controls where and under which rules player-versus-player combat is allowed.' },
  GatheringAmount: { defaultValue: '1.000000', effect: 'Higher values yield more resources per gathering action; lower values yield less.' },
  CraftingCost: { defaultValue: '1.000000', effect: 'Higher values require more crafting materials; lower values require fewer materials.' },
  WaterExtractionRate: { defaultValue: '1.000000', effect: 'Higher values extract water faster; lower values extract it slower.' },
  CraftingTimeMultiplier: { defaultValue: '1.000000', effect: 'Higher values make crafting take longer; lower values make it faster.' },
  BuildingCostMultiplier: { defaultValue: '1.000000', effect: 'Higher values require more building materials; lower values require fewer materials.' },
  ResourceRespawnSpeed: { defaultValue: '1.000000', effect: 'Higher values make world resources return faster; lower values make them return slower.' },
  LootRespawnSpeed: { defaultValue: '1.000000', effect: 'Higher values make loot return faster; lower values make it return slower.' },
  FuelBurnTimeMultiplier: { defaultValue: '1.000000', effect: 'Higher values make fuel last longer; lower values shorten its burn time.' },
  InventoryVolumeMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase inventory capacity; lower values reduce it.' },
  PlayerDamageToPlayer: { defaultValue: '1.000000', effect: 'Higher values increase player damage to other players; lower values reduce it.' },
  PlayerDamageToNPC: { defaultValue: '1.000000', effect: 'Higher values increase player damage to NPCs; lower values reduce it.' },
  PlayerDamageToVehicle: { defaultValue: '1.000000', effect: 'Higher values increase player damage to vehicles; lower values reduce it.' },
  PlayerStaminaDrain: { defaultValue: '1.000000', effect: 'Higher values drain stamina faster; lower values make stamina more forgiving.' },
  IntelPointsGainMultiplier: { defaultValue: '1.000000', effect: 'Higher values award Intel points faster; lower values slow Intel progression.' },
  NPCHealth: { defaultValue: '1.000000', effect: 'Higher values make NPCs tougher; lower values make them easier to defeat.' },
  NPCDamageToPlayer: { defaultValue: '1.000000', effect: 'Higher values make NPC attacks on players more damaging; lower values make them less damaging.' },
  NPCDamageToNPC: { defaultValue: '1.000000', effect: 'Higher values increase damage between NPCs; lower values reduce it.' },
  NPCRespawnMultiplier: { defaultValue: '1.000000', effect: 'Controls the multiplier used by NPC respawning.' },
  PVPDamageStructures: { defaultValue: '1.000000', effect: 'Higher values increase PvP damage to structures; lower values reduce it.' },
  GlobalXpMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase all XP gains; lower values slow overall progression.' },
  CombatXp: { defaultValue: '1.000000', effect: 'Higher values increase combat XP gains; lower values slow combat progression.' },
  GatheringXp: { defaultValue: '1.000000', effect: 'Higher values increase gathering XP gains; lower values slow gathering progression.' },
  MissionXp: { defaultValue: '1.000000', effect: 'Higher values increase mission XP rewards; lower values slow mission progression.' },
  ItemDurabilityDrainMultiplier: { defaultValue: '1.000000', effect: 'Higher values wear items faster; lower values make equipment last longer.' },
  bEnableItemMaxDurabilityLoss: { defaultValue: 'True', effect: 'Enabled allows items to lose maximum durability; disabled preserves their maximum.' },
  PlayerShieldDamageAbsorptionMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase damage absorbed by player shields; lower values reduce shield absorption.' },
  NPCShieldDamageAbsorptionMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase damage absorbed by NPC shields; lower values reduce shield absorption.' },
  HeatBuildupRate: { defaultValue: '1.000000', effect: 'Higher values build heat faster; lower values make heat exposure more forgiving.' },
  ColdBuildupRate: { defaultValue: '1.000000', effect: 'Higher values build cold faster; lower values make cold exposure more forgiving.' },
  ThirstMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase thirst faster; lower values make hydration more forgiving.' },
  DropEquipmentOnDeath: { defaultValue: 'Default', effect: 'Chooses how much carried equipment is dropped when a player dies.' },
  bAllowDynamicBuildingDamage: { defaultValue: 'True', effect: 'Enabled allows dynamic gameplay damage to affect buildings; disabled prevents that damage.' },
  bAllowSandstorms: { defaultValue: 'True', effect: 'Enabled allows sandstorms; disabled removes that world threat.' },
  bAllowSandworms: { defaultValue: 'True', effect: 'Enabled allows sandworms; disabled removes that world threat.' },
  SandwormConsequences: { defaultValue: 'All', effect: 'Chooses how much equipment is lost to sandworm consequences.' },
  PlayerDeathLootRule: { defaultValue: 'DependsOnSecurityZone', effect: 'Controls whether other players may loot a player death, including security-zone rules.' },
  bIsBuildingRestrictionsEnabled: { defaultValue: 'True', effect: 'Enabled enforces general building restrictions; disabled is less restrictive but does not remove permanent no-build zones.' },
  FiefdomLimit: { defaultValue: '3', effect: 'Higher values allow more sub-fiefs; lower values allow fewer.' },
  BuildingPieceLimitMultiplier: { defaultValue: '1.000000', effect: 'Higher values allow more building pieces; lower values allow fewer.' },
  bBuildingInfiniteStability: { defaultValue: 'False', effect: 'Enabled enforces building stability limits; disabled gives buildings infinite stability.' },
  BaseBackupToolTimeRestriction: { defaultValue: '10.000000', effect: 'Controls the time restriction applied to the base backup tool.' },
  LandsraadContributionMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase Landsraad contribution gains; lower values reduce them.' },
  LandsraadSpecializationXpMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase Landsraad specialization XP; lower values reduce it.' },
  LandsraadFactionStandingMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase Landsraad faction standing gains; lower values reduce them.' },
  bLandsraadDisableDecreeRerollLimit: { defaultValue: 'False', effect: 'Enabled removes the Landsraad decree reroll limit; disabled keeps the limit.' },
}

function normalizeSettingValue(setting: RetailServerSetting, value: string): string {
  if (setting.type !== 'float') return value
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed.toFixed(FLOAT_DECIMAL_PLACES) : value
}

function NumericSettingControl({
  setting,
  value,
  disabled,
  onChange,
  onCommit,
}: {
  setting: RetailServerSetting
  value: string
  disabled: boolean
  onChange: (value: string) => void
  onCommit: () => void
}) {
  const sliderMin = setting.type === 'float' ? FLOAT_SLIDER_MIN : INTEGER_SLIDER_MIN
  const parsedValue = Number(value)
  const sourceValue = Number(setting.value)
  const sliderSource = Number.isFinite(parsedValue)
    ? parsedValue
    : (Number.isFinite(sourceValue) ? sourceValue : sliderMin)
  const sliderValue = Math.min(NUMERIC_SLIDER_MAX, Math.max(sliderMin, sliderSource))
  const belowSliderRange = Number.isFinite(parsedValue) && parsedValue < sliderMin
  const aboveSliderRange = Number.isFinite(parsedValue) && parsedValue > NUMERIC_SLIDER_MAX
  const sliderStep = setting.type === 'int' ? 1 : 0.1
  const inputStep = setting.type === 'int' ? 1 : 'any'
  const rangeDescription = `${sliderMin} to ${NUMERIC_SLIDER_MAX}`
  const sliderDisplayValue = setting.type === 'float'
    ? sliderValue.toFixed(FLOAT_DECIMAL_PLACES)
    : String(sliderValue)

  return (
    <div className="flex w-full min-w-0 flex-wrap items-center justify-end gap-2">
      {setting.valid && (
        <div className="flex min-w-0 flex-[1_1_220px] items-center gap-2">
          <input
            aria-label={`${setting.label} slider, range ${rangeDescription}`}
            aria-valuetext={aboveSliderRange || belowSliderRange
              ? `${sliderValue}, slider ${aboveSliderRange ? 'maximum' : 'minimum'}; exact value ${value} is preserved`
              : sliderDisplayValue}
            type="range"
            min={sliderMin}
            max={NUMERIC_SLIDER_MAX}
            step={sliderStep}
            value={sliderValue}
            onChange={event => onChange(setting.type === 'float'
              ? Number(event.target.value).toFixed(FLOAT_DECIMAL_PLACES)
              : event.target.value)}
            disabled={disabled}
            title={`Adjust ${setting.label} from ${rangeDescription}. Use the exact value field for values outside this convenience range.`}
            className="h-1.5 min-w-0 flex-1 cursor-pointer accent-accent focus:outline-none focus-visible:ring-2 focus-visible:ring-ibad disabled:cursor-not-allowed disabled:opacity-60"
          />
          <span
            className="shrink-0 whitespace-nowrap text-right font-mono text-[11px] tabular-nums text-text-dim"
            title={aboveSliderRange || belowSliderRange
              ? `Slider is at its ${aboveSliderRange ? 'maximum' : 'minimum'}; exact value ${value} is preserved.`
              : undefined}
          >
            {aboveSliderRange
              ? `${NUMERIC_SLIDER_MAX} / ${NUMERIC_SLIDER_MAX} max`
              : belowSliderRange
                ? `${sliderDisplayValue} / ${NUMERIC_SLIDER_MAX} min`
                : `${sliderDisplayValue} / ${NUMERIC_SLIDER_MAX}`}
          </span>
        </div>
      )}
      <input
        aria-label={`${setting.label} exact value`}
        type="number"
        inputMode={setting.type === 'int' ? 'numeric' : 'decimal'}
        step={inputStep}
        value={value}
        onChange={event => onChange(event.target.value)}
        onBlur={onCommit}
        disabled={disabled}
        title={`Exact value ${value}. Values outside the slider's ${rangeDescription} convenience range remain unchanged.`}
        className="w-28 max-w-full shrink-0 border border-border bg-surface px-2 py-1 text-right font-mono text-xs tabular-nums text-text focus:outline-none focus:ring-2 focus:ring-ibad disabled:cursor-not-allowed disabled:opacity-60"
      />
    </div>
  )
}

export function OfficialRetailServerSettingsCard({
  vmRunning,
  statusRefreshKey,
}: {
  vmRunning: boolean
  statusRefreshKey?: string
}) {
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
    setMessage(null)
    try {
      const next = await getRetailServerSettings()
      setState(next)
      setValues(Object.fromEntries(
        (next.settings ?? []).map(setting => [setting.key, normalizeSettingValue(setting, setting.value)]),
      ))
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
  }, [vmRunning, statusRefreshKey])

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
      .map(setting => ({
        setting,
        current: normalizeSettingValue(setting, setting.value),
        draft: normalizeSettingValue(setting, values[setting.key] ?? setting.value),
      }))
      .filter(({ setting, current, draft }) => setting.editable && draft !== current)
      .map(({ setting, draft }) => [setting.key, draft]),
  ), [state, values])
  const dirtyCount = Object.keys(updates).length
  const canSave = state?.available === true
    && state.target.stopped === true
    && state.target.serverPodCount === 0
    && dirtyCount > 0
    && !saving

  const applyDefaults = () => {
    if (!state?.available || !state.target.stopped || state.target.serverPodCount !== 0 || saving) return
    setValues(previous => {
      const next = { ...previous }
      for (const setting of state.settings) {
        const guidance = RETAIL_SETTING_GUIDANCE[setting.key]
        if (setting.supported && setting.editable && guidance) {
          next[setting.key] = normalizeSettingValue(setting, guidance.defaultValue)
        }
      }
      return next
    })
    setError(null)
    setMessage('Default settings loaded as a draft. Review the changes, then use Save to apply them.')
  }

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
      setValues(Object.fromEntries(
        nextSettings.map(setting => [setting.key, normalizeSettingValue(setting, setting.value)]),
      ))
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
            className="btn-secondary"
            onClick={applyDefaults}
            disabled={!state?.available || !state.target.stopped || state.target.serverPodCount !== 0 || saving}
            title="Load Funcom Patch 1.5 defaults into this draft without saving"
          >
            <Icon name="RotateCcw" size={14} />
            Default Settings
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
                      className={`grid min-w-0 gap-2 border-b border-border/70 px-1 py-2.5 last:border-b-0 lg:grid-cols-[minmax(0,1fr)_minmax(16rem,24rem)] lg:items-center ${
                        !setting.supported || !setting.valid ? 'bg-warning/5' : ''
                      }`}
                    >
                      <div className="min-w-0">
                        <div className="text-sm font-medium text-text">{setting.label}</div>
                        <div className="mt-0.5 break-all font-mono text-[10px] text-text-dim">{setting.key}</div>
                        {RETAIL_SETTING_GUIDANCE[setting.key] && (
                          <div className="mt-1 max-w-prose text-[11px] leading-snug text-text-muted">
                            <span>{RETAIL_SETTING_GUIDANCE[setting.key].effect}</span>{' '}
                            <span className="whitespace-nowrap text-text-dim">
                              Funcom default: <span className="font-mono tabular-nums">{RETAIL_SETTING_GUIDANCE[setting.key].defaultValue}</span>.
                            </span>
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
                      <div className="flex min-w-0 flex-wrap items-center gap-2 lg:justify-end">
                        <span className="shrink-0 self-center text-[10px] uppercase tracking-wide text-text-dim">{setting.type}</span>
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
                          <NumericSettingControl
                            setting={setting}
                            value={values[setting.key] ?? setting.value}
                            disabled={!state.target.stopped || state.target.serverPodCount !== 0 || saving}
                            onChange={value => setValues(previous => ({ ...previous, [setting.key]: value }))}
                            onCommit={() => setValues(previous => ({
                              ...previous,
                              [setting.key]: normalizeSettingValue(setting, previous[setting.key] ?? setting.value),
                            }))}
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
