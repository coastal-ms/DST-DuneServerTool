import { lazy, Suspense, useEffect, useState } from 'react'
import { useNavigate } from '../router'
import { api } from '../api/client'
import { isShellHost, setShellWidget } from '../util/shellBridge'
import { mapLabel } from '../util/mapLabel'
import { SoloLiveMap } from '../components/solo/SoloLiveMap'

const SoloSeedMap = lazy(() => import('./WickMaps').then(module => ({ default: module.WickMaps })))

export type WidgetSnapshot = { observedAt: string; maps: { map: string; ready: boolean; alive: boolean }[] }

export default function WidgetMode({ soloOnly = false }: { soloOnly?: boolean }) {
  const navigate = useNavigate()
  const [snapshot, setSnapshot] = useState<WidgetSnapshot | null>(null)
  const [error, setError] = useState('')
  const [shellError, setShellError] = useState('')
  useEffect(() => {
    let active = true
    let timer: number | undefined
    let request: AbortController | undefined
    const read = async () => {
      request = new AbortController()
      const timeout = window.setTimeout(() => request?.abort(), 15_000)
      try {
        const result = await api<WidgetSnapshot>('/api/widget/status', { signal: request.signal })
        if (active) { setSnapshot(result); setError('') }
      } catch { if (active) setError('Connection unavailable') }
      finally {
        window.clearTimeout(timeout)
        if (active) timer = window.setTimeout(() => { void read() }, 15_000)
      }
    }
    if (!soloOnly) void read()
    if (isShellHost()) void (soloOnly ? setShellWidget(true, 'solo-map') : setShellWidget(true)).catch(e => { if (active) setShellError(String(e)) })
    return () => {
      active = false
      window.clearTimeout(timer)
      request?.abort()
      if (isShellHost()) void setShellWidget(false).catch(() => { /* window may be closing */ })
    }
  }, [soloOnly])
  const restore = async () => {
    try {
      if (isShellHost()) await setShellWidget(false)
      navigate(soloOnly ? '/solo' : '/')
    } catch (e) { setShellError(String(e)) }
  }
  const ready = !error && !!snapshot?.maps.length && snapshot.maps.every(m => m.ready && m.alive)
  return <main className="h-full overflow-auto bg-surface p-4 text-text">
    <header className="flex items-center justify-between gap-3 mb-3">
      <h1 className="text-sm font-semibold uppercase tracking-wider text-text-muted">{soloOnly ? 'Solo map' : 'Game servers'}</h1>
      <button className="text-sm underline" onClick={() => { void restore() }}>Open full DST</button>
    </header>
    {soloOnly ? <><SoloLiveMap connectionToken="widget" /><Suspense fallback={<p>Loading Solo map...</p>}><SoloSeedMap embedded solo compact /></Suspense></> : <>
    <table className="w-full text-left text-sm"><thead className="text-text-muted"><tr><th>Map</th><th>State</th></tr></thead>
      <tbody>{snapshot?.maps.map((m, i) => <tr key={`${m.map}-${i}`} className="border-t border-border">
        <td className="py-2 font-semibold">{mapLabel(m.map)}</td>
        <td className={error ? 'text-text-muted' : m.ready && m.alive ? 'text-success' : 'text-warning'}>{error ? 'Unknown' : m.ready && m.alive ? 'Ready' : 'Unavailable'}</td>
      </tr>)}</tbody>
    </table>
    <p role="status" className="mt-3 text-sm">{error || (!snapshot ? 'Connecting...' : !snapshot.maps.length ? 'No maps running' : ready ? 'Game ready' : 'Maps unavailable')}</p>
    {snapshot && <p className="text-xs text-text-muted mt-1">Updated {new Date(snapshot.observedAt).toLocaleTimeString()}</p>}
    </>}
    {shellError && <p role="alert" className="text-sm text-warning mt-2">{shellError}</p>}
  </main>
}
