import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { arrayMove } from '@dnd-kit/sortable'
import {
  GROUP_ORDER,
  getVisibleGroupLabel,
  type NavGroup,
  type NavItem,
} from '../nav'

export const SIDEBAR_ORDER_STORAGE_KEY = 'dst.sidebar.navigation-preferences.v3'
export const SIDEBAR_ORDER_V2_STORAGE_KEY = 'dst.sidebar.navigation-order.v2'
export const SIDEBAR_ORDER_V1_STORAGE_KEY = 'dst.sidebar.navigation-order.v1'
export const SIDEBAR_DIVIDER_LABEL_MAX_LENGTH = 48

export type SidebarPageEntry = {
  type: 'page'
  id: string
}

export type SidebarDividerEntry = {
  type: 'divider'
  id: string
  label: string
}

export type SidebarNavigationEntry = SidebarPageEntry | SidebarDividerEntry

export type SidebarNavigationOrder = {
  version: 3
  items: SidebarNavigationEntry[]
  hiddenPageIds: string[]
}

type SidebarNavigationOrderV2 = {
  version: 2
  items: SidebarNavigationEntry[]
}

type SidebarNavigationOrderV1 = {
  version: 1
  groups: Partial<Record<NavGroup, string[]>>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function sanitizeSidebarDividerLabel(value: string) {
  return value
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, SIDEBAR_DIVIDER_LABEL_MAX_LENGTH)
}

function canonicalSidebarItems(canonicalItems: readonly NavItem[]) {
  return canonicalItems.filter(item => !item.sidebarHidden)
}

export function getCanonicalSidebarNavigationOrder(
  canonicalItems: readonly NavItem[],
): SidebarNavigationOrder {
  const sidebarItems = canonicalSidebarItems(canonicalItems)
  const items: SidebarNavigationEntry[] = []

  for (const group of GROUP_ORDER) {
    const groupItems = sidebarItems.filter(item => item.group === group)
    if (groupItems.length === 0) continue
    items.push({
      type: 'divider',
      id: `divider:${group}`,
      label: getVisibleGroupLabel(group),
    })
    items.push(...groupItems.map(item => ({ type: 'page' as const, id: item.to })))
  }

  return { version: 3, items, hiddenPageIds: [] }
}

function migrateV1Order(
  saved: SidebarNavigationOrderV1,
  canonicalItems: readonly NavItem[],
): SidebarNavigationOrder {
  const sidebarItems = canonicalSidebarItems(canonicalItems)
  const items: SidebarNavigationEntry[] = []

  for (const group of GROUP_ORDER) {
    const canonicalGroupIds = sidebarItems
      .filter(item => item.group === group)
      .map(item => item.to)
    if (canonicalGroupIds.length === 0) continue

    const validIds = new Set(canonicalGroupIds)
    const seen = new Set<string>()
    const candidate = Array.isArray(saved.groups[group]) ? saved.groups[group] : []
    const retained = candidate.filter((id): id is string => {
      if (typeof id !== 'string' || !validIds.has(id) || seen.has(id)) return false
      seen.add(id)
      return true
    })

    items.push({
      type: 'divider',
      id: `divider:${group}`,
      label: getVisibleGroupLabel(group),
    })
    items.push(...[...retained, ...canonicalGroupIds.filter(id => !seen.has(id))]
      .map(id => ({ type: 'page' as const, id })))
  }

  return { version: 3, items, hiddenPageIds: [] }
}

