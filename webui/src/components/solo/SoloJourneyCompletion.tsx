import { useState } from 'react'
import { Icon } from '../Icon'

export function SoloJourneyCompletion({ disabled, busy, progression, onRun }: {
  disabled: boolean
  busy: boolean
  progression?: { npeNodesComplete: number; npeNodesTotal: number; npeTagPresent: boolean; fremenNodesComplete: number; fremenNodesTotal: number; spiceSystemStatus: string }
  onRun: (quest: string) => void
}) {
  const [mainQuest, setMainQuest] = useState('DA_MQ_FindTheFremen')
  const SOLO_INPUT_CLASS = 'w-full px-3 py-2 rounded-lg bg-surface-2 border border-border text-text text-sm focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50 disabled:opacity-50 disabled:cursor-not-allowed'
  const SOLO_DISABLED_PRIMARY_CLASS = 'disabled:bg-surface-2 disabled:text-text-dim disabled:border disabled:border-border disabled:opacity-100'
  return (
    <div className="card p-5 flex flex-col">
      <div className="w-9 h-9 rounded-lg bg-accent/10 border border-accent/25 flex items-center justify-center text-accent-bright mb-3">
        <Icon name="Route" size={17} />
      </div>
      <h2 className="font-semibold">Journey completion</h2>
      <p className="text-sm text-text-muted mt-1">
        Complete a selected main quest or the full tutorial. Close Dune first; each action retains a backup.
      </p>
      <label className="mt-4" htmlFor="solo-main-quest">Progression path</label>
      <select id="solo-main-quest" className={`${SOLO_INPUT_CLASS} mt-1`}
        value={mainQuest} onChange={event => setMainQuest(event.target.value)}
        disabled={disabled || busy}>
        <option value="DA_MQ_FindTheFremen">Find the Fremen</option>
        <option value="npe">Full tutorial (NPE)</option>
        <option value="DA_MQ_ANewBeginning">A New Beginning (quest only)</option>
        <option value="DA_MQ_AssassinsHandbook">Assassin’s Handbook</option>
        <option value="DA_MQ_TheGreatConvention">The Great Convention</option>
        <option value="DA_MQ_TheGreatConventionPt2">The Great Convention (Pt. 2)</option>
      </select>
      <p className="text-xs text-text-muted mt-3 flex-1">
        {mainQuest === 'npe'
          ? 'Complete A New Beginning and the additional tutorial objectives, including the Base Backup Tool steps, and mark the full tutorial finished.'
          : mainQuest === 'DA_MQ_FindTheFremen'
            ? 'Complete all 59 verified nodes, add 14 reward tags and five Fremkit recipes, then enable Prescience and the third ability slot.'
            : mainQuest === 'DA_MQ_ANewBeginning'
              ? 'Complete this quest’s saved objectives only. Choose Full tutorial (NPE) to include the extra tutorial objectives and tutorial-finished flag.'
              : 'Complete the selected main quest’s saved objectives and apply its mapped progression tags.'}
      </p>
      {(mainQuest === 'npe' || mainQuest === 'DA_MQ_FindTheFremen') &&
        <div className="rounded border border-border bg-surface-2/50 px-3 py-2 text-xs text-text-muted mt-4">
          {mainQuest === 'npe'
            ? `${progression?.npeNodesComplete ?? 0}/${progression?.npeNodesTotal ?? 0} nodes · completion tag ${progression?.npeTagPresent ? 'present' : 'missing'}`
            : `${progression?.fremenNodesComplete ?? 0}/${progression?.fremenNodesTotal ?? 0} nodes · Prescience ${progression?.spiceSystemStatus === 'FullyEnabled' ? 'enabled' : 'locked'}`}
        </div>}
      <button className={`btn-primary w-full justify-center mt-4 ${SOLO_DISABLED_PRIMARY_CLASS}`}
        disabled={disabled || busy}
        onClick={() => onRun(mainQuest)}>
        {busy ? 'Applying...' : 'Complete selected journey'}
      </button>
    </div>
  )
}
