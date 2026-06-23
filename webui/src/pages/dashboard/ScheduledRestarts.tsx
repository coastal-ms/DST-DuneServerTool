import { useCallback, useEffect, useState } from 'react'
import { Icon } from '../../components/Icon'
import { ApiError } from '../../api/client'
import {
  getRestartSchedule,
  saveRestartSchedule,
  checkFuncomUpdate,
  testDiscordWebhook,
  type RestartSchedule,
} from '../../api/restartSchedule'

// Client-side sanity check for a Discord incoming-webhook URL. The server
// re-validates; this just gives fast inline feedback.
const WEBHOOK_RE = /^https:\/\/(?:(?:canary|ptb)\.)?discord(?:app)?\.com\/api\/webhooks\/\d+\/[\w-]+$/
// Optional "mention on alert" target: empty, the keyword everyone/here, a raw
// role id (17-20 digit snowflake), or a pasted <@&id> role mention.
const MENTION_RE = /^(?:@?(?:everyone|here)|<@&\d{17,20}>|\d{17,20})$/

// Spell the lead minutes the same way the in-game broadcast does, so the
// preview line matches what players will see.
const WORDS = [
  'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
  'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen',
  'seventeen', 'eighteen', 'nineteen',
]
const TENS: Record<number, string> = { 20: 'twenty', 30: 'thirty', 40: 'forty', 50: 'fifty', 60: 'sixty' }
const numberWords = (n: number): string => {
  if (n < 0 || n > 60) return String(n)
  if (n < 20) return WORDS[n]
  const t = Math.floor(n / 10) * 10
  const r = n % 10
  return r === 0 ? TENS[t] : `${TENS[t]}-${WORDS[r]}`
}

// Editable fields here previously used a non-existent `.input` class and so
// rendered borderless/transparent - they didn't look editable. This explicit
// style gives them a solid surface, a bright border, an accent focus ring and a
// hover hint so it's obvious they accept input. `[color-scheme:dark]` makes the
// native time picker's spinner/clock render light on our dark surface.
const FIELD_CLASS =
  'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border-bright text-text text-base ' +
  'hover:border-accent/60 focus:outline-none focus:ring-2 focus:ring-accent focus:border-accent ' +
  'transition-colors cursor-text [color-scheme:dark]'

