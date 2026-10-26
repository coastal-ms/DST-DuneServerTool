import { BlueprintImport } from './BlueprintImport'
import { useEffect, useMemo, useRef, useState } from 'react'
import { usePortalAccess } from '../../../auth/portalAccess'
import { Icon } from '../../../components/Icon'
import { mapLabel } from '../../../util/mapLabel'
import { ActionsSection, InventorySection, SECTION_COMPONENTS, getPlayerActionTools, type SectionId, type SectionProps } from './sections'
import './playerManagement.css'
import './playersDesk.css'

export type PlayerHome = 'Overview' | 'Items' | 'Progression' | 'Activity' | 'Advanced'
export function playerToolHome(group: string, id: string): PlayerHome {
  if (group === 'Items' || group === 'Vehicle') return 'Items'
  if (group === 'Progression') return 'Progression'
  if (group === 'Currency' || id === 'rename') return 'Overview'
  return 'Advanced'
}
const homes: PlayerHome[] = ['Overview', 'Items', 'Progression', 'Activity', 'Advanced']
const homeIcons = { Overview: 'User', Items: 'Backpack', Progression: 'Sparkles', Activity: 'History', Advanced: 'SlidersHorizontal' }
const legacy: Record<SectionId, [PlayerHome, string]> = {
  stats: ['Overview', 'Snapshot'], manage: ['Items', 'Give & repair'], inventory: ['Items', 'Character Inventory'],
  specs: ['Progression', 'Specializations'], journey: ['Progression', 'Journey'], landsraad: ['Progression', 'Landsraad'],
  tags: ['Advanced', 'Character tags'], history: ['Activity', 'History'], actions: ['Advanced', 'All tools'],
}
const searches: Record<string, string> = {
  'give-solari': 'money currency balance', 'give-scrip': 'money currency balance', 'give-intel': 'research knowledge points',
  'grant-cosmetic': 'appearance skins dyes outfits building sets', 'repair-gear': 'fix durability armor weapons backpack',
  'give-vehicle-kit': 'vehicle parts assembly', rename: 'name identity', 'reset-journey': 'quest story restart',
}
const appearance = new Set(['grant-cosmetic', 'grant-building-sets', 'grant-armor-skins', 'grant-weapon-skins', 'grant-vehicle-skins',
  'grant-all-dyes', 'grant-house-swatches', 'grant-buildable-swatches', 'observed-character-swatches', 'observed-gear-appearances'])

