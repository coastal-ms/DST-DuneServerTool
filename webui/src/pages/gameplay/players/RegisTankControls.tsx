import { useEffect, useState } from 'react'
import { api } from '../../../api/client'

export function RegisTankControls({ actorId, online, busy, onGrant }: {
  actorId: number; online: boolean; busy: boolean
  onGrant: (template: 'T6_CombatDart' | 'T6_CombatFire') => void
}) {
  const [support, setSupport] = useState<{ enabled: boolean; message: string } | null>(null)
  useEffect(() => {
    let current = true
    setSupport(null)
    api<{ enabled: boolean; message: string }>('/api/gameplay/vehicles/regis-tanks')
      .then(result => { if (current) setSupport(result) })
      .catch(error => { if (current) setSupport({ enabled: false, message: error instanceof Error ? error.message : String(error) }) })
    return () => { current = false }
  }, [actorId])
  return <div className="space-y-3">
    <p className="text-xs text-text-muted">{support?.message ?? 'Checking Tank compatibility…'}</p>
    <p className="text-xs text-text-muted">Grants a persistent Tank with player ownership. Pink weapon effects, missing audio and incomplete module labels are known game-content limitations.</p>
    {!online && <p className="text-xs text-text-muted">The player must be online in Hagga.</p>}
    <div className="flex flex-wrap gap-2">
      <button type="button" className="btn-primary" disabled={busy || !online || !support?.enabled} onClick={() => onGrant('T6_CombatDart')}>Grant Dart Tank</button>
      <button type="button" className="btn-primary" disabled={busy || !online || !support?.enabled} onClick={() => onGrant('T6_CombatFire')}>Grant Flamethrower Tank</button>
    </div>
  </div>
}
