import { useEffect, useState } from 'react'
import { api } from '../../api/client'

export function SoloLiveMap({ connectionToken }: { connectionToken: string }) {
  const [state, setState] = useState({ available: false, status: '' })
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    let disposed = false
    let timer: ReturnType<typeof setTimeout>
    async function refresh() {
      try {
        const next = await api<typeof state>('/api/solo/live-map')
        if (!disposed) setState(next)
      } catch {
        if (!disposed) setState({ available: false, status: 'Live map unavailable' })
      } finally {
        if (!disposed) timer = setTimeout(refresh, 3000)
      }
    }
    setState({ available: false, status: '' })
    void refresh()
    return () => { disposed = true; clearTimeout(timer) }
  }, [connectionToken])
  async function open() {
    setBusy(true); setError('')
    try { await api('/api/solo/live-map/open', { method: 'POST', body: '{}' }) }
    catch (e) { setError(e instanceof Error ? e.message : String(e)) }
    finally { setBusy(false) }
  }
  return <div className="mb-4 flex flex-wrap items-center gap-3">
    <button className="btn btn-primary" disabled={!state.available || busy} onClick={() => void open()}>Open Solo Live Map</button>
    {!state.available && <span className="text-sm text-text-dim">{state.status}</span>}
    {error && <span role="alert" className="text-sm text-red-400">{error}</span>}
  </div>
}