export function PlayerManagement(props: SectionProps & { initialSection?: SectionId; focused?: boolean }) {
  const { isPlayer } = usePortalAccess()
  const initial = legacy[props.initialSection ?? 'stats']
  const [home, setHome] = useState<PlayerHome>(initial[0])
  const [view, setView] = useState(() => props.initialSection === 'inventory' && /(?:scope_type|location_type)=storage/.test(window.location.search) ? 'Storage containers' : initial[1])
  const [tool, setTool] = useState<string | null>(null)
  const [query, setQuery] = useState('')
  const [feedback, setFeedback] = useState<{ message: string; kind: 'ok' | 'err' | 'info' } | null>(null)
  const [working, setWorking] = useState<string | null>(null)
  const currentPlayer = useRef(props.player.id)
  currentPlayer.current = props.player.id
  useEffect(() => {
    setTool(null); setQuery(''); setFeedback(null); setWorking(null)
  }, [props.player.id])
  useEffect(() => {
    if (!feedback || feedback.kind === 'err' || working) return
    const timer = window.setTimeout(() => setFeedback(null), 5000)
    return () => window.clearTimeout(timer)
  }, [feedback, working])
  const tools = useMemo(() => getPlayerActionTools(isPlayer), [isPlayer])
  const views: Record<PlayerHome, string[]> = {
    Overview: ['Snapshot', 'Currency & identity'],
    Items: ['Character Inventory', 'Storage containers', 'Give & repair', 'Appearance', 'Blueprints', ...(tools.some(item => item.group === 'Vehicle') ? ['Vehicles'] : []), 'Bank'],
    Progression: ['Specializations', 'Journey', 'Unlocks & rewards', ...(!isPlayer ? ['Landsraad'] : [])],
    Activity: ['History'], Advanced: ['Character tags', 'Session controls', 'Identity & resets', 'All tools'],
  }
  const destinations = [
    { label: 'Import Blueprint', home: 'Items' as const, view: 'Blueprints', keywords: 'blueprint import base layout json solido' },
    { label: 'Bank', home: 'Items' as const, view: 'Bank', keywords: 'bank storage' },
    { label: 'Storage containers', home: 'Items' as const, view: 'Storage containers', keywords: 'inventory chests bases' },
    { label: 'Character Inventory', home: 'Items' as const, view: 'Character Inventory', keywords: 'backpack inventory bag equipment reserve recover restore durability stack water ammunition emotes contract items' },
    { label: 'Specializations', home: 'Progression' as const, view: 'Specializations', keywords: 'specs levels skills rewards' },
    { label: 'Journey', home: 'Progression' as const, view: 'Journey', keywords: 'quests objectives story chapters' },
    ...(!isPlayer ? [{ label: 'Landsraad', home: 'Progression' as const, view: 'Landsraad', keywords: 'house contributions' }] : []),
    { label: 'Character tags', home: 'Advanced' as const, view: 'Character tags', keywords: 'flags raw tags' },
    { label: 'History', home: 'Activity' as const, view: 'History', keywords: 'events activity log' },
  ]
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean)
  const matches = (text: string) => words.every(word => text.toLowerCase().includes(word))
  function navigate(nextHome: PlayerHome, nextView?: string, nextTool: string | null = null) {
    props.onFlush?.()
    const url = new URL(window.location.href)
    if (['scope_type', 'scope_id', 'location_type', 'location_id', 'q'].some(key => url.searchParams.has(key))) {
      for (const key of ['scope_type', 'scope_id', 'location_type', 'location_id', 'q']) url.searchParams.delete(key)
      window.history.replaceState(null, '', url)
      window.dispatchEvent(new PopStateEvent('popstate'))
    }
    setHome(nextHome); setView(nextView ?? views[nextHome][0]); setTool(nextTool); setQuery('')
  }
  function openTool(id: string) {
    const selected = tools.find(item => item.id === id)
    if (selected) navigate(playerToolHome(selected.group, selected.id), undefined, id)
  }
  const selectedTool = tools.find(item => item.id === tool)
  const shared = { ...props, onOpenTool: openTool,
    onWorking: (label: string | null) => { if (currentPlayer.current === props.player.id) setWorking(label) },
    flash: (message: string, kind: 'ok' | 'err' | 'info' = 'ok') => { if (currentPlayer.current === props.player.id) setFeedback({ message, kind }) } }
  let body
  if (tool && selectedTool) body = <>
    <div className="player-tool-heading"><h3>{selectedTool.label}</h3><button className="btn-secondary" onClick={() => navigate(home)}>Back to {home.toLowerCase()}</button></div>
    <ActionsSection key={`${props.player.id}:${tool}`} {...shared} actionIds={[tool]} initialAction={tool} />
  </>
  else if (view === 'Snapshot') {
    const Stats = SECTION_COMPONENTS.stats
    body = <><Stats {...shared} /><div className="player-common-tasks" aria-label="Common player tasks">
      {['give-solari', 'rename', 'give-item', 'repair-gear', 'grant-cosmetic'].filter(id => tools.some(item => item.id === id)).map(id =>
        <button key={id} className="btn-secondary" onClick={() => openTool(id)}>{tools.find(item => item.id === id)?.label}</button>)}
    </div></>
  } else if (view === 'Bank' || view === 'Storage containers') body = <InventorySection key={`${props.player.id}:${view}`} {...shared} embedded initialView={view === 'Storage containers' ? 'storage' : 'bank'} />
  else {
    const section: SectionId | undefined = ({ Specializations: 'specs', Journey: 'journey', Landsraad: 'landsraad', History: 'history', 'Character tags': 'tags' } as Record<string, SectionId>)[view]
    if (section) { const Component = SECTION_COMPONENTS[section]; body = <Component {...shared} /> }
    else if (view === 'Blueprints') body = <BlueprintImport key={props.player.id} player={props.player} canWrite={props.canWrite} onChanged={props.onChanged} />
    else if (view === 'Character Inventory') body = <InventorySection {...shared} key={props.player.id} embedded initialView="tools" />
    else {
      const list = tools.filter(item => {
        if (view === 'All tools') return true
        if (view === 'Currency & identity') return item.group === 'Currency' || item.id === 'rename'
        if (view === 'Appearance') return appearance.has(item.id)
        if (view === 'Give & repair') return item.group === 'Items' && !appearance.has(item.id)
        if (view === 'Vehicles') return item.group === 'Vehicle'
        if (view === 'Unlocks & rewards') return item.group === 'Progression'
        if (view === 'Session controls') return item.group === 'Live'
        return (item.group === 'Identity' && item.id !== 'rename') || item.group === 'Danger'
      })
      body = <div className="player-tool-list">{list.map(item => <button key={item.id} onClick={() => openTool(item.id)} className="player-tool-choice">
        <Icon name={homeIcons[playerToolHome(item.group, item.id)]} size={20} className="player-tool-icon" />
        <span><strong>{item.label}</strong>{item.note && <small>{item.note}</small>}</span>
        <span className="player-tool-requirement">{item.onlineOnly ? 'Online required' : item.offlineOnly ? 'Offline required' : 'Open'}<Icon name="ChevronRight" size={16} /></span>
      </button>)}{!list.length && <p className="text-sm text-text-muted">No tools available in this category.</p>}</div>
    }
  }
  return <section className={`player-management${props.focused ? ' player-management-focused players-desk' : ''}`} aria-label={props.focused ? 'My character management' : 'Player management'}>
    {props.focused && <header className="player-character-banner">
      <span className="player-character-avatar"><Icon name="User" size={28} /></span>
      <div className="player-character-title"><h2>{props.player.name}</h2><p>{[props.player.faction_name, props.player.class, mapLabel(props.player.map || '')].filter(Boolean).join(' · ')}</p></div>
      <span className="player-character-status" data-online={props.player.online_status.toLowerCase() === 'online'}><span />{props.player.online_status}</span>
    </header>}
    <div className="player-tool-search"><label className="sr-only" htmlFor={`player-tools-${props.player.id}`}>Find a player tool</label>
      <Icon name="Search" size={16} /><input id={`player-tools-${props.player.id}`} type="search" value={query} onChange={event => setQuery(event.target.value)} placeholder="Find a player tool… repair, money, skins" />
    </div>
    {!!words.length && <div role="region" className="player-tool-results" aria-label="Player tool search results">
      {tools.filter(item => matches(`${item.label} ${item.group} ${item.note} ${searches[item.id] ?? ''}`)).map(item =>
        <button key={item.id} onClick={() => openTool(item.id)}><span>{item.label}</span><small>{playerToolHome(item.group, item.id)}</small></button>)}
      {destinations.filter(item => matches(`${item.label} ${item.keywords}`)).map(item => <button key={item.label} onClick={() => navigate(item.home, item.view)}><span>{item.label}</span><small>{item.home}</small></button>)}
      {!tools.some(item => matches(`${item.label} ${item.group} ${item.note} ${searches[item.id] ?? ''}`)) && !destinations.some(item => matches(`${item.label} ${item.keywords}`)) && <p>No matching tools.</p>}
    </div>}
    <nav className="player-home-nav" aria-label="Character sections">{homes.map(item => <button key={item} aria-pressed={home === item} onClick={() => navigate(item)}><Icon name={homeIcons[item]} size={17} />{item}</button>)}</nav>
    {!tool && views[home].length > 1 && <nav className="player-view-nav" aria-label={`${home} views`}>{views[home].map(item => <button key={item} aria-pressed={view === item} onClick={() => navigate(home, item)}>{item}</button>)}</nav>}
    <div className="player-management-content" key={props.player.id}>{body}</div>
    {(working || feedback) && <div className="player-operation-feedback" data-kind={working ? 'info' : feedback?.kind} role={feedback?.kind === 'err' && !working ? 'alert' : 'status'}>
      <Icon name={working ? 'Loader2' : feedback?.kind === 'err' ? 'AlertCircle' : feedback?.kind === 'info' ? 'Info' : 'CheckCircle2'} size={18} className={working ? 'animate-spin motion-reduce:animate-none' : ''} />
      <span>{working ? `${working}…` : feedback?.message}</span>
      {!working && <button aria-label="Dismiss action result" onClick={() => setFeedback(null)}><Icon name="X" size={18} /></button>}
    </div>}
  </section>
}
