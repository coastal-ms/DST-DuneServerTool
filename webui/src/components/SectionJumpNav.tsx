import { useEffect, useState, type RefObject } from 'react'
import { useLocation } from '../router'
import { Icon } from './Icon'

type SectionItem = {
  id: string
  label: string
}

function sameSections(left: SectionItem[], right: SectionItem[]) {
  return left.length === right.length &&
    left.every((section, index) =>
      section.id === right[index]?.id && section.label === right[index]?.label)
}

export function SectionJumpNav({ containerRef }: { containerRef: RefObject<HTMLElement | null> }) {
  const { pathname } = useLocation()
  const [sections, setSections] = useState<SectionItem[]>([])
  const [selected, setSelected] = useState('')

  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    const collect = () => {
      const next = Array.from(container.querySelectorAll<HTMLElement>('[data-section-nav-id]'))
        .map(element => ({
          id: element.dataset.sectionNavId ?? '',
          label: element.dataset.sectionNavLabel ?? '',
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
    observer.observe(container, { childList: true, subtree: true })
    return () => observer.disconnect()
  }, [containerRef, pathname])

  if (sections.length < 2) return null

  const registeredElements = () =>
    Array.from(containerRef.current?.querySelectorAll<HTMLElement>('[data-section-nav-id]') ?? [])

  const collapseSections = (exceptId = '') => {
    for (const section of registeredElements()) {
      if (section.dataset.sectionNavId === exceptId) continue
      const toggle = section.querySelector<HTMLButtonElement>('button[data-section-nav-toggle]')
      if (toggle?.getAttribute('aria-expanded') === 'true') toggle.click()
    }
  }

  const jumpTo = (id: string) => {
    setSelected(id)
    const container = containerRef.current
    const target = Array.from(container?.querySelectorAll<HTMLElement>('[data-section-nav-id]') ?? [])
      .find(element => element.dataset.sectionNavId === id)
    if (!target) return

    collapseSections(id)
    const sectionToggle = target.querySelector<HTMLButtonElement>('button[data-section-nav-toggle]')
    if (sectionToggle?.getAttribute('aria-expanded') === 'false') sectionToggle.click()
    const focusTarget: HTMLElement = sectionToggle ?? target
    if (focusTarget === target && !target.hasAttribute('tabindex')) target.tabIndex = -1
    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    window.requestAnimationFrame(() => {
      target.scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'start' })
      focusTarget.focus({ preventScroll: true })
    })
  }

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
