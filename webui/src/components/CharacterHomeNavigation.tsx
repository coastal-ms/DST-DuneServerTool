import { Icon } from './Icon'

export const CHARACTER_HOMES = [
  { id: 'Overview', label: 'Overview', icon: 'User' },
  { id: 'Items', label: 'Items', icon: 'Backpack' },
  { id: 'Progression', label: 'Progression', icon: 'Sparkles' },
  { id: 'Activity', label: 'Activity', icon: 'History' },
  { id: 'Advanced', label: 'Advanced', icon: 'SlidersHorizontal' },
] as const
export type CharacterHome = typeof CHARACTER_HOMES[number]['id']
export const CHARACTER_ITEM_VIEWS = ['Character Inventory', 'Give & repair', 'Appearance', 'Blueprints', 'Vehicles'] as const
export type CharacterItemView = typeof CHARACTER_ITEM_VIEWS[number]
export const CHARACTER_PROGRESSION_VIEWS = ['Specializations', 'Journey', 'Unlocks & rewards'] as const
export type CharacterProgressionView = typeof CHARACTER_PROGRESSION_VIEWS[number]

export function CharacterViewNavigation<T extends string>({ views, value, onChange, ariaLabel,
  className = 'flex flex-wrap gap-2 mb-4', buttonClassName = 'btn-secondary text-sm',
}: { views: readonly T[]; value: T; onChange: (value: T) => void; ariaLabel: string; className?: string; buttonClassName?: string }) {
  return <nav className={className} aria-label={ariaLabel}>
    {views.map(view => <button type="button" key={view} aria-pressed={view === value}
      className={`${buttonClassName} ${buttonClassName && view === value ? 'border-accent text-accent-bright' : ''}`}
      onClick={() => onChange(view)}>{view}</button>)}
  </nav>
}

export function CharacterHomeNavigation<T extends string>({ options, value, onChange,
  className = 'flex flex-wrap gap-2 mb-4', ariaLabel = 'Character sections', buttonClassName,
}: {
  options: readonly { id: T; label: string; icon: string }[]
  value: T
  onChange: (value: T) => void
  className?: string
  ariaLabel?: string
  buttonClassName?: string
}) {
  return <nav className={className} aria-label={ariaLabel}>
    {options.map(item => <button type="button" key={item.id} aria-pressed={value === item.id}
      className={buttonClassName ?? `btn-secondary ${value === item.id ? 'border-accent text-accent-bright' : ''}`}
      onClick={() => onChange(item.id)}><Icon name={item.icon} size={17} />{item.label}</button>)}
  </nav>
}