function reconcileMissingPages(
  entries: SidebarNavigationEntry[],
  canonical: SidebarNavigationOrder,
) {
  const next = [...entries]
  const presentPages = new Set(
    next.filter((entry): entry is SidebarPageEntry => entry.type === 'page')
      .map(entry => entry.id),
  )

  for (let canonicalIndex = 0; canonicalIndex < canonical.items.length; canonicalIndex += 1) {
    const entry = canonical.items[canonicalIndex]
    if (entry.type !== 'page' || presentPages.has(entry.id)) continue

    let insertionIndex = -1
    for (let previous = 0; previous < canonicalIndex; previous += 1) {
      const previousEntry = canonical.items[previous]
      const found = next.findIndex(item => (
        item.type === previousEntry.type && item.id === previousEntry.id
      ))
      if (found >= 0) insertionIndex = Math.max(insertionIndex, found + 1)
    }
    if (insertionIndex < 0) {
      insertionIndex = next.length
      for (let following = canonicalIndex + 1; following < canonical.items.length; following += 1) {
        const followingEntry = canonical.items[following]
        const found = next.findIndex(item => (
          item.type === followingEntry.type && item.id === followingEntry.id
        ))
        if (found >= 0) {
          insertionIndex = found
          break
        }
      }
    }
    next.splice(insertionIndex, 0, entry)
    presentPages.add(entry.id)
  }

  return next
}

export function normalizeSidebarNavigationOrder(
  saved: unknown,
  canonicalItems: readonly NavItem[],
): SidebarNavigationOrder {
  const canonical = getCanonicalSidebarNavigationOrder(canonicalItems)

  if (isRecord(saved) && saved.version === 1 && isRecord(saved.groups)) {
    return migrateV1Order(saved as SidebarNavigationOrderV1, canonicalItems)
  }
  if (!isRecord(saved)
    || (saved.version !== 2 && saved.version !== 3)
    || !Array.isArray(saved.items)) {
    return canonical
  }

  const validPageIds = new Set(
    canonical.items
      .filter((entry): entry is SidebarPageEntry => entry.type === 'page')
      .map(entry => entry.id),
  )
  const seenIds = new Set<string>()
  const entries: SidebarNavigationEntry[] = []

  for (const candidate of saved.items) {
    if (!isRecord(candidate) || typeof candidate.id !== 'string' || seenIds.has(candidate.id)) {
      continue
    }
    if (candidate.type === 'page' && validPageIds.has(candidate.id)) {
      entries.push({ type: 'page', id: candidate.id })
      seenIds.add(candidate.id)
      continue
    }
    if (candidate.type === 'divider'
      && candidate.id.startsWith('divider:')
      && candidate.id.length <= 100
      && typeof candidate.label === 'string') {
      const label = sanitizeSidebarDividerLabel(candidate.label)
      if (!label) continue
      entries.push({ type: 'divider', id: candidate.id, label })
      seenIds.add(candidate.id)
    }
  }

  const hideablePageIds = new Set(
    canonicalSidebarItems(canonicalItems)
      .filter(item => !item.sidebarAlwaysVisible)
      .map(item => item.to),
  )
  const hiddenPageIds: string[] = []
  const seenHiddenPageIds = new Set<string>()
  const savedHiddenPageIds = saved.version === 3 && Array.isArray(saved.hiddenPageIds)
    ? saved.hiddenPageIds
    : []
  for (const pageId of savedHiddenPageIds) {
    if (typeof pageId !== 'string'
      || !hideablePageIds.has(pageId)
      || seenHiddenPageIds.has(pageId)) {
      continue
    }
    seenHiddenPageIds.add(pageId)
    hiddenPageIds.push(pageId)
  }

  return {
    version: 3,
    items: reconcileMissingPages(entries, canonical),
    hiddenPageIds,
  }
}

export function reorderSidebarNavigationItem(
  order: SidebarNavigationOrder,
  activeId: string,
  overId: string,
): SidebarNavigationOrder {
  const oldIndex = order.items.findIndex(item => item.id === activeId)
  const newIndex = order.items.findIndex(item => item.id === overId)
  if (oldIndex < 0 || newIndex < 0 || oldIndex === newIndex) return order
  return { ...order, items: arrayMove(order.items, oldIndex, newIndex) }
}

