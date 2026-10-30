import { useId, useState, type ReactNode } from 'react'
import { Icon } from '../../components/Icon'
import { COMMAND_CATEGORIES } from './categories'
import './commandCategories.css'

type CategoryTask = { id: string; label: string; group: string; rowNote?: string }
export type CategoryPageGroup = { id: string; label: string; icon: string; description?: string }

export function CommandCategoryPages<T extends CategoryTask>({
  tasks, category, onCategory, busy, renderTask,
  groups: groupDefs = COMMAND_CATEGORIES,
  searchPlaceholder = 'Search all commands...',
  searchAriaLabel = 'Search all commands',
  controlsLabel = 'Command controls',
  categoriesNavLabel = 'Command categories',
  allLabel = 'All controls',
  countNoun = 'controls',
  emptySearchLabel = 'No matching commands.',
}: {
  tasks: readonly T[]
  category: string
  onCategory: (category: string) => void
  busy: boolean
  renderTask: (task: T) => ReactNode
  groups?: readonly CategoryPageGroup[]
  searchPlaceholder?: string
  searchAriaLabel?: string
  controlsLabel?: string
  categoriesNavLabel?: string
  allLabel?: string
  countNoun?: string
  emptySearchLabel?: string
}) {
  const [query, setQuery] = useState('')
  const headingId = useId()
  const groups = groupDefs.map(group => ({ ...group, tasks: tasks.filter(task => task.group === group.id) }))
    .filter(group => group.tasks.length)
  const activeCategory = category === 'all' || groups.some(group => group.id === category) ? category : groups[0]?.id
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean)
  const searching = words.length > 0
  const visible = groups.filter(group => searching || activeCategory === 'all' || group.id === activeCategory)
    .map(group => ({ ...group, tasks: group.tasks.filter(task =>
      words.every(word => `${task.label} ${group.label} ${task.rowNote ?? ''}`.toLowerCase().includes(word))) }))
    .filter(group => group.tasks.length)
  const count = visible.reduce((total, group) => total + group.tasks.length, 0)
  function chooseCategory(value: string) {
    onCategory(value)
    setQuery('')
  }
  return (
    <section className="command-categories" aria-label={controlsLabel}>
      <header className="command-category-search">
        <label><Icon name="Search" size={16} /><input type="search" aria-label={searchAriaLabel} placeholder={searchPlaceholder} value={query} disabled={busy} onChange={event => setQuery(event.target.value)} /></label>
        <span role="status">{count} of {tasks.length} {countNoun}</span>
      </header>
      <div className="command-category-layout" style={groups.length < 2 ? {display:'block'} : undefined}>
        {groups.length > 1 && <nav aria-label={categoriesNavLabel}>
          {groups.map(group => <button key={group.id} type="button" aria-pressed={!searching && activeCategory === group.id} disabled={busy} onClick={() => chooseCategory(group.id)}>
            <Icon name={group.icon} size={17} /><span>{group.label}</span><small aria-hidden="true">{group.tasks.length}</small>
          </button>)}
          <button type="button" aria-pressed={!searching && activeCategory === 'all'} disabled={busy} onClick={() => chooseCategory('all')}>
            <Icon name="LayoutGrid" size={17} /><span>{allLabel}</span><small aria-hidden="true">{tasks.length}</small>
          </button>
        </nav>}
        {groups.length > 1 && <label className="command-category-mobile">Category
          <select value={searching ? 'search' : (activeCategory ?? 'all')} disabled={busy} onChange={event => chooseCategory(event.target.value)}>
            {searching && <option value="search" disabled>Search results</option>}
            {groups.map(group => <option key={group.id} value={group.id}>{group.label} ({group.tasks.length})</option>)}
            <option value="all">{allLabel} ({tasks.length})</option>
          </select>
        </label>}
        <div className="command-category-content">
          {searching && <h3 className="command-search-heading">Search results</h3>}
          {!count && <div className="command-category-empty" role="status">
            <p>{searching ? emptySearchLabel : 'No commands available.'}</p>
            {searching && <button type="button" className="btn-secondary" onClick={() => setQuery('')}>Clear search</button>}
          </div>}
          {visible.map(group => <section key={group.id} aria-labelledby={`${headingId}-${group.id}`}>
            <header className="command-category-heading">
              <h3 id={`${headingId}-${group.id}`}>{group.label}</h3><p>{group.description}</p>
            </header>
            <div className="command-control-grid">
              {group.tasks.map(task => <article className="command-control" key={task.id} aria-label={task.label}>{renderTask(task)}</article>)}
            </div>
          </section>)}
        </div>
      </div>
    </section>
  )
}
