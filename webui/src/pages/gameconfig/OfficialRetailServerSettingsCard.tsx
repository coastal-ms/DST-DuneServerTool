import { useContext, useEffect, useMemo, useRef, useState } from 'react'
import { SettingsApplyContext, useSettingsDraft } from './settingsApplyContext'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { Icon } from '../../components/Icon'
import { getRetailServerSettings, saveRetailServerSettings } from '../../api/gameconfig'
import type { RetailServerSetting, RetailServerSettingsResponse } from '../../api/types'
import { RESPAWN_SETTING_GUIDANCE } from '../../util/respawnSettingGuidance'

const INTEGER_SLIDER_MIN = 0
const FLOAT_SLIDER_MIN = 0
const NUMERIC_SLIDER_MAX = 10
const FLOAT_DECIMAL_PLACES = 6

type RetailSettingGuidance = {
  defaultValue: string
  effect: string
}

// Patch 1.5 default values from Red-Blink/dune-awakening-selfhost-docker at acc3d43c.
// Reviewed against CubeCoders AMPTemplates aa716232 (including its newer 16-hour backup default).
// Effect descriptions are DST guidance, not verbatim Funcom documentation.
export const RETAIL_SETTING_GUIDANCE: Record<string, RetailSettingGuidance> = {
  DifficultyLevel: { defaultValue: 'Custom', effect: 'DST supports only Custom mode for managed server settings. Difficulty Level is not adjustable here. Other presets can override these values and must be configured manually outside DST.' },
  PVPMode: { defaultValue: 'Limited', effect: 'Controls where and under which rules player-versus-player combat is allowed.' },
  GatheringAmount: { defaultValue: '1.000000', effect: 'Higher values yield more resources per gathering action; lower values yield less. The server template identifies this as overlapping the Advanced hand-mining and vehicle-mining multipliers. These are all server settings; different values are not reconciled automatically, and their in-game precedence has not been verified.' },
  CraftingCost: { defaultValue: '1.000000', effect: 'Higher values require more crafting materials; lower values require fewer materials.' },
  WaterExtractionRate: { defaultValue: '1.000000', effect: 'Scales water extraction. Current AMP guidance says higher values extract faster; older Funcom configuration comments say the opposite. Direction has not been verified in-game.' },
  CraftingTimeMultiplier: { defaultValue: '1.000000', effect: 'Higher values make crafting take longer; lower values make it faster.' },
  BuildingCostMultiplier: { defaultValue: '1.000000', effect: 'Higher values require more building materials; lower values require fewer materials.' },
  ResourceRespawnSpeed: { defaultValue: '1.000000', effect: RESPAWN_SETTING_GUIDANCE.ResourceRespawnSpeed.effect },
  LootRespawnSpeed: { defaultValue: '1.000000', effect: RESPAWN_SETTING_GUIDANCE.LootRespawnSpeed.effect },
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
  bEnableItemMaxDurabilityLoss: { defaultValue: 'True', effect: 'Enabled allows repairs to reduce an item\'s maximum durability; disabled preserves its maximum.' },
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
  BaseBackupToolTimeRestriction: { defaultValue: '16.000000', effect: 'Window in hours after a base was built or last backed up during which its sub-fief console can still be backed up. Higher values allow a longer window. This is not a cooldown between backups.' },
  LandsraadContributionMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase Landsraad contribution gains; lower values reduce them.' },
  LandsraadSpecializationXpMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase Landsraad specialization XP; lower values reduce it.' },
  LandsraadFactionStandingMultiplier: { defaultValue: '1.000000', effect: 'Higher values increase Landsraad faction standing gains; lower values reduce them.' },
  bLandsraadDisableDecreeRerollLimit: { defaultValue: 'False', effect: 'Enabled removes the Landsraad decree reroll limit; disabled keeps the limit.' },
}

function normalizeSettingValue(setting: RetailServerSetting, value: string): string {
  if (!value.trim()) return value
  if (setting.type === 'bool' && /^(true|false)$/i.test(value)) {
    return value.toLowerCase() === 'true' ? 'True' : 'False'
  }
  if (setting.type !== 'float') return value
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed.toFixed(FLOAT_DECIMAL_PLACES) : value
}

