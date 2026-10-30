import { useState } from 'react'
import { Icon } from './Icon'
import type { PlayerEvent } from '../api/gameplay'
import { fmtNum, fmtSolari } from '../pages/gameplay/shared'

function fmtTs(ts: string) { const d=new Date(ts); return Number.isNaN(d.getTime()) ? ts : d.toLocaleString() }
function communinetTitle(type: string, meta: Record<string,unknown>): string | undefined {
  const text=(key:string)=>typeof meta[key]==='string'?String(meta[key]):''
  const base=text('m_BaseName') || text('m_BuildableName') || 'Base'
  switch(type) {
    case 'communinet_0': return 'Character death'
    case 'communinet_10': return `${base}: building event`
    case 'communinet_13': return `${base}: shield ${text('m_TotemShieldState') || 'changed'}`
    case 'communinet_19': return `${base}: power ${text('m_StateChange') || 'changed'}`
    case 'communinet_95': {
      const seconds=Number(meta.m_PowerTimeLeftSeconds)
      const left=Number.isFinite(seconds)&&seconds>=0?` (${Math.floor(seconds/86400)}d ${Math.floor(seconds%86400/3600)}h ${Math.floor(seconds%3600/60)}m remaining)`:''
      return `${base}: running low on power${left}`
    }
    case 'communinet_97': return 'Base permissions changed'
    case 'communinet_98': return text('m_NewName') ? `Base renamed to ${text('m_NewName')}` : 'Base renamed'
    default: return type.startsWith('communinet_') ? 'Communinet event' : undefined
  }
}

export function CharacterActivityEvent({ ev }: { ev: PlayerEvent }) {
  const [open, setOpen] = useState(false)
  let metadata: Record<string, unknown> = {}
  try {
    const parsed: unknown = JSON.parse(ev.meta)
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) metadata = parsed as Record<string, unknown>
  } catch { /* An event can still be shown without optional details. */ }
  const number = (key: string) => {
    const value = metadata[key]
    return (typeof value === 'number' || (typeof value === 'string' && /^-?\d+(\.\d+)?$/.test(value))) && Number.isFinite(Number(value)) ? Number(value) : undefined
  }
  const delta = number('solaris_delta'), balance = number('solaris_balance')
  const title = ev.event_type === 'update_solaris'
    ? delta === undefined || delta === 0 ? 'Solari balance updated' : `${fmtNum(Math.abs(delta))} Solari ${delta < 0 ? 'removed' : 'added'}`
    : communinetTitle(ev.event_type, metadata) ?? ({login:'Logged in',logout:'Logged out'} as Record<string, string>)[ev.event_type] ?? 'Player activity recorded'
  const details = [
    ...['m_BaseName','m_BuildableName','m_OldName','m_NewName','m_OldPermissionRank','m_NewPermissionRank'].filter(key => typeof metadata[key] === 'string').map(key => [({m_BaseName:'Base',m_BuildableName:'Building',m_OldName:'Previous name',m_NewName:'New name',m_OldPermissionRank:'Previous permission',m_NewPermissionRank:'New permission'} as Record<string,string>)[key], String(metadata[key])]),
    ...(balance !== undefined ? [['Balance', fmtSolari(balance)]] : []),
    ...(typeof metadata.map === 'string' ? [['Location', metadata.map.replace(/([a-z])([A-Z])/g, '$1 $2').replaceAll('_', ' ')]] : []),
  ]
  return (
    <div className="card p-2.5 text-sm">
      <button type="button" onClick={() => setOpen(o => !o)} className="w-full flex items-center justify-between gap-2 text-left">
        <span className="flex items-center gap-2 min-w-0">
          <Icon name={open ? 'ChevronDown' : 'ChevronRight'} size={12} className="text-text-dim shrink-0" />
          <span className="text-text font-medium truncate">{title}</span>
        </span>
        <span className="text-[11px] text-text-dim font-mono shrink-0">{fmtTs(ev.ts)}</span>
      </button>
      {open && (
        <div className="mt-2 p-3 bg-surface-2 rounded-md text-sm">
          {details.length ? <dl className="space-y-2">{details.map(([label, value]) => <div key={label} className="flex flex-wrap justify-between gap-3"><dt className="text-text-muted">{label}</dt><dd>{value}</dd></div>)}</dl> : <p className="text-text-muted">No additional details were recorded.</p>}
        </div>
      )}
    </div>
  )
}
