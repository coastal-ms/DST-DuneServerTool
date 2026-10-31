import { mapLabel } from '../util/mapLabel'
export interface PlayerServerStatus {
 available: boolean
 state: string
 serverName?: string
 ready?: boolean
 maps?: {map: string; state: string; ready: boolean; players: number}[]
 ts?: string
}
export function PlayerGameServerCard({status}: {status: PlayerServerStatus | null}) {
 const label = !status ? 'Checking' : !status.available ? 'Unavailable' : status.ready ? 'Ready' : status.state === 'running' ? 'Starting' : status.state
 return <section className="card p-4" aria-label="Game server status">
  <div className="flex flex-wrap items-center gap-2 mb-3"><h2 className="font-semibold flex-1">Game Server{status?.serverName ? ` — ${status.serverName}` : ''}</h2><span className={status?.ready ? 'text-success' : 'text-text-muted'}>{label}</span></div>
  {!!status?.maps?.length ? <ul className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-2">
   {status.maps.map((map,index) => <li key={`${map.map}:${index}`} className="rounded-lg border border-border p-3 flex flex-wrap gap-2 items-center"><strong className="flex-1 text-sm">{mapLabel(map.map)}</strong><span className={map.ready ? 'text-success text-sm' : 'text-text-muted text-sm'}>{map.state}</span><span className="w-full text-xs text-text-dim">{map.players} player{map.players === 1 ? '' : 's'}</span></li>)}
  </ul> : <p className="text-sm text-text-muted">{status?.available ? 'No active maps.' : 'Map status is unavailable.'}</p>}
 </section>
}
