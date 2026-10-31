import { PlayerGameServerCard, type PlayerServerStatus } from '../components/PlayerGameServerCard'
import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../api/client'
import { getPlayers, type Player } from '../api/gameplay'
import { getMapState, startMap } from '../api/maps'
import { usePortalAuth } from '../auth/PortalAuthGate'
import { PlayerManagement } from './gameplay/players/PlayerManagement'
import { WickMaps } from './WickMaps'
import { MapLiveState } from './workspaces/MapLiveState'
import { DataState } from '../components/platform/DataState'
import './playerPortal.css'

const MAPS = [
  { key: 'deepdesert', label: 'Deep Desert' },
  { key: 'arakeen', label: 'Arrakeen' },
  { key: 'harkovillage', label: 'Harko Village' },
]

export default function PlayerPortal() {
  const auth = usePortalAuth()
  const [view, setView] = useState<'character' | 'map'>('character')
  const [mapView, setMapView] = useState<'live' | 'reference'>('live')
  const [player, setPlayer] = useState<Player | null>(null)
  const [loading, setLoading] = useState(true)
  const [serverStatus, setServerStatus] = useState<PlayerServerStatus | null>(null)
  const [state, setState] = useState('Checking')
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  const [refreshKey, setRefreshKey] = useState(0)
  const pendingRefresh = useRef(false)
  const [warming, setWarming] = useState('')
  const [mapStates, setMapStates] = useState<Record<string, string>>({})
  const load = useCallback(async () => {
    const results = await Promise.allSettled([
      api<PlayerServerStatus>('/api/player-portal/status'),
      getPlayers(),
    ])
    const status = results[0]
    setServerStatus(status.status === 'fulfilled' ? status.value : {available:false,state:'unavailable'})
    setState(status.status === 'fulfilled' && status.value.available ? status.value.state : 'Unavailable')
    const character = results[1]
    if (character.status === 'fulfilled') {
      setPlayer(character.value.players[0] ?? null)
      setError('')
    } else {
      setPlayer(null)
      setError(character.reason instanceof Error ? character.reason.message : 'Character unavailable.')
    }
    setLoading(false)
  }, [])
  useEffect(() => {
    void load()
    const timer = window.setInterval(() => { void load() }, 15000)
    return () => window.clearInterval(timer)
  }, [load])
  useEffect(() => {
    if (view !== 'map') return
    let active = true
    const refresh = async () => {
      const states = await Promise.allSettled(MAPS.map(map => getMapState(map.key)))
      if (active) setMapStates(Object.fromEntries(MAPS.map((map, index) => {
        const result = states[index]
        return [map.key, result.status === 'fulfilled' ? (result.value.running ? 'Running' : 'Stopped') : 'Unavailable']
      })))
    }
    void refresh()
    const timer = window.setInterval(() => { void refresh() }, 10000)
    return () => { active = false; window.clearInterval(timer) }
  }, [view])
  const refresh = () => { pendingRefresh.current = false; setRefreshKey(key => key + 1); void load() }
  const warm = async (key: string) => {
    setWarming(key); setMessage('')
    try { const result = await startMap(key); setMessage(result.message || 'Map warming requested.') }
    catch (e) { setMessage(e instanceof Error ? e.message : 'Map warming failed.') }
    finally { setWarming('') }
  }
  return <main className="player-portal h-dvh min-h-0 min-w-0 overflow-y-auto p-4">
    <div className="mx-auto w-full min-w-0 max-w-screen-2xl space-y-4">
    <header className="card p-4 flex flex-wrap items-center gap-3">
      <h1 className="text-xl font-semibold flex-1">Player Portal</h1>
      <span>Server: {state}</span>
      <button className="btn-secondary" onClick={refresh}>Refresh</button>
      <button className="btn-secondary" onClick={() => { void auth?.logout() }}>Sign out</button>
    </header>
    <PlayerGameServerCard status={serverStatus} />
    <nav className="flex gap-2" aria-label="Player portal">
      <button className="btn-secondary" aria-pressed={view === 'character'} onClick={() => setView('character')}>My character</button>
      <button className="btn-secondary" aria-pressed={view === 'map'} onClick={() => setView('map')}>Map</button>
    </nav>
    {message && <p role="status">{message}</p>}
    {view === 'character' ? <>
      {loading && <DataState state="loading" title="Loading your character…" />}
      {!loading && error && <DataState state="error" title="Could not load your character" message={error}
        action={<button className="btn-secondary" onClick={refresh}>Retry</button>} />}
      {!loading && !error && !player && <DataState state="unavailable" title="No linked character found"
        message="Ask the server host to check the character linked to your Player Portal account." />}
      {player && <>
        <PlayerManagement key={player.id} focused player={player} canWrite={true} demo={false} refreshKey={refreshKey}
          flash={text => setMessage(text)} onChanged={() => { pendingRefresh.current = true }}
          onFlush={() => { if (pendingRefresh.current) refresh() }} />
      </>}
    </> : <>
      <nav className="flex flex-wrap gap-2" aria-label="Map views">
        <button className="btn-secondary" aria-pressed={mapView === 'live'} onClick={() => setMapView('live')}>Live map</button>
        <button className="btn-secondary" aria-pressed={mapView === 'reference'} onClick={() => setMapView('reference')}>DD reference map</button>
      </nav>
      {mapView === 'live' ? <MapLiveState /> : <WickMaps embedded />}
      <section className="card p-4 space-y-3" aria-label="Warm maps">
        <h2 className="text-lg font-semibold">Warm a map</h2>
        {MAPS.map(map => <div key={map.key} className="flex flex-wrap items-center gap-3">
          <span className="flex-1">{map.label}: {mapStates[map.key] || 'Checking'}</span>
          <button className="btn-primary" disabled={!!warming} onClick={() => { void warm(map.key) }}>{warming === map.key ? 'Warming…' : 'Warm map'}</button>
        </div>)}
      </section>
    </>}
    </div>
  </main>
}
