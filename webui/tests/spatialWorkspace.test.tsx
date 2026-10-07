// @vitest-environment jsdom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, cleanup, fireEvent, render as renderUI, screen, waitFor, within } from '@testing-library/react'
import type { ReactNode } from 'react'
import '@testing-library/jest-dom/vitest'
import type { StatusSnapshot } from '../src/api/types'
import type { PlayersResponse } from '../src/api/gameplay'
import SpatialHome from '../src/pages/workspaces/SpatialHome'
import SpatialStage from '../src/pages/workspaces/SpatialStage'
import { spatialGlobeNodes, spatialNodes, spatialConnections, spatialSceneLayout, spatialLayers, MAX_SPATIAL_LOCATIONS, locationScale, spatialLocationKind, LOCATION_VISUALS } from '../src/pages/workspaces/spatialModel'
import { PRESETS, ThemeProvider } from '../src/theme/ThemeContext'
import SpatialFrame from '../src/layout/SpatialFrame'
import { GLOBE_LAYOUT_STORAGE_KEY, globePositionsForNodes } from '../src/pages/workspaces/globeLayout'
import { GLOBE_ZOOM_KEY } from '../src/pages/workspaces/globeZoom'
import { GLOBE_AUTO_ROTATE_KEY } from '../src/hooks/useGlobeAutoRotate'
import { GLOBE_ORIENTATION_KEY } from '../src/hooks/useGlobeOrientation'
import { HEALTH_REFRESH_KEY } from '../src/hooks/useHealthRefresh'

function render(ui: ReactNode) {
  return renderUI(<ThemeProvider>{ui}</ThemeProvider>)
}

const state = vi.hoisted(() => ({
  owner: false,
  soloOnly: false,
  local: false,
  status: null as StatusSnapshot | null,
  error: null,
  loading: false,
  refresh: vi.fn(async () => {}),
  dispose: vi.fn(), select: vi.fn(), reset: vi.fn(),
  palette: vi.fn(), motion: vi.fn(), spin: vi.fn(), updateStatus: vi.fn(),
  create: vi.fn(), layout: vi.fn(), moveMaps: vi.fn(), nudge: vi.fn(), drawer: vi.fn(), flights: vi.fn(), localSun: vi.fn(), zoom: vi.fn(), fit: vi.fn(),
  roster: { data: null as PlayersResponse | null, loading: false, error: null, refresh: vi.fn() },
  rosterReads: vi.fn(),
}))
vi.mock('../src/hooks/useStatus', () => ({ useStatus: () => state }))
vi.mock('../src/hooks/useInstallationMode', async importOriginal => ({
  ...await importOriginal<object>(), useSoloInstallation: () => state.soloOnly,
}))
vi.mock('../src/hooks/useUpdateCheck', () => ({ useUpdateCheck: () => ({ data: { currentVersion: '15.0.0-finalphase-1.2' } }) }))
vi.mock('../src/hooks/useApi', () => ({
  useApi: (_path: string, options?: { enabled?: boolean; intervalMs?: number }) => {
    if (options?.enabled) state.rosterReads(options.intervalMs)
    return state.roster
  },
}))
vi.mock('../src/auth/portalAccess', () => ({ usePortalAccess: () => ({ canAccessOwnerSurfaces: state.owner }) }))
vi.mock('../src/util/viewer', () => ({ isLocalViewer: () => state.local, isWindowsViewer: () => true }))
vi.mock('../src/pages/workspaces/spatialRenderer', () => ({
  createSpatialRenderer: state.create,
}))
beforeEach(() => {
  vi.clearAllMocks()
  vi.stubGlobal('ResizeObserver', class { observe() {}; disconnect() {} })
  localStorage.clear()
  window.history.replaceState({}, '', '/')
  HTMLDialogElement.prototype.showModal = function () { this.setAttribute('open', '') }
  HTMLDialogElement.prototype.close = function () {
    if (this.hasAttribute('open')) {
      this.removeAttribute('open')
      this.dispatchEvent(new Event('close'))
    }
  }
  state.owner = false
  state.soloOnly = false
  state.local = false
  state.roster.data = null
  state.status = {
    vm: { exists: true, running: true, state: 'Running', name: 'Example', ip: null, uptime: 1 },
    ports: null, ts: '2026-09-05T12:00:00Z',
    bg: { available: true, gameServers: [
      { map: 'One', phase: 'Running', ready: 'True', players: '0', age: '1m' },
      { map: 'Two', phase: 'Starting', ready: 'False', players: '', age: '1m' },
    ] },
  }
  state.create.mockImplementation(() => ({ dispose: state.dispose, select: state.select, reset: state.reset, palette: state.palette, motion: state.motion, spin: state.spin, status: state.updateStatus, layout: state.layout, moveMaps: state.moveMaps, nudge: state.nudge, drawer: state.drawer, flights: state.flights, localSun: state.localSun, zoom: state.zoom, fit: state.fit }))
})
afterEach(() => { cleanup(); vi.restoreAllMocks(); vi.unstubAllGlobals() })