// Defaults can set the required difficulty and initialize an absent PvP mode;
// neither read-only field becomes a freely editable control.
function isDefaultSettingUpdate(setting: RetailServerSetting, value: string): boolean {
  return setting.supported && (
    (setting.key === 'DifficultyLevel' && value === 'Custom')
    || (setting.key === 'PVPMode' && setting.present === false && value === 'Limited')
  )
}

function getDraftValidationError(setting: RetailServerSetting, value: string): string | null {
  if (!value.trim()) return null // Clearing removes the server-file entry on apply.
  if (setting.type === 'float') return value.trim() && Number.isFinite(Number(value)) ? null : `${setting.label} must be a finite number.`
  if (setting.type !== 'int') return null
  const parsed = Number(value)
  return /^-?\d+$/.test(value) && Number.isFinite(parsed) && Number.isInteger(parsed)
    ? null
    : `${setting.label} must be a finite whole integer.`
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
  const sliderMax = setting.key === 'CraftingTimeMultiplier' ? 5 : NUMERIC_SLIDER_MAX
  const showSlider = setting.key !== 'BaseBackupToolTimeRestriction'
  const parsedValue = Number(value)
  const sourceValue = Number(setting.value)
  const sliderSource = Number.isFinite(parsedValue)
    ? parsedValue
    : (Number.isFinite(sourceValue) ? sourceValue : sliderMin)
  const sliderValue = Math.min(sliderMax, Math.max(sliderMin, sliderSource))
  const belowSliderRange = Number.isFinite(parsedValue) && parsedValue < sliderMin
  const aboveSliderRange = Number.isFinite(parsedValue) && parsedValue > sliderMax
  const sliderStep = setting.type === 'int' ? 1 : 0.1
  const inputStep = setting.type === 'int' ? 1 : 'any'
  const rangeDescription = `${sliderMin} to ${sliderMax}`
  const sliderDisplayValue = setting.type === 'float'
    ? String(Number(sliderValue.toFixed(FLOAT_DECIMAL_PLACES)))
    : String(sliderValue)
  const controls = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const element = controls.current
    if (!element) return
    const onWheel = (event: WheelEvent) => {
      const input = event.target
      if (disabled || event.ctrlKey || event.metaKey || !(input instanceof HTMLInputElement) || input !== document.activeElement
        || !['number', 'range'].includes(input.type) || !event.deltaY || !value.trim()) return
      const current = Number(input.type === 'range' ? input.value : value)
      if (!Number.isFinite(current)) return
      event.preventDefault()
      const next = current + (event.deltaY < 0 ? sliderStep : -sliderStep)
      const bounded = input.type === 'range' ? Math.min(sliderMax, Math.max(sliderMin, next)) : next
      onChange(setting.type === 'float' ? bounded.toFixed(FLOAT_DECIMAL_PLACES) : String(bounded))
    }
    // Native non-passive handling prevents a single wheel event from both
    // editing a focused control and scrolling the page / taking a browser step.
    element.addEventListener('wheel', onWheel, { passive: false })
    return () => element.removeEventListener('wheel', onWheel)
  }, [disabled, onChange, setting.type, sliderMax, sliderMin, sliderStep, value])

  return (
    <div ref={controls} className="flex w-full min-w-0 flex-wrap items-center justify-end gap-2">
      {showSlider && setting.valid && value.trim() !== '' && (
        <div className="flex min-w-0 flex-[1_1_220px] items-center gap-2">
          <input
            aria-label={`${setting.label} slider, range ${rangeDescription}`}
            aria-valuetext={aboveSliderRange || belowSliderRange
              ? `${sliderValue}, slider ${aboveSliderRange ? 'maximum' : 'minimum'}; exact value ${value} is preserved`
              : sliderDisplayValue}
            type="range"
            data-settings-fine-wheel="true"
            min={sliderMin}
            max={sliderMax}
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
              ? `${sliderMax} / ${sliderMax} max`
              : belowSliderRange
                ? `${sliderDisplayValue} / ${sliderMax} min`
                : `${sliderDisplayValue} / ${sliderMax}`}
          </span>
        </div>
      )}
      <input
        aria-label={`${setting.label} exact value`}
        type="number"
        data-settings-fine-wheel="true"
        inputMode={setting.type === 'int' ? 'numeric' : 'decimal'}
        step={inputStep}
        value={value}
        onChange={event => onChange(event.target.value)}
        onBlur={onCommit}
        disabled={disabled}
        title={showSlider ? `Exact value ${value}. Values outside the slider's ${rangeDescription} convenience range remain unchanged.` : 'Backup window in hours. No documented maximum; existing values are preserved.'}
        className="w-28 max-w-full shrink-0 border border-border bg-surface px-2 py-1 text-right font-mono text-xs tabular-nums text-text focus:outline-none focus:ring-2 focus:ring-ibad disabled:cursor-not-allowed disabled:opacity-60"
      />
    </div>
  )
}

