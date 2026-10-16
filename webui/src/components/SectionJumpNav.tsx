import { useEffect, useState, type RefObject } from 'react'
import { useLocation } from '../router'
import { Icon } from './Icon'
import { useCommandDeck } from '../hooks/useCommandDeck'
import './platform/workspaceChrome.css'

type SectionItem = {
  id: string
  label: string
  element: HTMLElement
}

function sameSections(left: SectionItem[], right: SectionItem[]) {
  return left.length === right.length &&
    left.every((section, index) =>
      section.id === right[index]?.id && section.label === right[index]?.label && section.element === right[index]?.element)
}

export function SectionJumpNav({ containerRef }: { containerRef: RefObject<HTMLElement | null> }) {
  const contextual = useCommandDeck()
  const { pathname } = useLocation()
  const [sections, setSections] = useState<SectionItem[]>([])
  const [selected, setSelected] = useState('')
  const [focused, setFocused] = useState(false)

  useEffect(() => {
    const container = containerRef.current
    if (!container) return
    setFocused(false)

    const collect = () => {
      const next = Array.from(container.querySelectorAll<HTMLElement>('[data-section-nav-id]'))
        .filter(element => !element.closest('[hidden]'))
        .map(element => ({
          id: element.dataset.sectionNavId ?? '',
          label: element.dataset.sectionNavLabel ?? '',
          element,
        }))
        .filter(section => section.id && section.label)
        .filter((section, index, all) => all.findIndex(item => item.id === section.id) === index)

      setSections(current => sameSections(current, next) ? current : next)
      setSelected(current => next.some(section => section.id === current)
        ? current
        : (next[0]?.id ?? ''))
    }

    collect()
    const observer = new MutationObserver(collect)
    observer.observe(container, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden'] })
    return () => observer.disconnect()
  }, [containerRef, pathname])

  useEffect(() => {
    if (!contextual || !focused) return
    const target = sections.find(section => section.id === selected)?.element
    if (!target) return
    const hidden = sections.filter(section => section.element !== target && !section.element.contains(target) && !target.contains(section.element))
    hidden.forEach(section => section.element.setAttribute('data-portal-section-inactive', ''))
    return () => hidden.forEach(section => section.element.removeAttribute('data-portal-section-inactive'))
  }, [contextual, focused, sections, selected])

  if (sections.length < 2) return null

  const registeredElements = () =>
    Array.from(containerRef.current?.querySelectorAll<HTMLElement>('[data-section-nav-id]') ?? [])
      .filter(element => !element.closest('[hidden]'))

  const collapseSections = (exceptId = '') => {
    const target = registeredElements().find(section => section.dataset.sectionNavId === exceptId)
    for (const section of registeredElements()) {
      if (section === target || target?.contains(section) || (target && section.contains(target))) continue
      const toggle = section.querySelector<HTMLButtonElement>('button[data-section-nav-toggle]')
      if (toggle?.closest('[data-section-nav-id]') === section && toggle.getAttribute('aria-expanded') === 'true') toggle.click()
    }
  }

  const jumpTo = (id: string) => {
    setSelected(id)
    if (contextual) setFocused(true)
    const container = containerRef.current
    const target = Array.from(container?.querySelectorAll<HTMLElement>('[data-section-nav-id]') ?? [])
      .find(element => element.dataset.sectionNavId === id)
    if (!target) return

    collapseSections(id)
    const candidateToggle = target.querySelector<HTMLButtonElement>('button[data-section-nav-toggle]')
    const sectionToggle = candidateToggle?.closest('[data-section-nav-id]') === target ? candidateToggle : null
    if (sectionToggle?.getAttribute('aria-expanded') === 'false') sectionToggle.click()
    const focusTarget: HTMLElement = sectionToggle ?? target
    if (focusTarget === target && !target.hasAttribute('tabindex')) target.tabIndex = -1
    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    window.requestAnimationFrame(() => {
      target.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' })
      focusTarget.focus({ preventScroll: true })
    })
  }

  if (contextual) return <nav className="workspace-section-nav" aria-label="Workspace sections">
    <div className="workspace-section-strip">
      {sections.map(section => <button key={section.id} type="button" aria-pressed={selected === section.id} onClick={() => jumpTo(section.id)}>{section.label}</button>)}
    </div>
    <select className="workspace-section-picker" aria-label="Jump to section" value={selected} onChange={event => jumpTo(event.target.value)}>
      {sections.map(section => <option key={section.id} value={section.id}>{section.label}</option>)}
    </select>
    {focused && <button className="portal-sections-overview" type="button" onClick={() => setFocused(false)}>All sections</button>}
    <button className="workspace-section-collapse" type="button" aria-label="Collapse all sections" title="Collapse all sections" onClick={() => collapseSections()}><Icon name="ChevronsUp" size={17} /></button>
  </nav>

  return (
    <div className="sticky top-0 z-30 mb-4 -mx-1 rounded-lg border border-border bg-base/95 px-3 py-2 shadow-[0_6px_18px_-12px_rgba(0,0,0,0.8)] backdrop-blur-sm">
      <label className="flex items-center gap-2 text-sm">
        <Icon name="ListFilter" size={15} className="shrink-0 text-accent-bright" />
        <span className="shrink-0 font-medium text-text-muted">Jump to section</span>
        <select
          aria-label="Jump to section"
          value={selected}
          onChange={event => jumpTo(event.target.value)}
          className="min-w-0 flex-1 rounded-md border border-border bg-surface-2 px-2.5 py-1.5 text-sm text-text focus:outline-none focus-visible:ring-2 focus-visible:ring-ibad sm:max-w-sm"
        >
          {sections.map(section => (
            <option key={section.id} value={section.id}>{section.label}</option>
          ))}
        </select>
        <button
          type="button"
          aria-label="Collapse all sections"
          title="Collapse all sections"
          onClick={() => collapseSections()}
          className="btn-secondary shrink-0 px-2 py-1.5"
        >
          <Icon name="ChevronsUp" size={15} />
        </button>
      </label>
    </div>
  )
}