export function removeSidebarDivider(
  order: SidebarNavigationOrder,
  dividerId: string,
): SidebarNavigationOrder {
  const item = order.items.find(entry => entry.id === dividerId)
  if (item?.type !== 'divider') return order
  return { ...order, items: order.items.filter(entry => entry.id !== dividerId) }
}

export function renameSidebarDivider(
  order: SidebarNavigationOrder,
  dividerId: string,
  label: string,
): SidebarNavigationOrder {
  const sanitized = sanitizeSidebarDividerLabel(label)
  if (!sanitized) return order
  return {
    ...order,
    items: order.items.map(entry => (
      entry.type === 'divider' && entry.id === dividerId
        ? { ...entry, label: sanitized }
        : entry
    )),
  }
}

export function isSidebarPageHideable(item: NavItem) {
  return !item.sidebarHidden && !item.sidebarAlwaysVisible
}

export function setSidebarPagesHidden(
  order: SidebarNavigationOrder,
  canonicalItems: readonly NavItem[],
  pageIds: readonly string[],
  hidden: boolean,
): SidebarNavigationOrder {
  const hideablePageIds = new Set(
    canonicalSidebarItems(canonicalItems)
      .filter(isSidebarPageHideable)
      .map(item => item.to),
  )
  const requestedPageIds = new Set(pageIds.filter(pageId => hideablePageIds.has(pageId)))
  if (requestedPageIds.size === 0) return order

  const nextHiddenPageIds = hidden
    ? [...order.hiddenPageIds, ...requestedPageIds]
    : order.hiddenPageIds.filter(pageId => !requestedPageIds.has(pageId))
  const normalizedHiddenPageIds = Array.from(new Set(nextHiddenPageIds))
  if (normalizedHiddenPageIds.length === order.hiddenPageIds.length
    && normalizedHiddenPageIds.every((pageId, index) => pageId === order.hiddenPageIds[index])) {
    return order
  }
  return { ...order, hiddenPageIds: normalizedHiddenPageIds }
}

export function applySidebarNavigationOrder(
  canonicalItems: readonly NavItem[],
  order: SidebarNavigationOrder,
  visiblePageIds?: ReadonlySet<string>,
): Array<SidebarDividerEntry | { type: 'page'; id: string; item: NavItem }> {
  const byId = new Map(canonicalSidebarItems(canonicalItems).map(item => [item.to, item]))
  const result: Array<SidebarDividerEntry | { type: 'page'; id: string; item: NavItem }> = []
  for (const entry of order.items) {
    if (entry.type === 'divider') {
      result.push(entry)
      continue
    }
    const item = byId.get(entry.id)
    if (item && (!visiblePageIds || visiblePageIds.has(entry.id))) {
      result.push({ ...entry, item })
    }
  }
  return result
}

