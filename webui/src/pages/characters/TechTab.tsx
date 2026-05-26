// Tech tab — bulk Unlock All / Lock All Recipes, both gated by ConfirmDialog.
import { useState } from 'react'
import { Icon } from '../../components/Icon'
import { ConfirmDialog, SectionCard, Toast } from './Shared'
import { techLockAll, techUnlockAll } from '../../api/characters'

type Props = { charId: number; charName: string }

export function TechTab({ charId, charName }: Props) {
  const [pending, setPending] = useState<null | 'unlock' | 'lock'>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  async function run(mode: 'unlock' | 'lock') {
    setPending(null); setOk(null); setErr(null)
    try {
      if (mode === 'unlock') await techUnlockAll(charId)
      else                   await techLockAll(charId)
      setOk(mode === 'unlock' ? 'All recipes unlocked.' : 'All recipes locked.')
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    }
  }

  return (
    <SectionCard title="Tech Tree" icon="Wrench">
      <Toast kind="error" message={err} onClear={() => setErr(null)} />
      <Toast kind="success" message={ok} onClear={() => setOk(null)} />
      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        <button type="button" className="btn-primary justify-center py-3" onClick={() => setPending('unlock')}>
          <Icon name="Unlock" size={16} /> Unlock All Recipes
        </button>
        <button type="button" className="btn-danger justify-center py-3" onClick={() => setPending('lock')}>
          <Icon name="Lock" size={16} /> Lock All Recipes
        </button>
      </div>
      <p className="text-xs text-text-dim mt-4">
        Bulk-updates the <code className="font-mono">TechKnowledgePlayerComponent</code> JSONB.
        Tech points are not consumed by Unlock — set them on the Stats tab separately.
      </p>

      <ConfirmDialog
        open={pending === 'unlock'}
        title="Unlock all recipes?"
        message={<>This sets every tech entry on <strong>{charName || `character #${charId}`}</strong> to Purchased. Continue?</>}
        confirmLabel="Unlock All"
        confirmIcon="Unlock"
        onCancel={() => setPending(null)}
        onConfirm={() => run('unlock')}
      />
      <ConfirmDialog
        open={pending === 'lock'}
        danger
        title="Lock all recipes?"
        message={<>This resets every tech entry on <strong>{charName || `character #${charId}`}</strong> to NotPurchased. Continue?</>}
        confirmLabel="Lock All"
        confirmIcon="Lock"
        onCancel={() => setPending(null)}
        onConfirm={() => run('lock')}
      />
    </SectionCard>
  )
}