describe('Spatial object workspace', () => {
  it('keeps Solo tools free of dedicated-server navigation and indicators', () => {
    state.soloOnly = true
    state.local = true
    state.owner = true
    render(<SpatialFrame tools><p>Solo save</p></SpatialFrame>)
    expect(screen.getByText('Local save tools')).toBeInTheDocument()
    expect(screen.queryByText('Database')).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Diagnostics' })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Find a tool' }))
    const finder = screen.getByRole('dialog')
    expect(within(finder).queryByRole('link', { name: /Server Settings/ })).not.toBeInTheDocument()
    expect(within(finder).getByRole('link', { name: /Settings/ })).toBeInTheDocument()
  })
  it('shows Duke attribution and the running version beside the dock', () => {
    render(<SpatialFrame tools><p>Tools</p></SpatialFrame>)
    expect(screen.getByText('BUILT WITH DUKE WITH LOVE')).toBeInTheDocument()
    expect(screen.getByText('v15.0.0-finalphase-1.2')).toBeInTheDocument()
  })

  it.each(PRESETS)('keeps the complete $name theme selected across globe and tool frames', preset => {
    const home = render(<SpatialFrame><p>Globe</p></SpatialFrame>)
    fireEvent.change(screen.getByRole('combobox', { name: 'Workspace palette' }), { target: { value: preset.id } })
    for (const [key, value] of Object.entries(preset.tokens)) {
      expect(document.documentElement.style.getPropertyValue(key)).toBe(value)
    }
    home.unmount()
    window.history.replaceState({}, '', '/players')
    render(<SpatialFrame tools><p>Players</p></SpatialFrame>)
    expect(screen.getByRole('combobox', { name: 'Workspace palette' })).toHaveValue(preset.id)
    for (const [key, value] of Object.entries(preset.tokens)) {
      expect(document.documentElement.style.getPropertyValue(key)).toBe(value)
    }
  })

  it('saves both rotation axes and restores them on remount and renderer recreation', async () => {
    localStorage.setItem(GLOBE_ORIENTATION_KEY, JSON.stringify({ version: 1, pitch: .6, yaw: -1.2 }))
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    const stage = <SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />
    let view = render(stage)
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    expect(state.create.mock.lastCall![5].orientation).toEqual({ pitch: .6, yaw: -1.2 })
    act(() => state.create.mock.lastCall![5].onOrientationChange({ pitch: -.4, yaw: 2.1 }))
    expect(JSON.parse(localStorage.getItem(GLOBE_ORIENTATION_KEY)!)).toEqual({ version: 1, pitch: -.4, yaw: 2.1 })
    expect(state.create).toHaveBeenCalledOnce()
    fireEvent.click(screen.getByRole('button', { name: 'Disable 3D' }))
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledTimes(2))
    expect(state.create.mock.lastCall![5].orientation).toEqual({ pitch: -.4, yaw: 2.1 })
    view.unmount()
    view = render(stage)
    await waitFor(() => expect(state.create).toHaveBeenCalledTimes(3))
    expect(state.create.mock.lastCall![5].orientation).toEqual({ pitch: -.4, yaw: 2.1 })
    const extra = spatialNodes([...state.status!.bg!.gameServers!, { map: 'Another', phase: 'Running', ready: 'True', players: '0', age: '1m' }], value => value)
    view.rerender(<ThemeProvider><SpatialStage nodes={extra} selected={extra[0].id} onSelect={() => {}} initiallyEnabled /></ThemeProvider>)
    await waitFor(() => expect(state.create).toHaveBeenCalledTimes(4))
    expect(state.create.mock.lastCall![5].orientation).toEqual({ pitch: -.4, yaw: 2.1 })
    expect(state.reset).not.toHaveBeenCalled()
  })
  it.each(['{bad', '{"version":1,"pitch":9,"yaw":0}', '{"version":1,"pitch":"0","yaw":0}'])('reports invalid orientation storage %s and can save a valid view', async raw => {
    localStorage.setItem(GLOBE_ORIENTATION_KEY, raw)
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />)
    expect(screen.getByText(/Saved globe orientation could not be read/)).toBeInTheDocument()
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    expect(state.create.mock.lastCall![5].orientation).toEqual({ pitch: 0, yaw: 0 })
    act(() => state.create.mock.lastCall![5].onOrientationChange({ pitch: .3, yaw: .8 }))
    expect(screen.queryByText(/Saved globe orientation could not be read/)).not.toBeInTheDocument()
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new DOMException('Blocked', 'SecurityError') })
    act(() => state.create.mock.lastCall![5].onOrientationChange({ pitch: .4, yaw: .9 }))
    expect(screen.getByText(/Globe orientation changed for this view only/)).toBeInTheDocument()
  })
  it('uses the same light/dark color scope on the globe and tool pages without sharing their layout', () => {
    const home = render(<SpatialFrame dashboard><p>Globe</p></SpatialFrame>)
    expect(home.container.querySelector('.spatial-dashboard-frame')).toHaveAttribute('data-portal-tone', 'dark')
    fireEvent.change(screen.getByRole('combobox', { name: 'Workspace palette' }), { target: { value: 'daylight' } })
    expect(home.container.querySelector('.spatial-dashboard-frame')).toHaveAttribute('data-portal-tone', 'light')
    expect(home.container.querySelector('.spatial-tool-portal')).toBeNull()
    home.unmount()
    window.history.replaceState({}, '', '/commands')
    const tools = render(<SpatialFrame tools><p>Commands</p></SpatialFrame>)
    expect(tools.container.querySelector('.spatial-tool-portal')).toHaveAttribute('data-portal-tone', 'light')
    fireEvent.change(screen.getByRole('combobox', { name: 'Workspace palette' }), { target: { value: 'world-control' } })
    expect(tools.container.querySelector('.spatial-tool-portal')).toHaveAttribute('data-portal-tone', 'dark')
  })
  it('remembers auto rotate on and off when the globe is reopened', async () => {
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    const stage = <SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />
    let view = render(stage)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Auto rotate' })).toBeEnabled())
    expect(screen.getByRole('button', { name: 'Auto rotate' })).toHaveAttribute('aria-pressed', 'false')
    fireEvent.click(screen.getByRole('button', { name: 'Auto rotate' }))
    expect(localStorage.getItem(GLOBE_AUTO_ROTATE_KEY)).toBe('1')
    view.unmount()
    view = render(stage)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Auto rotate' })).toBeEnabled())
    expect(screen.getByRole('button', { name: 'Auto rotate' })).toHaveAttribute('aria-pressed', 'true')
    expect(state.spin).toHaveBeenLastCalledWith(true)
    fireEvent.click(screen.getByRole('button', { name: 'Auto rotate' }))
    expect(localStorage.getItem(GLOBE_AUTO_ROTATE_KEY)).toBe('0')
    view.unmount()
    render(stage)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Auto rotate' })).toBeEnabled())
    expect(screen.getByRole('button', { name: 'Auto rotate' })).toHaveAttribute('aria-pressed', 'false')
    expect(state.spin).toHaveBeenLastCalledWith(false)
  })
  it('restores stored rotation at startup and preserves it while moving maps or disabling 3D', async () => {
    localStorage.setItem(GLOBE_AUTO_ROTATE_KEY, '1')
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />)
    await waitFor(() => expect(screen.getByRole('button', { name: 'Auto rotate' })).toBeEnabled())
    expect(state.spin).toHaveBeenLastCalledWith(true)
    fireEvent.click(screen.getByRole('button', { name: 'Move maps' }))
    expect(screen.getByRole('button', { name: 'Auto rotate' })).toBeDisabled()
    expect(localStorage.getItem(GLOBE_AUTO_ROTATE_KEY)).toBe('1')
    fireEvent.click(screen.getByRole('button', { name: 'Done moving' }))
    expect(screen.getByRole('button', { name: 'Auto rotate' })).toHaveAttribute('aria-pressed', 'true')
    fireEvent.click(screen.getByRole('button', { name: 'Disable 3D' }))
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledTimes(2))
    expect(state.spin).toHaveBeenLastCalledWith(true)
    expect(localStorage.getItem(GLOBE_AUTO_ROTATE_KEY)).toBe('1')
    fireEvent.click(screen.getByRole('button', { name: 'Reset view' }))
    expect(localStorage.getItem(GLOBE_AUTO_ROTATE_KEY)).toBe('0')
    expect(state.spin).toHaveBeenLastCalledWith(false)
  })
  it('restores and saves camera zoom without rebuilding the scene', async () => {
    localStorage.setItem(GLOBE_ZOOM_KEY, JSON.stringify({ version: 1, zoom: 1.7 }))
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled fitViewport />)
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    expect(state.zoom).toHaveBeenCalledWith(1.7)
    fireEvent.click(screen.getByRole('button', { name: 'Zoom in' }))
    expect(JSON.parse(localStorage.getItem(GLOBE_ZOOM_KEY)!)).toEqual({ version: 1, zoom: 1.8 })
    act(() => state.create.mock.calls[0][5].onZoomChange(2.1))
    expect(screen.getByLabelText('Globe zoom level')).toHaveTextContent('210%')
    expect(state.create).toHaveBeenCalledOnce()
    fireEvent.click(screen.getByRole('button', { name: 'Fit', exact: true }))
    expect(state.fit).toHaveBeenCalledOnce()
    expect(JSON.parse(localStorage.getItem(GLOBE_ZOOM_KEY)!)).toEqual({ version: 1, zoom: 1 })
  })
  it('reports corrupt or blocked zoom storage instead of claiming persistence', async () => {
    localStorage.setItem(GLOBE_ZOOM_KEY, '{bad')
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled fitViewport />)
    expect(screen.getByText(/Saved globe zoom could not be read/)).toBeInTheDocument()
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new DOMException('Blocked', 'SecurityError') })
    fireEvent.click(screen.getByRole('button', { name: 'Zoom in' }))
    expect(screen.getByText(/Zoom changed for this view only/)).toBeInTheDocument()
    expect(state.zoom).toHaveBeenLastCalledWith(1.1)
  })
  it.each(['0', '50', '1000'])('keeps reported count %s while loading selected-map names on the standard interval', count => {
    state.status!.bg!.gameServers![0].players = count
    state.roster.data = {
      players: [{
        id: 1,
        account_id: 1,
        controller_id: 1,
        name: 'Example player',
        class: 'Player',
        map: 'One',
        faction_id: 0,
        faction_name: '',
        online_status: 'Online',
      }],
      total: 1,
      source: 'live',
    }
    render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /^Select One:/ }))
    const panel = screen.getByRole('complementary', { name: 'Selected map details' })
    expect(within(panel).getByText('Reported players').nextElementSibling).toHaveTextContent(count)
    expect(state.rosterReads).toHaveBeenLastCalledWith(30_000)
    expect(screen.getByRole('complementary', { name: 'Map status roster' })).toHaveTextContent(`One - Ready - ${count}`)
    expect(within(panel).getByText('Example player')).toBeInTheDocument()
    expect(screen.getByRole('region', { name: 'Server status summary' })).toHaveTextContent('Running')
  })
  it('applies the focused selected-map roster interval', () => {
    localStorage.setItem(HEALTH_REFRESH_KEY, 'focused')
    render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /^Select One:/ }))
    expect(state.rosterReads).toHaveBeenLastCalledWith(10_000)
  })
  it('maps missing values honestly and identifies unknown map models', () => {
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    expect(nodes[0].players).toBe('0')
    expect(nodes[1].players).toBe('Unknown')
    expect(nodes[1].ready).toBe('Not ready')
    expect(spatialLocationKind(nodes[0].map)).toBe('unknown')
    expect(LOCATION_VISUALS.unknown.description).toContain('no matching')
  })
  it('treats Overmap as the parent and sizes regions by identity, not row order', () => {
    const maps = ['Survival_1', 'Overmap', 'SH_Arrakeen', 'DeepDesert_1', 'SH_HarkoVillage']
    state.status!.bg!.gameServers = maps.map(map => ({ map, phase: 'Running', ready: 'True', players: '0', age: '1m' }))
    const nodes = spatialNodes(state.status!.bg!.gameServers, value => value)
    expect(spatialLayers(nodes).locations).toHaveLength(4)
    expect(locationScale('DeepDesert_1')).toBeGreaterThan(locationScale('Survival_1'))
    expect(locationScale('Survival_1')).toBeGreaterThan(locationScale('SH_Arrakeen'))
    const layout = spatialSceneLayout(nodes)
    expect(layout.placements).toEqual(spatialSceneLayout([...nodes].reverse()).placements)
    expect(layout.placements[0].node.map).toBe('DeepDesert_1')
    render(<SpatialHome onDetails={() => {}} />)
    expect(screen.getByRole('button', { name: /Inspect Overmap/ })).toHaveAttribute('aria-pressed', 'false')
    expect(screen.queryByRole('button', { name: /Select Overmap/ })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Inspect Overmap/ }))
    expect(screen.getByRole('complementary', { name: 'Selected map details' })).toHaveTextContent('Overmap')
  })
  it('disposes 3D above the limit and keeps every map in the list', async () => {
    const view = render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    state.status!.bg!.gameServers = Array.from({ length: MAX_SPATIAL_LOCATIONS + 1 }, (_, index) => ({ map: `Map_${index}`, phase: 'Running', ready: 'True', players: '0', age: '1m' }))
    state.create.mockClear()
    view.rerender(<ThemeProvider><SpatialHome onDetails={() => {}} /></ThemeProvider>)
    expect(screen.getByText(/3D is paused above 13/)).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: /^Select Map / })).toHaveLength(14)
    expect(screen.queryByRole('button', { name: /Enter spatial view/ })).not.toBeInTheDocument()
    expect(state.create).not.toHaveBeenCalled()
    expect(state.dispose).toHaveBeenCalled()
  })
  it('allows thirteen locations plus the containing Overmap and packs symbols without overlap', async () => {
    const maps = ['Overmap', 'DeepDesert_1', 'Survival_1', 'SH_Arrakeen', 'SH_HarkoVillage', ...Array.from({ length: 9 }, (_, index) => `Other_${index}`)]
    state.status!.bg!.gameServers = maps.map(map => ({ map, phase: 'Running', ready: 'True', players: '0', age: '1m' }))
    const nodes = spatialNodes(state.status!.bg!.gameServers, value => value)
    const layout = spatialSceneLayout(nodes)
    expect(layout.placements).toHaveLength(13)
    for (const [index, a] of layout.placements.entries()) {
      for (const b of layout.placements.slice(index + 1)) {
        expect(Math.hypot(a.x - b.x, a.z - b.z)).toBeGreaterThan((a.scale + b.scale) * 2.7)
      }
    }
    render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    expect(state.create.mock.calls[0][1]).toHaveLength(14)
  })
  it('pins the supplied composition as other maps spin up and down', () => {
    const servers = ['DeepDesert_1', 'Survival_1', 'SH_HarkoVillage', 'SH_Arrakeen', 'CB_Dungeon_Hephaestus']
      .map(map => ({ map, phase: 'Running', ready: 'True', players: '0', age: '1m' }))
    const layout = spatialSceneLayout(spatialNodes(servers, value => value))
    const positions = new Map(layout.placements.map(item => [item.node.map, item]))
    const desert = positions.get('DeepDesert_1')!
    const hagga = positions.get('Survival_1')!
    const harko = positions.get('SH_HarkoVillage')!
    const arrakeen = positions.get('SH_Arrakeen')!
    const other = positions.get('CB_Dungeon_Hephaestus')!
    expect(desert.x).toBe(hagga.x)
    expect(harko.x).toBe(hagga.x)
    expect(desert.z).toBeLessThan(hagga.z)
    expect(hagga.z).toBeLessThan(harko.z)
    expect(arrakeen.x).toBeGreaterThan(hagga.x)
    expect(arrakeen.z).toBeLessThan(hagga.z)
    expect(other.x).toBeGreaterThan(hagga.x)
    expect(other.z).toBeGreaterThan(arrakeen.z)
    const withoutOthers = spatialSceneLayout(spatialNodes(servers.slice(0, 4), value => value))
    expect(withoutOthers.placements).toEqual(layout.placements.filter(item => item.node.map !== 'CB_Dungeon_Hephaestus'))
    const duplicated = spatialSceneLayout(spatialNodes([...servers, ...servers], value => value))
    for (const [index, a] of duplicated.placements.entries()) {
      for (const b of duplicated.placements.slice(index + 1)) {
        expect(Math.hypot(a.x - b.x, a.z - b.z)).toBeGreaterThan((a.scale + b.scale) * 2.7)
      }
    }
  })
  it('starts every connection at Hagga and never invents a replacement hub', () => {
    const servers = ['Overmap', 'DeepDesert_1', 'SH_Arrakeen', 'Survival_1', 'SH_HarkoVillage']
      .map(map => ({ map, phase: 'Running', ready: 'True', players: '0', age: '1m' }))
    const nodes = spatialNodes(servers, value => value)
    const links = spatialConnections(spatialSceneLayout(nodes).placements)
    expect(links).toHaveLength(3)
    expect(links.every(link => link.from.node.map === 'Survival_1')).toBe(true)
    expect(links.map(link => link.to.node.map).sort()).toEqual(['DeepDesert_1', 'SH_Arrakeen', 'SH_HarkoVillage'])
    expect(spatialConnections(spatialSceneLayout(nodes.filter(node => node.map !== 'Survival_1')).placements)).toEqual([])
  })
  it('keeps dormant main maps on the globe but out of live routes and the reported roster', async () => {
    state.status!.bg!.gameServers = [
      { map: 'Overmap', phase: 'Running', ready: 'True', players: '0', age: '1m' },
      { map: 'Survival_1', phase: 'Running', ready: 'True', players: '0', age: '1m' },
    ]
    render(<SpatialHome onDetails={() => {}} startEnabled />)
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())

    const globe = state.create.mock.calls[0][1]
    const expected = spatialGlobeNodes(spatialNodes(state.status!.bg!.gameServers, value => value))
    expect(globe.map((node: { id: string; map: string; layoutId?: string; reported?: boolean }) =>
      ({ id: node.id, map: node.map, layoutId: node.layoutId, reported: node.reported })))
      .toEqual(expected.map(node => ({ id: node.id, map: node.map, layoutId: node.layoutId, reported: node.reported })))
    expect(globe.filter((node: { reported?: boolean }) => node.reported === false)).toHaveLength(3)
    expect(screen.getByRole('complementary', { name: 'Map status roster' })).not.toHaveTextContent('Not spun up')
    expect(screen.getByRole('list', { name: 'Globe map labels' })).toHaveTextContent('Not spun up')
    expect(spatialConnections(spatialSceneLayout(globe).placements)).toEqual([])
    expect(state.flights).toHaveBeenLastCalledWith(false)
    expect(screen.getByRole('button', { name: 'Simulated travel' })).toBeDisabled()
  })
  it('uses technical map identity rather than custom server names or list order', () => {
    const servers = [
      { map: 'Survival_1', sietchName: 'Coastal example', phase: 'Running', ready: 'True', players: '2', age: '1m' },
      { map: 'DeepDesert_1', phase: 'Running', ready: 'True', players: '0', age: '1m' },
    ]
    const original = spatialNodes(servers, value => value)
    const reordered = spatialNodes([...servers].reverse(), value => value)
    expect(original[0].id).toBe(reordered[1].id)
    expect(spatialLocationKind(original[0].map)).toBe('hagga')
    expect(spatialLocationKind(original[1].map)).toBe('deep-desert')
    expect(spatialLocationKind('SH_Arrakeen')).toBe('arrakeen')
    expect(spatialLocationKind('SH_HarkoVillage')).toBe('harko')
    expect(spatialLocationKind('Overmap')).toBe('overland')
    expect(spatialLocationKind('CB_Dungeon_ThePit')).toBe('quarry')
    expect(spatialLocationKind('Story_HeighlinerDungeon')).toBe('fallen-light')
    expect(spatialLocationKind('CB_Ecolab_Bronze_Green_152')).toBe('station152')
    expect(spatialNodes([servers[0], servers[0]], value => value).map(node => node.id)).toEqual(['Survival_1:0', 'Survival_1:1'])
  })
  it('retains placements by named sietch rather than duplicate map row order', () => {
    const row = { map: 'Survival_1', phase: 'Running', ready: 'True', players: '1', age: '1m' }
    const original = spatialNodes([{ ...row, sietchName: 'North' }, { ...row, sietchName: 'South' }], value => value)
    const reordered = spatialNodes([{ ...row, sietchName: 'South' }, { ...row, sietchName: 'North' }], value => value)
    const positions = { [original[0].layoutId!]: [1, 0, 0] as const, [original[1].layoutId!]: [0, 1, 0] as const }
    expect(globePositionsForNodes(reordered, positions)).toEqual({ 'Survival_1:0': [0, 1, 0], 'Survival_1:1': [1, 0, 0] })
    expect(spatialNodes([row, row], value => value).every(node => !node.layoutId)).toBe(true)
    expect(spatialNodes([{ ...row, sietchName: 'Same' }, { ...row, sietchName: 'Same' }], value => value).every(node => !node.layoutId)).toBe(true)
    const remaining = spatialNodes([{ ...row, sietchName: 'South' }], value => value)
    expect(globePositionsForNodes(remaining, positions)).toEqual({ 'Survival_1:0': [0, 1, 0] })
  })
  it('separates moving from spinning and offers keyboard and touch controls', async () => {
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />)
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    fireEvent.click(screen.getByRole('button', { name: 'Move maps' }))
    expect(state.moveMaps).toHaveBeenLastCalledWith(true)
    expect(screen.getByRole('button', { name: 'Auto rotate' })).toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: 'Move map right' }))
    expect(state.nudge).toHaveBeenLastCalledWith(nodes[0].id, 1, 0)
    fireEvent.keyDown(screen.getByRole('button', { name: 'Move map up' }), { key: 'ArrowUp' })
    expect(state.nudge).toHaveBeenLastCalledWith(nodes[0].id, 0, 1)
    fireEvent.click(screen.getByRole('button', { name: 'Done moving' }))
    expect(state.moveMaps).toHaveBeenLastCalledWith(false)
    expect(screen.queryByRole('region', { name: 'Globe layout' })).not.toBeInTheDocument()
  })
  it('hides and restores the control strip without changing mode or rebuilding the globe', async () => {
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />)
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    fireEvent.click(screen.getByRole('button', { name: 'Move maps' }))
    const moveCalls = state.moveMaps.mock.calls.length
    fireEvent.click(screen.getByRole('button', { name: 'Hide globe controls' }))
    expect(screen.queryByRole('combobox', { name: 'Select map' })).not.toBeInTheDocument()
    const restore = screen.getByRole('button', { name: 'Show globe controls' })
    expect(restore).toHaveTextContent('Moving maps')
    expect(state.moveMaps).toHaveBeenCalledTimes(moveCalls)
    fireEvent.click(restore)
    expect(screen.getByRole('button', { name: 'Done moving' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: 'Disable 3D' })).toBeInTheDocument()
    expect(state.create).toHaveBeenCalledOnce()
  })
  it('saves drop results, restores them across reloads, and resets layout independently of the view', async () => {
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    const view = render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />)
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    act(() => state.create.mock.calls[0][5].onMove({ [nodes[0].id]: [1, 0, 0] }))
    expect(JSON.parse(localStorage.getItem(GLOBE_LAYOUT_STORAGE_KEY)!)).toEqual({ version: 1, positions: { [nodes[0].layoutId!]: [1, 0, 0] } })
    expect(screen.getByText('Layout saved in this browser.')).toBeInTheDocument()
    view.unmount()
    render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />)
    await waitFor(() => expect(state.create).toHaveBeenCalledTimes(2))
    expect(state.create.mock.calls[1][5].positions).toEqual({ [nodes[0].id]: [1, 0, 0] })
    fireEvent.click(screen.getByRole('button', { name: 'Reset view' }))
    expect(JSON.parse(localStorage.getItem(GLOBE_LAYOUT_STORAGE_KEY)!).positions).not.toEqual({})
    fireEvent.click(screen.getByRole('button', { name: 'Move maps' }))
    fireEvent.click(screen.getByRole('button', { name: 'Reset map positions' }))
    expect(state.layout).toHaveBeenLastCalledWith({})
    expect(JSON.parse(localStorage.getItem(GLOBE_LAYOUT_STORAGE_KEY)!)).toEqual({ version: 1, positions: {} })
  })
  it('always labels every projected map without opening a card or rebuilding on counts', async () => {
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    const onSelect = vi.fn()
    const view = render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={onSelect} initiallyEnabled />)
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    const project = state.create.mock.calls[0][5].onMapLabelPositions
    act(() => project([{ id: nodes[0].id, x: .4, y: .5, visible: true }, { id: nodes[1].id, x: .6, y: .3, visible: true }]))
    const mapLabels = screen.getByRole('list', { name: 'Globe map labels' })
    expect(within(mapLabels).getByText('0 players')).toBeVisible()
    expect(within(mapLabels).getByText('Player count unknown')).toBeVisible()
    expect(screen.queryByRole('status', { name: 'Selected map card' })).not.toBeInTheDocument()
    expect(onSelect).not.toHaveBeenCalled()
    const refreshed = nodes.map(node => ({ ...node, players: '7' }))
    view.rerender(<ThemeProvider><SpatialStage nodes={refreshed} selected={nodes[0].id} onSelect={onSelect} initiallyEnabled /></ThemeProvider>)
    expect(state.create).toHaveBeenCalledOnce()
    expect(within(mapLabels).getAllByText('7 players')).toHaveLength(2)
    act(() => project([{ id: nodes[1].id, x: .6, y: .3, visible: false }]))
    expect(within(mapLabels).getByText('Two')).not.toBeVisible()
    act(() => state.create.mock.calls[0][5].onMove({ [nodes[1].id]: [1, 0, 0] }))
    expect(onSelect).not.toHaveBeenCalled()
    expect(screen.queryByRole('status', { name: 'Selected map card' })).not.toBeInTheDocument()
  })
  it('keeps missing map placements and never offers movement for ambiguous instances', async () => {
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    localStorage.setItem(GLOBE_LAYOUT_STORAGE_KEY, JSON.stringify({ version: 1, positions: { '["Absent",null]': [0, 0, 1] } }))
    const view = render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />)
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    act(() => state.create.mock.calls[0][5].onMove({ [nodes[0].id]: [1, 0, 0] }))
    expect(JSON.parse(localStorage.getItem(GLOBE_LAYOUT_STORAGE_KEY)!).positions['["Absent",null]']).toEqual([0, 0, 1])
    const ambiguous = spatialNodes([state.status!.bg!.gameServers![0], state.status!.bg!.gameServers![0]], value => value)
    view.rerender(<ThemeProvider><SpatialStage nodes={ambiguous} selected={ambiguous[0].id} onSelect={() => {}} initiallyEnabled /></ThemeProvider>)
    fireEvent.click(screen.getByRole('button', { name: 'Move maps' }))
    expect(screen.getByRole('button', { name: 'Move map right' })).toBeDisabled()
    expect(screen.getByText(/no unique instance identity/)).toBeInTheDocument()
  })
  it('reports corrupt or inaccessible storage without claiming the layout was saved', async () => {
    localStorage.setItem(GLOBE_LAYOUT_STORAGE_KEY, '{bad')
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} initiallyEnabled />)
    expect(screen.getByText(/Saved layout could not be read/)).toBeInTheDocument()
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => { throw new DOMException('Blocked', 'SecurityError') })
    act(() => state.create.mock.calls[0][5].onMove({ [nodes[0].id]: [1, 0, 0] }))
    expect(screen.getByText(/will not survive a reload/)).toBeInTheDocument()
    expect(state.layout).toHaveBeenLastCalledWith({ [nodes[0].id]: [1, 0, 0] })
  })
  it('does not initialize graphics before consent and updates focus without a server action', () => {
    render(<SpatialHome onDetails={() => {}} />)
    expect(state.create).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: /Select Two/ }))
    expect(screen.getByRole('heading', { name: 'Two', level: 2 })).toBeInTheDocument()
    expect(state.refresh).not.toHaveBeenCalled()
    expect(state.create).not.toHaveBeenCalled()
  })
  it('keeps owner-only tools out of both the dock and finder', () => {
    render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: 'All tools' }))
    expect(screen.queryByRole('link', { name: /^Database/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /^Settings/ })).not.toBeInTheDocument()
    fireEvent.change(screen.getByRole('textbox', { name: 'Search DST tools' }), { target: { value: 'ammo' } })
    expect(screen.getByRole('link', { name: /Players.*Inspect/ })).toHaveAttribute('href', '/players')
  })
  it('creates and disposes the renderer on explicit enable/disable', async () => {
    const nodes = spatialNodes(state.status!.bg!.gameServers!, value => value)
    render(<SpatialStage nodes={nodes} selected={nodes[0].id} onSelect={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    await waitFor(() => expect(state.select).toHaveBeenCalledWith(nodes[0].id))
    fireEvent.click(screen.getByRole('button', { name: 'Disable 3D' }))
    expect(state.dispose).toHaveBeenCalledOnce()
  })
  it('shows each selected custom sietch and its own count in the in-place map panel', async () => {
    state.status!.bg!.gameServers = [
      { map: 'Survival_1', sietchName: 'Northern Watch', phase: 'Running', ready: 'True', players: '3', age: '1m' },
      { map: 'Survival_1', sietchName: 'Southern Watch', phase: 'Running', ready: 'True', players: '7', age: '1m' },
    ]
    render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    fireEvent.change(screen.getByRole('combobox', { name: 'Select map' }), { target: { value: 'Survival_1:1' } })
    const card = screen.getByRole('complementary', { name: 'Selected map details' })
    expect(within(card).getByText('Southern Watch')).toBeInTheDocument()
    expect(within(card).getByText('Hagga Basin')).toBeInTheDocument()
    expect(within(card).getByText('Reported players').nextElementSibling).toHaveTextContent('7')
    fireEvent.change(screen.getByRole('combobox', { name: 'Select map' }), { target: { value: 'Survival_1:0' } })
    expect(within(card).getByText('Northern Watch')).toBeInTheDocument()
    expect(within(card).getByText('Reported players').nextElementSibling).toHaveTextContent('3')
    expect(screen.queryByRole('status', { name: 'Selected map card' })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Disable 3D' }))
    expect(screen.queryByRole('status', { name: 'Selected map card' })).not.toBeInTheDocument()
    expect(screen.getByRole('complementary', { name: 'Map status roster' })).toBeVisible()
  })
  it('keeps a status-only roster alongside 3D and removes the separate lower health section', async () => {
    const view = render(<SpatialHome onDetails={() => {}} />)
    expect(screen.getByRole('complementary', { name: 'Map status roster' })).toBeVisible()
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    expect(state.create.mock.calls[0][5].fitViewport).toBe(true)
    expect(screen.getByRole('complementary', { name: 'Map status roster' })).toBeVisible()
    expect(view.container.querySelector('.spatial-map-health')).toBeNull()
    fireEvent.change(screen.getByRole('combobox', { name: 'Select map' }), { target: { value: 'Two:0' } })
    expect(screen.getByRole('heading', { name: 'Two', level: 2 })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Disable 3D' }))
    expect(screen.getByRole('complementary', { name: 'Map status roster' })).toBeVisible()
  })
  it('selects status rows without requesting map-facing rotation, even when reselected', async () => {
    render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    fireEvent.click(screen.getByRole('button', { name: /^Select One:/ }))
    fireEvent.click(screen.getByRole('button', { name: /^Select One:/ }))
    expect(state.select).toHaveBeenLastCalledWith('One:0')
  })
  it('keeps the tool workspace available when graphics fail', async () => {
    state.create.mockImplementation(() => { throw new Error('WebGL unavailable') })
    render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await screen.findByText(/3D could not start/)
    fireEvent.click(screen.getByRole('button', { name: /Select Two/ }))
    expect(screen.getByRole('link', { name: 'Open map workspace' })).toHaveAttribute('href', '/map')
    expect(screen.getByRole('button', { name: /Select Two/ })).toBeInTheDocument()
  })
  it('starts route pulses after explicit 3D consent and recolors without rebuilding graphics', async () => {
    state.status!.bg!.gameServers = ['Survival_1', 'DeepDesert_1'].map(map => ({ map, phase: 'Running', ready: 'True', players: '0', age: '1m' }))
    render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    expect(state.motion).toHaveBeenCalledWith(true)
    fireEvent.click(screen.getByRole('button', { name: 'Signal runners' }))
    expect(state.motion).toHaveBeenLastCalledWith(false)
    fireEvent.change(screen.getByRole('combobox', { name: 'Workspace palette' }), { target: { value: 'daylight' } })
    expect(state.palette).toHaveBeenCalled()
    expect(state.create).toHaveBeenCalledOnce()
    expect(document.documentElement.style.colorScheme).toBe('light')
    fireEvent.click(screen.getByRole('button', { name: 'Signal runners' }))
    expect(state.motion).toHaveBeenLastCalledWith(true)
  })
  it('replaces the intro with a globe workspace and makes rotation opt-in', async () => {
    render(<SpatialHome onDetails={() => {}} />)
    expect(screen.queryByText(/Your world/)).not.toBeInTheDocument()
    expect(screen.queryByText('A world within reach.')).not.toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Arrakis', level: 1 })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    expect(state.spin).toHaveBeenLastCalledWith(false)
    fireEvent.click(screen.getByRole('button', { name: 'Auto rotate' }))
    expect(state.spin).toHaveBeenLastCalledWith(true)
    fireEvent.click(screen.getByRole('button', { name: 'Auto rotate' }))
    expect(state.spin).toHaveBeenLastCalledWith(false)
  })
  it('uses a new canvas after map membership changes instead of reusing a lost WebGL context', async () => {
    const view = render(<SpatialHome onDetails={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /Enter spatial view/ }))
    await waitFor(() => expect(state.create).toHaveBeenCalledOnce())
    const original = view.container.querySelector('canvas')
    state.status!.bg!.gameServers!.push({ map: 'SH_Arrakeen', phase: 'Running', ready: 'True', players: '0', age: '1m' })
    state.status = { ...state.status!, bg: { ...state.status!.bg!, gameServers: [...state.status!.bg!.gameServers!] } }
    view.rerender(<ThemeProvider><SpatialHome onDetails={() => {}} /></ThemeProvider>)
    await waitFor(() => expect(state.create).toHaveBeenCalledTimes(2))
    expect(state.dispose).toHaveBeenCalledOnce()
    expect(view.container.querySelector('canvas')).not.toBe(original)
  })
  it('carries the same navigation and palettes into a real tool surface', () => {
    window.history.replaceState({}, '', '/players?view=inventory')
    render(<SpatialFrame tools><h1>Inventory tools</h1><button>Existing guarded action</button></SpatialFrame>)
    expect(screen.getByRole('heading', { name: 'Inventory tools' })).toBeInTheDocument()
    expect(within(screen.getByRole('navigation', { name: 'Workspace dock' })).getByRole('link', { name: 'Players' })).toHaveAttribute('aria-current', 'page')
    expect(screen.getByRole('link', { name: 'DST home' })).toHaveAttribute('href', '/')
    expect(screen.queryByRole('navigation', { name: 'Workspace location' })).not.toBeInTheDocument()
    expect(screen.getByRole('option', { name: /Daylight/ })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Atreides' })).toBeInTheDocument()
    expect(state.create).not.toHaveBeenCalled()
    fireEvent.keyDown(window, { key: 'k', ctrlKey: true })
    expect(screen.getByRole('textbox', { name: 'Search DST tools' })).toHaveFocus()
    fireEvent.change(screen.getByRole('textbox', { name: 'Search DST tools' }), { target: { value: 'ammo' } })
    expect(within(screen.getByRole('dialog')).getByRole('link', { name: /Players/ })).toHaveAttribute('href', '/players')
    fireEvent.click(screen.getByRole('button', { name: 'Close tool finder' }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })
  it('persists palettes across remounts while keeping the default unchanged', () => {
    const first = render(<SpatialFrame tools>Tools</SpatialFrame>)
    fireEvent.change(screen.getByRole('combobox', { name: 'Workspace palette' }), { target: { value: 'daylight' } })
    first.unmount()
    render(<SpatialFrame tools>Tools</SpatialFrame>)
    expect(screen.getByRole('combobox', { name: 'Workspace palette' })).toHaveValue('daylight')
    fireEvent.change(screen.getByRole('combobox', { name: 'Workspace palette' }), { target: { value: 'atreides' } })
    expect(document.documentElement.style.colorScheme).toBe('dark')
  })
})
