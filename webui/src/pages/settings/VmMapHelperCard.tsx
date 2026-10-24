import { useEffect, useState } from 'react'
import { api } from '../../api/client'
import { CollapsibleCard } from '../../components/CollapsibleCard'
import { isLocalViewer } from '../../util/viewer'
import { Link } from '../../router'
import { LoaderCircle } from 'lucide-react'

interface State { enabled: boolean; phase: string; url?: string; loginUrl?: string; error?: string; live?: boolean; refreshSeconds?: number; refreshing?: boolean; stopping?: boolean; activity?: string[]; refreshError?: string }

export function VmMapHelperCard() {
  const [state, setState] = useState<State | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [action, setAction] = useState('')
  const [elapsed, setElapsed] = useState(0)
  const local = isLocalViewer()
  const load = async () => { try { setState(await api<State>('/api/v1/maps/vm-helper')) } catch (e) { setError(String(e)) } }
  useEffect(() => { if (local) void load() }, [local])
  useEffect(() => {
    if (!local || !state || !(['installing', 'removing'].includes(state.phase) || state.refreshing || state.stopping || (!state.live && state.activity?.some(job => job !== 'gathering')))) return
    const timer = setTimeout(() => void load(), 2000)
    return () => clearTimeout(timer)
  }, [local, state])
  const progressing = busy || !!state?.refreshing || !!state?.stopping || ['installing', 'removing'].includes(state?.phase ?? '')
  useEffect(() => {
    if (!progressing) return
    const started = Date.now()
    const timer = setInterval(() => setElapsed(Math.floor((Date.now() - started) / 1000)), 1000)
    return () => { clearInterval(timer); setElapsed(0) }
  }, [progressing])
  if (!local) return null
  const update = async (method: 'POST' | 'DELETE') => {
    if (method === 'POST' && !state?.enabled && !window.confirm('Live Maps requires 250 MB of RAM and at least 30 MB of disk space on the VM, plus its Python runtime and map assets. Insufficient resources may cause lag spikes or prevent Live Maps from working. Enable Live Maps and install the helper?')) return
    setBusy(true); setAction(method === 'DELETE' ? 'Removing map helper' : 'Setting up VM-hosted map'); setError('')
    try { setState(await api<State>('/api/v1/maps/vm-helper', { method, body: JSON.stringify({ resourcesAccepted: true }) })) }
    catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  const collection = async (action: 'start' | 'stop' | 'refresh' | 'preferences', refreshSeconds?: number) => {
    if (action === 'refresh' && (state?.live || state?.refreshing || state?.stopping)) return
    setBusy(true); setAction(({start:'Starting live collection',stop:'Stopping live collection',refresh:'Starting snapshot refresh',preferences:'Updating refresh interval'})[action]); setError('')
    try { setState(await api<State>('/api/v1/maps/vm-helper/control', {method:'POST',body:JSON.stringify({action,preferences:refreshSeconds ? {refreshSeconds} : undefined})})) }
    catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  const working = busy || ['installing', 'removing'].includes(state?.phase ?? '')
  const collectionWorking = !!state?.refreshing || !!state?.stopping || (!state?.live && !!state?.activity?.some(job => job !== 'gathering'))
  const progressLabel = busy ? action : state?.phase === 'removing' ? 'Removing map helper' : state?.phase === 'installing' ? 'Setting up VM-hosted map' : state?.stopping ? 'Stopping live collection' : 'Refreshing snapshot'
  return <CollapsibleCard title="VM-hosted Live Map" icon="Map" id="settings-vm-map-helper">
    <p>Move Live Map processing to the VM. Requires 250 MB RAM and at least 30 MB disk space, plus the runtime and map assets.</p>
    {state?.phase === 'ready' && <p><Link className="btn-primary" to="/map?view=live">Open Live Map</Link></p>}
    {progressing && <p role="status" className="flex items-center gap-2"><LoaderCircle aria-hidden="true" size={16} className="animate-spin motion-reduce:animate-none" />{progressLabel}… {elapsed}s elapsed</p>}
    {state?.live && !progressing && <p role="status">Live collection running. Stop live before refreshing a snapshot.</p>}
    {(error || state?.error || state?.refreshError) && <p role="alert" className="text-danger">{error || state?.error || state?.refreshError}</p>}
    <div className="flex gap-2 flex-wrap">
      <button className="btn-primary" disabled={working} onClick={() => void update('POST')}>{state?.enabled ? 'Repair / update' : 'Set up VM-hosted map'}</button>
      {state?.enabled && <button className="btn-secondary" disabled={working} onClick={() => void update('DELETE')}>Remove map helper</button>}
      {state?.phase === 'ready' && <>
        <button className="btn-secondary" disabled={working || collectionWorking} onClick={() => void collection(state.live ? 'stop' : 'start')}>{state.live ? 'Stop live' : 'Start live'}</button>
        <button className="btn-secondary" disabled={working || !!state.live || collectionWorking} onClick={() => void collection('refresh')}>Refresh snapshot</button>
        <label>Refresh interval <select disabled={working} value={state.refreshSeconds ?? 3} onChange={e => void collection('preferences', Number(e.target.value))}>
          {[1,3,5,10,30,60].map(seconds => <option key={seconds} value={seconds}>{seconds}s</option>)}
        </select></label>
      </>}
    </div>
  </CollapsibleCard>
}
