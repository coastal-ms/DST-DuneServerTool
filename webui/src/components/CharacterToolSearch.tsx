import { Icon } from './Icon'
import { useState } from 'react'
import type { CharacterHome, CharacterItemView, CharacterProgressionView } from './CharacterHomeNavigation'

export type CharacterToolDestination = {
  label: string
  home: CharacterHome
  view: string
  keywords: string
  itemView?: CharacterItemView
  progressionView?: CharacterProgressionView | 'Codex'
}

// Destinations describe where controls live; execution and prerequisites remain
// with the target mode's action adapters and server-side guards.
export function characterToolDestinations(mode: 'solo' | 'self-host'): CharacterToolDestination[] {
  return [
    { label: 'Character snapshot', home: 'Overview', view: 'Snapshot', keywords: 'stats health level experience xp' },
    { label: 'Currencies', home: 'Overview', view: 'Currency & identity', keywords: 'solari money intel spice' },
    { label: 'Character Inventory', home: 'Items', view: 'Character Inventory', itemView: 'Character Inventory', keywords: 'backpack inventory bag equipment reserve recover restore durability stack water ammunition emotes contract items' },
    { label: 'Give & repair', home: 'Items', view: 'Give & repair', itemView: 'Give & repair', keywords: 'give grant item package repair equipment water refill augment' },
    { label: 'Appearance', home: 'Items', view: 'Appearance', itemView: 'Appearance', keywords: 'cosmetic building set armor weapon vehicle skin dye swatch customization' },
    { label: 'Import Blueprint', home: 'Items', view: 'Blueprints', itemView: 'Blueprints', keywords: 'blueprint import base layout json solido' },
    { label: 'Vehicles', home: 'Items', view: 'Vehicles', itemView: 'Vehicles', keywords: 'vehicle kit tank regis' },
    { label: 'Specializations', home: 'Progression', view: 'Specializations', progressionView: 'Specializations', keywords: 'specs levels class experience xp' },
    { label: 'Journey', home: 'Progression', view: 'Journey', progressionView: 'Journey', keywords: 'quests objectives story chapter 3 iii great convention lost harvest dlc journey' },
    { label: 'Unlocks & rewards', home: 'Progression', view: 'Unlocks & rewards', progressionView: 'Unlocks & rewards', keywords: 'trainer testing station research skill points faction progression reward' },
    ...(mode === 'solo' ? [{ label: 'Codex', home: 'Progression' as const, view: 'Codex', progressionView: 'Codex' as const, keywords: 'codex lore discovery ownership' }] : []),
    mode === 'solo'
      ? { label: 'Solo diagnostics', home: 'Advanced', view: 'Diagnostics', keywords: 'diagnostics report support' }
      : { label: 'Character tags', home: 'Advanced', view: 'Character tags', keywords: 'flags raw tags add remove' },
    mode === 'solo'
      ? { label: 'Retained backups', home: 'Activity', view: 'History', keywords: 'backup recovery restore activity' }
      : { label: 'History', home: 'Activity', view: 'History', keywords: 'events activity log' },
  ]
}

export function CharacterToolSearch({ onSelect }: { onSelect: (destination: CharacterToolDestination) => void }) {
  const [query, setQuery] = useState('')
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean)
  const results = characterToolDestinations('solo').filter(item =>
    words.every(word => `${item.label} ${item.keywords}`.toLowerCase().includes(word)))
  return <>
    <div className="player-tool-search">
      <Icon name="Search" size={16} />
    <input type="search"  aria-label="Find a character tool" placeholder="Find a character tool…"
      value={query} onChange={event => setQuery(event.target.value)} />
    </div>
    {words.length > 0 && <div className="player-tool-results" aria-label="Character tool search results" role="region">
      {results.map(item => <button type="button"  key={item.label}
        onClick={() => { onSelect(item); setQuery('') }}><span>{item.label}</span>{' '}<small>{item.home}</small></button>)}
      {results.length === 0 && <p className="text-muted text-sm" role="status">No matching character tools.</p>}
    </div>}
  </>
}
