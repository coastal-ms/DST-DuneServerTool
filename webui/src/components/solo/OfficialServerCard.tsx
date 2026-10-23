import { useId, useRef, useState } from 'react'
import { Icon } from '../Icon'

const discordUrl = 'https://discord.gg/tTSG4fuHFZ'
const discordChannelUrl = 'https://discord.com/channels/1517599283757453333/1563241244396757102'
const features = [
  { icon: 'Sparkles', label: '2× combat & gathering XP' },
  { icon: 'Backpack', label: '3× inventory capacity' },
  { icon: 'ShieldCheck', label: 'Keep equipment on death' },
  { icon: 'ArchiveRestore', label: 'Deep Desert base backups' },
  { icon: 'UserRoundCog', label: 'Personal player portal' },
  { icon: 'BrainCircuit', label: '2× Intel points' },
]

export function OfficialServerCard() {
  const [showJoin, setShowJoin] = useState(false)
  const joinId = useId()
  const featuresDialog = useRef<HTMLDialogElement>(null)

  return (
    <section aria-labelledby={`${joinId}-title`} className="card p-5 xl:col-span-2">
      <div className="grid items-center gap-6 lg:grid-cols-[1fr_1.25fr_auto]">
        <div className="min-w-0">
          <div className="mb-2 flex items-center gap-2 text-accent">
            <Icon name="Users" size={20} />
            <span className="text-xs font-semibold uppercase tracking-wide">Free community multiplayer</span>
          </div>
          <h2 id={`${joinId}-title`} className="text-lg font-semibold">Join us on our DST Official Multiplayer Server</h2>
          <p className="mt-2 text-sm text-text-muted">PvE-focused Arrakis, together. We host, you play.</p>
        </div>

        <ul className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          {features.map(feature => (
            <li key={feature.label} className="flex min-h-11 items-center gap-2 rounded-lg border border-border px-3 py-2 text-sm">
              <Icon name={feature.icon} size={17} className="shrink-0 text-accent" />
              <span>{feature.label}</span>
            </li>
          ))}
        </ul>

        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-1">
          <button type="button" className="btn-secondary min-h-11 justify-center" onClick={() => featuresDialog.current?.showModal()}>
            <Icon name="List" size={16} /> View features
          </button>
          <button type="button" className="btn-primary min-h-11 justify-center" aria-expanded={showJoin} aria-controls={joinId} onClick={() => setShowJoin(value => !value)}>
            <Icon name="LogIn" size={16} /> How to join
          </button>
          <a href={discordUrl} target="_blank" rel="noopener noreferrer" className="btn-secondary min-h-11 justify-center">
            <Icon name="MessageCircle" size={16} /> Discord <Icon name="ExternalLink" size={14} />
          </a>
          <a href={discordChannelUrl} target="_blank" rel="noopener noreferrer" className="text-center text-xs text-text-muted underline underline-offset-2 sm:col-span-2 lg:col-span-1">Already a member? Open channel</a>
        </div>
      </div>

      {showJoin && (
        <div id={joinId} className="mt-5 border-t border-border pt-4 text-sm text-text-muted">
          <p>Find <strong className="text-text">DST Official</strong> in the in-game <strong className="text-text">Experimental</strong> server browser.</p>
          <p className="mt-2"><a href={discordUrl} target="_blank" rel="noopener noreferrer" className="text-accent underline underline-offset-2">Join our Discord</a> for access details, server rules and help getting started. No self-hosting needed.</p>
        </div>
      )}

      <dialog ref={featuresDialog} aria-labelledby={`${joinId}-features`} className="m-auto max-h-[85dvh] w-[calc(100%-2rem)] max-w-xl overflow-y-auto rounded-xl border border-border bg-surface p-5 text-text shadow-xl backdrop:bg-black/70">
        <div className="mb-4 flex items-center justify-between gap-4">
          <h2 id={`${joinId}-features`} className="text-lg font-semibold">DST Official server features</h2>
          <button type="button" className="btn-icon shrink-0" aria-label="Close features" onClick={() => featuresDialog.current?.close()}><Icon name="X" size={18} /></button>
        </div>
        <dl className="grid gap-4 text-sm sm:grid-cols-2">
          {[
            ['Faster progression', '2× combat XP, gathering XP and Intel points.'],
            ['More room to explore', '3× inventory capacity.'],
            ['Easier survival', '50% stamina drain and 20% less thirst.'],
            ['Keep your equipment', 'No equipment drops on death; other players cannot loot your death inventory.'],
            ['Sandworm recovery', 'Sandworm penalties disabled.'],
            ['Deep Desert base backups', 'Enabled on our server.'],
            ['Your own player portal', 'Manage your character, items and grants, with story/journey skips and trainer unlocks. Log out for saved-data edits.'],
            ['Vehicle kits', 'Grant yourself vehicle kits to assemble in game.'],
          ].map(([title, description]) => (
            <div key={title} className="rounded-lg border border-border p-3">
              <dt className="font-semibold">{title}</dt>
              <dd className="mt-1 text-text-muted">{description}</dd>
            </div>
          ))}
        </dl>
        <p className="mt-4 text-sm text-text-muted">Free community multiplayer, hosted by the DST team. <a href={discordUrl} target="_blank" rel="noopener noreferrer" className="text-accent underline underline-offset-2">Request a player portal login in our Discord</a>, or get server rules and help.</p>
      </dialog>
    </section>
  )
}
