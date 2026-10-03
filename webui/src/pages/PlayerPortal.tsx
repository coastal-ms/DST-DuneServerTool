import { useCallback, useEffect, useState } from 'react'
import { api } from '../api/client'
import { getPlayers, type Player } from '../api/gameplay'
import { getMapState, startMap } from '../api/maps'
import { usePortalAuth } from '../auth/PortalAuthGate'
import { SECTIONS, SECTION_COMPONENTS, type SectionId } from './gameplay/players/sections'
import { WickMaps } from './WickMaps'
import { MapLiveState } from './workspaces/MapLiveState'
import { usePlatformCapabilities } from '../hooks/usePlatformCapabilities'

const MAPS = [
  { key: 'deepdesert', label: 'Deep Desert' },
  { key: 'arakeen', label: 'Arrakeen' },
  { key: 'harkovillage', label: 'Harko Village' },
]

export default function PlayerPortal() {
  const auth = usePortalAuth()
  const [view, setView] = useState<'character' | 'map'>('character')
  const [section, setSection] = useState<SectionId>('stats')
  const [player, setPlayer] = useState<Player | null>(null)
  const [state, setState] = useState('Checking')
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')
  const [refreshKey, setRefreshKey] = useState(0)
  const [warming, setWarming] = useState('')
  const [mapStates, setMapStates] = useState<Record<string, string>>({})
  const { hasCapability } = usePlatformCapabilities()
  const load = useCallback(async () => {
    const results = await Promise.allSettled([
      api<{ state: string; available: boolean }>('/api/player-portal/status'),
      getPlayers(),
    ])
    const status = results[0]
    setState(status.status === 'fulfilled' && status.value.available ? status.value.state : 'Unavailable')
    const character = results[1]
    if (character.status === 'fulfilled') {
      setPlayer(character.value.players[0] ?? null)
      setError('')
    } else {
      setPlayer(null)
      setError(character.reason instanceof Error ? character.reason.message : 'Character unavailable.')
    }
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
  const refresh = () => { setRefreshKey(key => key + 1); void load() }
  const warm = async (key: string) => {
    setWarming(key); setMessage('')
    try { const result = await startMap(key); setMessage(result.message || 'Map warming requested.') }
    catch (e) { setMessage(e instanceof Error ? e.message : 'Map warming failed.') }
    finally { setWarming('') }
  }
  const Section = SECTION_COMPONENTS[section]
  return <main className="min-h-full p-4 space-y-4">
    <header className="card p-4 flex flex-wrap items-center gap-3">
      <h1 className="text-xl font-semibold flex-1">Player Portal</h1>
      <span>Server: {state}</span>
      <button className="btn-secondary" onClick={refresh}>Refresh</button>
      <button className="btn-secondary" onClick={() => { void auth?.logout() }}>Sign out</button>
    </header>
    <nav className="flex gap-2" aria-label="Player portal">
      <button className="btn-secondary" aria-pressed={view === 'character'} onClick={() => setView('character')}>My character</button>
      <button className="btn-secondary" aria-pressed={view === 'map'} onClick={() => setView('map')}>Map</button>
    </nav>
    {message && <p role="status">{message}</p>}
    {view === 'character' ? <>
      {error && <p role="alert">{error}</p>}
      {player && <>
        <h2 className="text-lg font-semibold">{player.name} · {player.online_status}</h2>
        <p className="text-sm text-text-muted">Manage your linked character. Actions that edit saved character data require you to be offline.</p>
        <nav className="flex flex-wrap gap-2" aria-label="Character sections">
          {SECTIONS.filter(item => item.id !== 'landsraad').map(item =>
            <button key={item.id} className="btn-secondary" aria-pressed={section === item.id} onClick={() => setSection(item.id)}>{item.label}</button>)}
        </nav>
        <Section player={player} canWrite={true} demo={false} refreshKey={refreshKey}
          flash={text => setMessage(text)} onChanged={() => {}} onFlush={refresh} />
      </>}
    </> : <>
      <section className="card p-4 space-y-3" aria-label="Warm maps">
        <h2 className="text-lg font-semibold">Warm a map</h2>
        {MAPS.map(map => <div key={map.key} className="flex flex-wrap items-center gap-3">
          <span className="flex-1">{map.label}: {mapStates[map.key] || 'Checking'}</span>
          <button className="btn-primary" disabled={!!warming} onClick={() => { void warm(map.key) }}>{warming === map.key ? 'Warming…' : 'Warm map'}</button>
        </div>)}
      </section>
      <WickMaps embedded />
      {hasCapability('map.live-cache') && <MapLiveState />}
    </>}
  </main>
}