export function ScheduledRestarts() {
  const [sched, setSched] = useState<RestartSchedule | null>(null)
  const [enabled, setEnabled] = useState(false)
  const [time, setTime] = useState('04:00')
  const [lead, setLead] = useState(10)
  const [discordEnabled, setDiscordEnabled] = useState(false)
  const [discordNotifyOnline, setDiscordNotifyOnline] = useState(false)
  const [discordNotifyOffline, setDiscordNotifyOffline] = useState(false)
  const [discordNotifyRestarting, setDiscordNotifyRestarting] = useState(false)
  const [discordNotifyUpdate, setDiscordNotifyUpdate] = useState(false)
  const [webhookInput, setWebhookInput] = useState('')
  const [webhookSet, setWebhookSet] = useState(false)
  const [clearWebhook, setClearWebhook] = useState(false)
  const [mention, setMention] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [checking, setChecking] = useState(false)
  const [testing, setTesting] = useState(false)
  const [msg, setMsg] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)
  const [expanded, setExpanded] = useState<boolean>(() => {
    try { return localStorage.getItem('dst.schedRestarts.expanded') === '1' } catch { return false }
  })

  const load = useCallback(async () => {
    setLoading(true)
    try {
      const s = await getRestartSchedule()
      setSched(s)
      setEnabled(s.enabled)
      setTime(s.time || '04:00')
      setLead(typeof s.broadcastLeadMinutes === 'number' ? s.broadcastLeadMinutes : 10)
      setDiscordEnabled(s.discordEnabled)
      setDiscordNotifyOnline(s.discordNotifyOnline)
      setDiscordNotifyOffline(s.discordNotifyOffline)
      setDiscordNotifyRestarting(s.discordNotifyRestarting)
      setDiscordNotifyUpdate(s.discordNotifyUpdate)
      setWebhookSet(s.discordWebhookSet)
      setWebhookInput('')
      setClearWebhook(false)
      setMention(s.discordMentionId || '')
    } catch (e) {
      setMsg({ kind: 'err', text: e instanceof ApiError ? e.message : 'Failed to load schedule.' })
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => { void load() }, [load])

  useEffect(() => {
    try { localStorage.setItem('dst.schedRestarts.expanded', expanded ? '1' : '0') } catch { /* ignore */ }
  }, [expanded])

  const webhookInputValid = webhookInput.trim() === '' || WEBHOOK_RE.test(webhookInput.trim())
  const mentionValid = mention.trim() === '' || MENTION_RE.test(mention.trim())
  // Will a webhook be stored after this save?
  const effectiveWebhookSet = clearWebhook ? false : (webhookSet || webhookInput.trim() !== '')

  const save = useCallback(async () => {
    setSaving(true)
    setMsg(null)
    try {
      const body: {
        enabled: boolean; time: string; broadcastLeadMinutes: number
        discordEnabled: boolean; discordNotifyOnline: boolean; discordNotifyOffline: boolean; discordNotifyRestarting: boolean; discordNotifyUpdate: boolean; discordWebhookUrl?: string; discordMentionId?: string
      } = { enabled, time, broadcastLeadMinutes: lead, discordEnabled, discordNotifyOnline, discordNotifyOffline, discordNotifyRestarting, discordNotifyUpdate, discordMentionId: mention.trim() }
      if (clearWebhook) body.discordWebhookUrl = ''
      else if (webhookInput.trim() !== '') body.discordWebhookUrl = webhookInput.trim()
      const s = await saveRestartSchedule(body)
      setSched(s)
      setDiscordEnabled(s.discordEnabled)
      setDiscordNotifyOnline(s.discordNotifyOnline)
      setDiscordNotifyOffline(s.discordNotifyOffline)
      setDiscordNotifyRestarting(s.discordNotifyRestarting)
      setDiscordNotifyUpdate(s.discordNotifyUpdate)
      setWebhookSet(s.discordWebhookSet)
      setWebhookInput('')
      setClearWebhook(false)
      setMention(s.discordMentionId || '')
      setMsg({ kind: 'ok', text: 'Schedule saved.' })
    } catch (e) {
      setMsg({ kind: 'err', text: e instanceof ApiError ? e.message : 'Save failed.' })
    } finally {
      setSaving(false)
    }
  }, [enabled, time, lead, discordEnabled, discordNotifyOnline, discordNotifyOffline, discordNotifyRestarting, discordNotifyUpdate, webhookInput, clearWebhook, mention])

  const runCheck = useCallback(async () => {
    setChecking(true)
    setMsg(null)
    try {
      const r = await checkFuncomUpdate()
      setMsg({ kind: r.available ? 'err' : 'ok', text: r.message })
      void load()
    } catch (e) {
      setMsg({ kind: 'err', text: e instanceof ApiError ? e.message : 'Update check failed.' })
    } finally {
      setChecking(false)
    }
  }, [load])

  const runTest = useCallback(async () => {
    setTesting(true)
    setMsg(null)
    try {
      const r = await testDiscordWebhook()
      setMsg({ kind: 'ok', text: r.message })
    } catch (e) {
      setMsg({ kind: 'err', text: e instanceof ApiError ? e.message : 'Test message failed.' })
    } finally {
      setTesting(false)
    }
  }, [])

  const discordDirty = !!sched && (sched.discordEnabled !== discordEnabled || sched.discordNotifyOnline !== discordNotifyOnline || sched.discordNotifyOffline !== discordNotifyOffline || sched.discordNotifyRestarting !== discordNotifyRestarting || sched.discordNotifyUpdate !== discordNotifyUpdate || webhookInput.trim() !== '' || clearWebhook || (sched.discordMentionId || '') !== mention.trim())
  const dirty = !!sched && (sched.enabled !== enabled || sched.time !== time || sched.broadcastLeadMinutes !== lead || discordDirty)
  const anyDiscordEvent = discordEnabled || discordNotifyOnline || discordNotifyOffline || discordNotifyRestarting || discordNotifyUpdate
  const canSave = dirty && webhookInputValid && mentionValid && !(anyDiscordEvent && !effectiveWebhookSet)

  return (
    <div className="card p-5">
      <button
        type="button"
        onClick={() => setExpanded(v => !v)}
        aria-expanded={expanded}
        className="w-full flex items-center justify-between gap-3 text-left"
      >
        <h2 className="text-sm font-semibold uppercase tracking-wider text-text-muted flex items-center gap-2">
          <Icon name={expanded ? 'ChevronDown' : 'ChevronRight'} size={14} className="text-text-dim" />
          <Icon name="CalendarClock" size={14} className="text-accent" /> Scheduled restarts
        </h2>
        <div className="flex items-center gap-2 flex-wrap justify-end">
          {!expanded && sched && (
            <span className="text-[11px] font-medium text-text-dim normal-case">
              {sched.enabled ? `Daily ${sched.time}` : 'Off'}
              {sched.enabled && sched.discordEnabled ? ' · Discord on' : ''}
            </span>
          )}
          {sched?.updateAvailable && (
            <span
              className="inline-flex items-center gap-1 text-[10px] font-semibold uppercase tracking-wider text-warning border border-warning/40 bg-warning/10 rounded px-1.5 py-0.5"
              title={`Funcom update available (installed ${sched.installedBuild || '?'}, latest ${sched.latestBuild || '?'}).`}
            >
              <Icon name="ArrowUpCircle" size={11} /> Server update available
            </span>
          )}
        </div>
      </button>

      {expanded && (
        <div className="mt-4">
          <div className="flex items-start gap-2 text-xs text-warning bg-warning/10 border border-warning/30 rounded-md px-3 py-2 mb-4">
            <Icon name="Info" size={14} className="mt-0.5 shrink-0" />
            <span>
              This runs inside the Dune Server Tool, so scheduled restarts only fire while
              <span className="font-semibold"> DST is open and running</span> on this PC. Closing the tool
              pauses the schedule.
            </span>
          </div>

          {loading ? (
        <p className="text-sm text-text-dim italic">Loading…</p>
      ) : (
        <>
          <div className="flex flex-col gap-4">
            <label className="flex items-center gap-3 cursor-pointer select-none">
              <input
                type="checkbox"
                checked={enabled}
                onChange={e => setEnabled(e.target.checked)}
                className="h-4 w-4 accent-accent"
              />
              <span className="text-sm font-medium">Enable daily restart</span>
            </label>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div>
                <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">
                  Restart time (local)
                </label>
                <input
                  type="time"
                  value={time}
                  onChange={e => setTime(e.target.value)}
                  aria-label="Daily restart time"
                  className={FIELD_CLASS}
                />
                <p className="text-[11px] text-text-dim mt-1">One restart per day at this time (this PC's clock).</p>
              </div>
              <div>
                <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">
                  Broadcast lead (minutes)
                </label>
                <input
                  type="number"
                  min={0}
                  max={60}
                  value={lead}
                  onChange={e => setLead(Math.max(0, Math.min(60, Number(e.target.value) || 0)))}
                  aria-label="Broadcast lead minutes"
                  className={FIELD_CLASS}
                />
                <p className="text-[11px] text-text-dim mt-1">0 = no advance notice.</p>
              </div>
            </div>

            {lead > 0 && (
              <div className="text-xs text-text-dim bg-bg-dim border border-border/50 rounded-md px-3 py-2">
                <div className="font-semibold text-text-muted mb-0.5">In-game notice preview</div>
                <div className="font-mono text-[11px]"><span className="text-accent">Game Server Restart</span> — The game
                  server will be restarting in {numberWords(lead)} minute{lead === 1 ? '' : 's'} for our scheduled daily BG
                  maintenance.</div>
              </div>
            )}

            {/* Discord notifications */}
            <div className="border-t border-border/50 pt-4 mt-1">
              <h3 className="text-sm font-medium flex items-center gap-2 mb-2">
                <Icon name="MessageSquare" size={14} className="text-accent" /> Discord Notifications
              </h3>
              <p className="text-[11px] text-text-dim mb-4">
                Push server state alerts to a Discord channel. Create an Incoming Webhook in Discord (Channel → Edit → Integrations → Webhooks → New Webhook → Copy URL).
              </p>

              <div className="flex flex-col gap-2 mb-4">
                <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">
                  Discord webhook URL
                </label>
                <input
                  type="password"
                  value={webhookInput}
                  onChange={e => { setWebhookInput(e.target.value); setClearWebhook(false) }}
                  placeholder={webhookSet && !clearWebhook ? 'Webhook saved ••••••••  (type to replace)' : 'https://discord.com/api/webhooks/…'}
                  autoComplete="off"
                  aria-label="Discord webhook URL"
                  className={FIELD_CLASS}
                />
                <div className="flex items-center justify-between gap-2 mt-1 flex-wrap">
                  <p className="text-[11px] text-text-dim">
                    {clearWebhook
                      ? 'Saved webhook will be removed on save.'
                      : webhookSet
                        ? 'A webhook is stored. Leave blank to keep it.'
                        : 'Paste your channel webhook URL.'}
                  </p>
                  {webhookSet && !clearWebhook && (
                    <button
                      type="button"
                      onClick={() => {
                        setClearWebhook(true)
                        setWebhookInput('')
                        setDiscordEnabled(false)
                        setDiscordNotifyOnline(false)
                        setDiscordNotifyOffline(false)
                        setDiscordNotifyRestarting(false)
                        setDiscordNotifyUpdate(false)
                      }}
                      className="text-[11px] text-danger hover:underline"
                    >
                      Remove saved webhook
                    </button>
                  )}
                </div>
                {!webhookInputValid && (
                  <p className="text-[11px] text-danger mt-1">That doesn't look like a Discord webhook URL.</p>
                )}
              </div>

              {effectiveWebhookSet && (
                <div className="flex flex-col gap-3 mb-4 p-3 bg-surface-2 rounded-lg border border-border/50">
                  <label className="flex items-start gap-3 cursor-pointer select-none">
                    <input
                      type="checkbox"
                      checked={discordEnabled}
                      onChange={e => setDiscordEnabled(e.target.checked)}
                      className="h-4 w-4 accent-accent mt-0.5"
                    />
                    <div>
                      <span className="text-sm font-medium block leading-none">Advance Warning</span>
                      <span className="text-[11px] text-text-dim mt-1 block">Posts a "restart imminent" message {lead > 0 ? `${lead} minutes` : 'right'} before a scheduled restart.</span>
                    </div>
                  </label>
                  <label className="flex items-start gap-3 cursor-pointer select-none">
                    <input
                      type="checkbox"
                      checked={discordNotifyOnline}
                      onChange={e => setDiscordNotifyOnline(e.target.checked)}
                      className="h-4 w-4 accent-accent mt-0.5"
                    />
                    <div>
                      <span className="text-sm font-medium block leading-none">Online</span>
                      <span className="text-[11px] text-text-dim mt-1 block">When Hagga Basin finishes loading and the server is joinable.</span>
                    </div>
                  </label>
                  <label className="flex items-start gap-3 cursor-pointer select-none">
                    <input
                      type="checkbox"
                      checked={discordNotifyOffline}
                      onChange={e => setDiscordNotifyOffline(e.target.checked)}
                      className="h-4 w-4 accent-accent mt-0.5"
                    />
                    <div>
                      <span className="text-sm font-medium block leading-none">Offline</span>
                      <span className="text-[11px] text-text-dim mt-1 block">When the server has been down for more than a minute (a quick restart won't trigger it).</span>
                    </div>
                  </label>
                  <label className="flex items-start gap-3 cursor-pointer select-none">
                    <input
                      type="checkbox"
                      checked={discordNotifyRestarting}
                      onChange={e => setDiscordNotifyRestarting(e.target.checked)}
                      className="h-4 w-4 accent-accent mt-0.5"
                    />
                    <div>
                      <span className="text-sm font-medium block leading-none">Restarting</span>
                      <span className="text-[11px] text-text-dim mt-1 block">When the server drops offline to restart (start of a restart cycle).</span>
                    </div>
                  </label>
                  <label className="flex items-start gap-3 cursor-pointer select-none">
                    <input
                      type="checkbox"
                      checked={discordNotifyUpdate}
                      onChange={e => setDiscordNotifyUpdate(e.target.checked)}
                      className="h-4 w-4 accent-accent mt-0.5"
                    />
                    <div>
                      <span className="text-sm font-medium block leading-none">Update Available</span>
                      <span className="text-[11px] text-text-dim mt-1 block">When the scheduled-restart update check finds a new Funcom build.</span>
                    </div>
                  </label>
                  <div className="flex items-start gap-2 mt-1 pt-2 border-t border-border/50 text-[11px] text-text-dim">
                    <Icon name="Info" size={13} className="mt-0.5 flex-none text-text-muted" />
                    <span>
                      Online / Offline / Restarting are detected while the Dune Server Tool is running, and only for the server it manages. Starting, stopping, or restarting the battlegroup directly on the VM (via <code>battlegroup.bat</code>) — or any change made while DST is closed — won't be detected. Use DST's own Server Health commands and Scheduled Restarts so these fire reliably.
                    </span>
                  </div>
                </div>
              )}

              {effectiveWebhookSet && (
                <div className="flex flex-col gap-2">
                  <div>
                    <label className="block text-xs uppercase tracking-wider text-text-dim mb-1">
                      Mention on alert <span className="normal-case text-text-dim">(optional)</span>
                    </label>
                    <input
                      type="text"
                      value={mention}
                      onChange={e => setMention(e.target.value)}
                      placeholder="Role ID, or everyone / here"
                      autoComplete="off"
                      aria-label="Discord mention on alert"
                      className={FIELD_CLASS}
                    />
                    <p className="text-[11px] text-text-dim mt-1">
                      Pings a role when the alert posts. Paste a role ID (Discord → enable Developer Mode → right-click the role → Copy Role ID), or type <code>everyone</code> or <code>here</code>. Leave blank for no ping.
                    </p>
                    {!mentionValid && (
                      <p className="text-[11px] text-danger mt-1">Enter a role ID (17–20 digits), or the keyword everyone or here.</p>
                    )}
                  </div>

                  <div>
                    <button
                      type="button"
                      onClick={() => { void runTest() }}
                      disabled={testing || !webhookSet || webhookInput.trim() !== '' || clearWebhook || discordDirty}
                      className="btn-secondary"
                      title={
                        !webhookSet || webhookInput.trim() !== '' || clearWebhook
                          ? 'Save a webhook URL first, then send a test message.'
                          : discordDirty
                            ? 'Save your changes first — the test sends a sample of each currently-saved notification.'
                            : 'Sends a sample of each enabled notification (online / offline / restarting / update) to your Discord channel.'
                      }
                    >
                      <Icon name="Send" size={14} className={testing ? 'animate-pulse' : ''} /> {testing ? 'Sending…' : 'Send test message'}
                    </button>
                    <p className="text-[11px] text-text-dim mt-1">
                      Sends one sample message for each notification you have enabled above, so you can see exactly what each will look like.
                    </p>
                  </div>
                </div>
              )}
            </div>
          </div>

          {msg && (
            <p className={`text-xs mt-3 break-words ${msg.kind === 'ok' ? 'text-success' : 'text-danger'}`}>{msg.text}</p>
          )}

          <div className="flex items-center justify-between gap-3 mt-4 flex-wrap">
            <button
              type="button"
              onClick={() => { void runCheck() }}
              disabled={checking}
              className="btn-secondary"
              title="Check now whether Funcom has released a server update (non-destructive). Otherwise this runs automatically during each scheduled restart."
            >
              <Icon name="RefreshCw" size={14} className={checking ? 'animate-spin' : ''} /> Check for server update
            </button>
            <button
              type="button"
              onClick={() => { void save() }}
              disabled={saving || !canSave}
              className="btn-primary"
            >
              <Icon name="Save" size={15} /> {saving ? 'Saving…' : 'Save schedule'}
            </button>
          </div>

          {sched?.updateCheckedAt && (
            <p className="text-[11px] text-text-dim mt-2">
              Last update check: {new Date(sched.updateCheckedAt).toLocaleString()}
              {sched.installedBuild ? ` · installed build ${sched.installedBuild}` : ''}
              {sched.latestBuild ? ` · latest ${sched.latestBuild}` : ''}
            </p>
          )}
        </>
          )}
        </div>
      )}
    </div>
  )
}