function readStorage(key: string): unknown {
  try {
    const raw = localStorage.getItem(key)
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

function loadSavedOrder() {
  const current = readStorage(SIDEBAR_ORDER_STORAGE_KEY)
  if (current !== null) return { saved: current, migrationKey: null }
  const previous = readStorage(SIDEBAR_ORDER_V2_STORAGE_KEY)
  if (previous !== null) return { saved: previous as SidebarNavigationOrderV2, migrationKey: SIDEBAR_ORDER_V2_STORAGE_KEY }
  const legacy = readStorage(SIDEBAR_ORDER_V1_STORAGE_KEY)
  return {
    saved: legacy,
    migrationKey: legacy !== null ? SIDEBAR_ORDER_V1_STORAGE_KEY : null,
  }
}

function saveOrder(order: SidebarNavigationOrder) {
  try {
    localStorage.setItem(SIDEBAR_ORDER_STORAGE_KEY, JSON.stringify(order))
    return true
  } catch {
    // Browser storage can be unavailable; the in-memory order still works.
    return false
  }
}

function ordersMatch(left: SidebarNavigationOrder, right: SidebarNavigationOrder) {
  return JSON.stringify(left.items) === JSON.stringify(right.items)
    && JSON.stringify(left.hiddenPageIds) === JSON.stringify(right.hiddenPageIds)
}

function newDividerId() {
  const suffix = typeof crypto.randomUUID === 'function'
    ? crypto.randomUUID()
    : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
  return `divider:user:${suffix}`
}

export function useSidebarNavigationOrder(
  canonicalItems: readonly NavItem[],
  visibleItems: readonly NavItem[],
) {
  const [initial] = useState(loadSavedOrder)
  const [savedOrder, setSavedOrder] = useState<unknown>(initial.saved)
  const migrationPersistedRef = useRef(false)
  const normalizedOrder = useMemo(
    () => normalizeSidebarNavigationOrder(savedOrder, canonicalItems),
    [savedOrder, canonicalItems],
  )
  const defaultOrder = useMemo(
    () => getCanonicalSidebarNavigationOrder(canonicalItems),
    [canonicalItems],
  )
  const visiblePageIds = useMemo(
    () => new Set(visibleItems.map(item => item.to)),
    [visibleItems],
  )
  const layoutItems = useMemo(
    () => applySidebarNavigationOrder(canonicalItems, normalizedOrder, visiblePageIds),
    [canonicalItems, normalizedOrder, visiblePageIds],
  )
  const hiddenPageIds = useMemo(
    () => new Set(normalizedOrder.hiddenPageIds),
    [normalizedOrder.hiddenPageIds],
  )

  useEffect(() => {
    if (!initial.migrationKey || migrationPersistedRef.current) return
    migrationPersistedRef.current = true
    if (saveOrder(normalizedOrder)) {
      try { localStorage.removeItem(initial.migrationKey) } catch { /* ignore */ }
    }
  }, [initial.migrationKey, normalizedOrder])

  const update = useCallback((change: (current: SidebarNavigationOrder) => SidebarNavigationOrder) => {
    setSavedOrder((current: unknown) => {
      const currentOrder = normalizeSidebarNavigationOrder(current, canonicalItems)
      const next = change(currentOrder)
      if (next !== currentOrder) saveOrder(next)
      return next
    })
  }, [canonicalItems])

  const reorder = useCallback((activeId: string, overId: string) => {
    update(current => reorderSidebarNavigationItem(current, activeId, overId))
  }, [update])

  const addDivider = useCallback(() => {
    const id = newDividerId()
    update(current => ({
      ...current,
      items: [...current.items, { type: 'divider', id, label: 'New section' }],
    }))
    return id
  }, [update])

  const renameDivider = useCallback((id: string, label: string) => {
    update(current => renameSidebarDivider(current, id, label))
  }, [update])

  const removeDivider = useCallback((id: string) => {
    update(current => removeSidebarDivider(current, id))
  }, [update])

  const setPagesHidden = useCallback((pageIds: readonly string[], hidden: boolean) => {
    update(current => setSidebarPagesHidden(current, canonicalItems, pageIds, hidden))
  }, [canonicalItems, update])

  const setPageHidden = useCallback((pageId: string, hidden: boolean) => {
    setPagesHidden([pageId], hidden)
  }, [setPagesHidden])

  const reset = useCallback(() => {
    try {
      localStorage.removeItem(SIDEBAR_ORDER_STORAGE_KEY)
      localStorage.removeItem(SIDEBAR_ORDER_V2_STORAGE_KEY)
      localStorage.removeItem(SIDEBAR_ORDER_V1_STORAGE_KEY)
    } catch { /* ignore */ }
    setSavedOrder(null)
  }, [])

  return {
    layoutItems,
    reorder,
    addDivider,
    renameDivider,
    removeDivider,
    hiddenPageIds,
    setPageHidden,
    setPagesHidden,
    reset,
    isCustomized: !ordersMatch(normalizedOrder, defaultOrder),
  }
}
