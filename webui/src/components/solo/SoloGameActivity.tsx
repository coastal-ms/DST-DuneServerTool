import { useApi } from '../../hooks/useApi'
import type { PlayerEvent } from '../../api/gameplay'
import { CharacterActivityEvent } from '../CharacterActivityEvent'

export function SoloGameActivity({profileToken}:{profileToken:string}) {
  const state=useApi<{events:PlayerEvent[];unsupported:boolean;profileToken:string}>('/api/solo/activity',{enabled:!!profileToken})
  const data=state.data?.profileToken===profileToken?state.data:null
  return <section className="card p-5 space-y-3" aria-label="Communinet activity">
    <div className="flex items-center justify-between gap-3"><h2 className="font-semibold">Communinet events</h2><button type="button" className="btn-secondary" disabled={!profileToken||state.loading} onClick={()=>void state.refresh()}>Refresh activity</button></div>
    {state.error?<p role="alert">{state.error}</p>:!data?<p>Reading activity…</p>:data.unsupported?<p>Communinet records are unavailable in this save.</p>:!data.events.length?<p>No Communinet events recorded for this character.</p>:data.events.map(ev=><CharacterActivityEvent key={ev.id} ev={ev} />)}
  </section>
}