export function OfficialRetailServerSettingsCard({
  vmRunning,
  statusRefreshKey,
  onActionStateChange,
}: {
  vmRunning: boolean
  statusRefreshKey?: string
  onActionStateChange?: (busy: boolean) => void
}) {
  const coordinated = useContext(SettingsApplyContext)
  const [state, setState] = useState<RetailServerSettingsResponse | null>(null)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const [values, setValues] = useState<Record<string, string>>({})
  const loadRequest = useRef<{ sequence: number; controller: AbortController | null }>({
    sequence: 0,
    controller: null,
  })
  const automaticRefreshKey = coordinated ? undefined : statusRefreshKey

  const load = async (source?: 'operator') => {
    if (!vmRunning) return
    const sequence = loadRequest.current.sequence + 1
    loadRequest.current.sequence = sequence
    loadRequest.current.controller?.abort()
    const controller = new AbortController()
    loadRequest.current.controller = controller
    onActionStateChange?.(true)
    setLoading(true)
    setError(null)
    setMessage(null)
    try {
      const next = await getRetailServerSettings(controller.signal, source)
      if (controller.signal.aborted || sequence !== loadRequest.current.sequence) return
      setState(next)
      setValues(Object.fromEntries(
        (next.settings ?? []).map(setting => [setting.key, normalizeSettingValue(setting, setting.value)]),
      ))
      if (source === 'operator') setMessage('Current YAML settings loaded as a draft. Save writes them into the Linux UserSettings file.')
    } catch (e) {
      if (controller.signal.aborted || sequence !== loadRequest.current.sequence) return
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      if (sequence === loadRequest.current.sequence) {
        loadRequest.current.controller = null
        setLoading(false)
        onActionStateChange?.(false)
      }
    }
  }

  useEffect(() => {
    void load()
    const requests = loadRequest.current
    // The card owns its endpoint so it can move to a dedicated page without
    // changing the Retail settings API or coupling to legacy Game Config state.
    return () => requests.controller?.abort()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [vmRunning, automaticRefreshKey])

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
      .filter(({ setting, current, draft }) =>
        (setting.editable || isDefaultSettingUpdate(setting, draft)) && draft !== current,
      )
      .map(({ setting, draft }) => [setting.key, draft]),
  ), [state, values])
  const dirtyCount = Object.keys(updates).length + (state?.operatorRevision ? 1 : 0)
  const draftValidationErrors = useMemo(() => Object.fromEntries(
    (state?.settings ?? [])
      .filter(setting => setting.editable)
      .map(setting => [
        setting.key,
        getDraftValidationError(setting, values[setting.key] ?? setting.value),
      ])
      .filter((entry): entry is [string, string] => entry[1] !== null),
  ), [state, values])
  const hasDraftValidationErrors = Object.keys(draftValidationErrors).length > 0
  const canSave = state?.available === true
    && state.target.stopped === true
    && state.target.serverPodCount === 0
    && dirtyCount > 0
    && !hasDraftValidationErrors
    && !saving
    && !loading

  const applyDefaults = () => {
    if (!state?.available || (!coordinated && (!state.target.stopped || state.target.serverPodCount !== 0)) || saving) return
    setValues(previous => {
      const next = { ...previous }
      for (const setting of state.settings) {
        const guidance = RETAIL_SETTING_GUIDANCE[setting.key]
        if (setting.supported && guidance
          && (setting.editable || isDefaultSettingUpdate(setting, guidance.defaultValue))) {
          next[setting.key] = normalizeSettingValue(setting, guidance.defaultValue)
        }
      }
      return next
    })
    setError(null)
    setMessage('Default settings and Custom difficulty loaded as a draft. Review the changes, then use Save to apply them.')
  }

  const save = async (fromReview = false) => {
    if (!state?.revision || (!fromReview && !canSave)) return
    onActionStateChange?.(true)
    setSaving(true)
    setError(null)
    setMessage(null)
    try {
      const result = await saveRetailServerSettings(state.revision, updates, state.operatorRevision ?? undefined)
      const nextSettings = result.settings
      setState(previous => previous ? {
        ...previous,
        readOnly: false,
        source: 'funcom-persistent-user-settings',
        authority: 'Linux UserSettings/UserServerCustomSettings.ini',
        revision: result.revision,
        operatorRevision: null,
        operatorMismatch: false,
        sectionFound: true,
        settings: nextSettings,
        target: {
          ...previous.target,
          ...result.target,
          upstreamConfigured: true,
          upstreamMountPath: result.target?.upstreamMountPath
            ?? previous.target.upstreamMountPath
            ?? '/home/dune/server/DuneSandbox/Saved/Config/LinuxServer',
          upstreamFileName: 'ServerCustomSettings.ini',
        },
      } : previous)
      setValues(Object.fromEntries(
        nextSettings.map(setting => [setting.key, normalizeSettingValue(setting, setting.value)]),
      ))
      setMessage(`${result.applied} setting${result.applied === 1 ? '' : 's'} saved with backup ${result.backup.path}. Start the battlegroup to apply them.`)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
      if (fromReview) throw e
    } finally {
      setSaving(false)
      onActionStateChange?.(false)
    }
  }

  useSettingsDraft('official', {
    ready: state?.available === true && !!state.revision && !loading && !saving && !hasDraftValidationErrors,
    changes: [
      ...Object.entries(updates).map(([key, after]) => ({
        label: state?.settings.find(setting => setting.key === key)?.label ?? key,
        before: state?.settings.find(setting => setting.key === key)?.value ?? '', after: after.trim() ? after : 'Remove from server file',
        target: 'Server · ServerCustomSettings.ini · after start',
      })),
      ...(state?.operatorRevision ? [{ label: 'Import current deployment settings', before: 'Persistent file', after: 'Reviewed deployment values', target: 'Server · ServerCustomSettings.ini' }] : []),
    ],
    validate: async () => {
      const current = await getRetailServerSettings()
      if (!current.available || current.revision !== state?.revision) {
        throw new Error('Official settings changed outside this form. Refresh and review them before applying; your draft is still here.')
      }
    },
    apply: () => save(true),
  })

  return (
    <CollapsibleCard
      id="gameconfig.officialRetailServerSettings"
      icon="ServerCog"
      iconClassName="text-accent-bright shrink-0"
      title="Official server settings"
      titleClassName="text-sm font-semibold text-text"
      className="mb-4 border-accent/30"
      headerClassName="flex-wrap px-4 pt-4 pb-2"
      headerRightClassName="flex w-full flex-wrap items-center gap-2"
      bodyClassName="px-4 pb-4"
      headerRight={(
        <>
          <span className="pill-info" title="Reads and saves the persistent Linux UserSettings file">
            <Icon name="ShieldCheck" size={12} /> Linux file
          </span>
          <button
            type="button"
            className="btn-secondary"
            onClick={() => void load()}
            disabled={!vmRunning || loading || saving || dirtyCount > 0}
          >
            <Icon name={loading ? 'Loader2' : 'RefreshCw'} size={14} className={loading ? 'animate-spin' : ''} />
            Refresh
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={applyDefaults}
            disabled={!state?.available || (!coordinated && (!state.target.stopped || state.target.serverPodCount !== 0)) || saving || loading}
            title="Draft Custom difficulty and documented defaults, including missing settings, without saving"
          >
            <Icon name="RotateCcw" size={14} />
            Default Settings
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={() => void load('operator')}
            disabled={!vmRunning || loading || saving || dirtyCount > 0 || !state?.target.upstreamConfigured}
            title="Read current YAML settings as a draft; Save writes them into the Linux UserSettings file"
          >
            <Icon name="Download" size={14} />
            Read current settings
          </button>
          {dirtyCount > 0 && <button type="button" className="btn-secondary" disabled={saving || loading} onClick={() => {
            setValues(Object.fromEntries((state?.settings ?? []).map(setting => [setting.key, normalizeSettingValue(setting, setting.value)])))
            if (state?.operatorRevision) { void load() }
          }}>Discard draft</button>}
          <button
            type="button"
            className="btn-primary"
            onClick={() => coordinated ? coordinated.review() : void save()}
            disabled={coordinated ? dirtyCount === 0 || loading || saving || hasDraftValidationErrors : !canSave}
            title={hasDraftValidationErrors
              ? 'Correct invalid setting values before saving'
              : state?.target.stopped
                ? 'Save changed settings to the Linux UserSettings file'
              : 'Stop the battlegroup fully before saving'}
          >
            <Icon name={saving ? 'Loader2' : 'Save'} size={14} className={saving ? 'animate-spin' : ''} />
            {saving ? 'Saving…' : `${coordinated ? 'Review & Apply' : 'Save'}${dirtyCount ? ` (${dirtyCount})` : ''}`}
          </button>
        </>
      )}
    >
      <div className="mb-3 rounded-lg border border-warning/30 bg-warning/5 p-3 text-xs text-text-muted">
        <strong className="text-text">Official server controls · all players.</strong>{' '}
        Refresh reads manual edits to <span className="font-mono">UserSettings/UserServerCustomSettings.ini</span>.
        {coordinated ? ' Edit a draft, then Review & Apply saves it while the battlegroup is fully stopped.' : ' Save writes changes to that same file while the battlegroup is fully stopped.'}
        {' '}Starting the battlegroup synchronizes those values to its Linux runtime configuration when DST management is enabled.
      </div>
      {state?.operatorMismatch && (
        <div className="mb-3 rounded-lg border border-warning/30 bg-warning/5 p-3 text-xs text-warning" role="status">
          {state.operatorRevision
            ? 'Current YAML settings are loaded as a draft. Review them, then Save to write them into the Linux UserSettings file.'
            : 'The Linux UserSettings file and current YAML settings differ. Read current settings first to review the YAML values before saving.'}
        </div>
      )}
      {state?.available && !state.target.stopped && !coordinated && (
        <div className="mb-3 border-y border-border py-2 text-xs text-text-muted">
          Stop the battlegroup to unlock edits. Saving creates a timestamped copy of the complete current file;
          start the battlegroup afterward to mount the new settings into every game pod.
        </div>
      )}

      {!vmRunning && (
        <div className="text-sm text-text-muted">Start the battlegroup to read its official Retail Server Settings.</div>
      )}
      {error && (
        <div className="rounded-lg border border-danger/40 bg-danger/10 p-3 text-sm text-danger" role="alert">
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
            <div><span className="text-text-muted">Authoritative Linux file:</span> <span className="font-mono">{state.target.path}</span></div>
            <div><span className="text-text-muted">Game pod:</span> <span className="font-mono">{state.target.gamePath}</span></div>
            <div>
              <span className="text-text-muted">Source:</span> {state.authority}
              {state.modifiedAt ? ` • updated ${new Date(state.modifiedAt).toLocaleString()}` : ''}
            </div>
            {state.source === 'existing-operator-settings-pending-migration' && (
              <div className="text-warning">
                Existing YAML settings are preserved. The next stopped-battlegroup Save or Start backs them up
                and migrates them into the Linux file before file edits become authoritative.
              </div>
            )}
            {state.target.upstreamConfigured && (
              <div>
                <span className="text-text-muted">Operator mount:</span>{' '}
                <span className="font-mono">{state.target.upstreamMountPath?.replace(/\/+$/, '')}/{state.target.upstreamFileName}</span>
              </div>
            )}
          </div>

          {state.malformedLines.length > 0 && (
            <div className="mb-3 rounded-lg border border-warning/40 bg-warning/10 p-3 text-xs text-warning">
              {state.malformedLines.length} non-comment line{state.malformedLines.length === 1 ? '' : 's'} could not be parsed and remain visible only in the source file.
            </div>
          )}

          {state.settings.some(setting => setting.present === false) && (
            <div className="mb-3 border-y border-border py-2 text-xs text-text-muted">
              Settings marked Not configured are absent from the source file; their effective game values are not known.
              Enter a value or use Default Settings to draft Custom difficulty and the documented defaults, including missing settings.
              Only drafted changes are added when you save; no settings are written automatically.
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
                        {setting.present === false && (
                          <div className="mt-1 text-[11px] text-text-muted">Not configured in the source file.</div>
                        )}
                        {setting.inverted && setting.present !== false && (
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
                        {draftValidationErrors[setting.key] && (
                          <div className="mt-1 text-[11px] text-warning" role="alert">
                            {draftValidationErrors[setting.key]}
                          </div>
                        )}
                      </div>
                      <div className="flex min-w-0 flex-wrap items-center gap-2 lg:justify-end">
                        <span className="shrink-0 self-center text-[10px] uppercase tracking-wide text-text-dim">{setting.type}</span>
                        {setting.type === 'bool' && setting.editable ? (
                          <select
                            aria-label={setting.label}
                            value={values[setting.key] ?? setting.value}
                            onChange={event => setValues(previous => ({ ...previous, [setting.key]: event.target.value }))}
                            disabled={(!coordinated && (!state.target.stopped || state.target.serverPodCount !== 0)) || saving}
                            className="min-w-28 border border-border bg-surface px-2 py-1 text-xs font-semibold text-text disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            {setting.present === false && <option value="">Not configured</option>}
                            <option value={setting.inverted ? 'False' : 'True'}>Enabled</option>
                            <option value={setting.inverted ? 'True' : 'False'}>Disabled</option>
                          </select>
                        ) : setting.type === 'select' && setting.editable ? (
                          <select
                            aria-label={setting.label}
                            value={values[setting.key] ?? setting.value}
                            onChange={event => setValues(previous => ({ ...previous, [setting.key]: event.target.value }))}
                            disabled={(!coordinated && (!state.target.stopped || state.target.serverPodCount !== 0)) || saving}
                            className="min-w-36 border border-border bg-surface px-2 py-1 text-xs text-text disabled:cursor-not-allowed disabled:opacity-60"
                          >
                            {setting.present === false && <option value="">Not configured</option>}
                            {setting.options.map(option => <option key={option} value={option}>{option}</option>)}
                          </select>
                        ) : (setting.type === 'int' || setting.type === 'float') && setting.editable ? (
                          <NumericSettingControl
                            setting={setting}
                            value={values[setting.key] ?? setting.value}
                            disabled={(!coordinated && (!state.target.stopped || state.target.serverPodCount !== 0)) || saving}
                            onChange={value => setValues(previous => ({ ...previous, [setting.key]: value }))}
                            onCommit={() => setValues(previous => ({
                              ...previous,
                              [setting.key]: normalizeSettingValue(setting, previous[setting.key] ?? setting.value),
                            }))}
                          />
                        ) : (
                          <span className="min-w-20 border border-border bg-surface px-2 py-1 text-center text-xs font-semibold text-text">
                            {isDefaultSettingUpdate(setting, values[setting.key] ?? '')
                              ? values[setting.key] : setting.displayValue}
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
