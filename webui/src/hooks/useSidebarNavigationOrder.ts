import { useCallback, useMemo, useState } from 'react'
import { arrayMove } from '@dnd-kit/sortable'
import { GROUP_ORDER, type NavGroup, type NavItem } from '../nav'

export const SIDEBAR_ORDER_STORAGE_KEY = 'dst.sidebar.navigation-order.v1'

export type SidebarNavigationOrder = {
  version: 1
  groups: Partial<Record<NavGroup, string[]>>
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function normalizeSidebarNavigationOrder(
  saved: unknown,
  canonicalItems: readonly NavItem[],
): SidebarNavigationOrder {
  const savedGroups = isRecord(saved)
    && saved.version === 1
    && isRecord(saved.groups)
    ? saved.groups
    : {}
  const groups: Partial<Record<NavGroup, string[]>> = {}

  for (const group of GROUP_ORDER) {
    const canonicalIds = canonicalItems
      .filter(item => item.group === group)
      .map(item => item.to)
    if (canonicalIds.length === 0) continue

    const validIds = new Set(canonicalIds)
    const seen = new Set<string>()
    const candidate = Array.isArray(savedGroups[group]) ? savedGroups[group] : []
    const kept = candidate.filter((id): id is string => {
      if (typeof id !== 'string' || !validIds.has(id) || seen.has(id)) return false
      seen.add(id)
      return true
    })
    groups[group] = [...kept, ...canonicalIds.filter(id => !seen.has(id))]
  }

  return { version: 1, groups }
}

export function reorderSidebarNavigationItem(
  order: SidebarNavigationOrder,
  group: NavGroup,
  activeId: string,
  overId: string,
): SidebarNavigationOrder {
  const groupOrder = order.groups[group] ?? []
  const oldIndex = groupOrder.indexOf(activeId)
  const newIndex = groupOrder.indexOf(overId)
  if (oldIndex < 0 || newIndex < 0 || oldIndex === newIndex) return order

  return {
    ...order,
    groups: {
      ...order.groups,
      [group]: arrayMove(groupOrder, oldIndex, newIndex),
    },
  }
}

export function applySidebarNavigationOrder(
  canonicalItems: readonly NavItem[],
  order: SidebarNavigationOrder,
): NavItem[] {
  const byId = new Map(canonicalItems.map(item => [item.to, item]))
  return GROUP_ORDER.flatMap(group => (
    (order.groups[group] ?? [])
      .map(id => byId.get(id))
      .filter((item): item is NavItem => item?.group === group)
  ))
}

function loadSavedOrder(): unknown {
  try {
    const raw = localStorage.getItem(SIDEBAR_ORDER_STORAGE_KEY)
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

function saveOrder(order: SidebarNavigationOrder) {
  try {
    localStorage.setItem(SIDEBAR_ORDER_STORAGE_KEY, JSON.stringify(order))
  } catch {
    // Browser storage can be unavailable; the in-memory order still works.
  }
}

function ordersMatch(left: SidebarNavigationOrder, right: SidebarNavigationOrder) {
  return GROUP_ORDER.every(group => {
    const leftIds = left.groups[group] ?? []
    const rightIds = right.groups[group] ?? []
    return leftIds.length === rightIds.length
      && leftIds.every((id, index) => id === rightIds[index])
  })
}

export function useSidebarNavigationOrder(canonicalItems: readonly NavItem[]) {
  const [savedOrder, setSavedOrder] = useState<unknown>(loadSavedOrder)
  const normalizedOrder = useMemo(
    () => normalizeSidebarNavigationOrder(savedOrder, canonicalItems),
    [savedOrder, canonicalItems],
  )
  const defaultOrder = useMemo(
    () => normalizeSidebarNavigationOrder(null, canonicalItems),
    [canonicalItems],
  )
  const orderedItems = useMemo(
    () => applySidebarNavigationOrder(canonicalItems, normalizedOrder),
    [canonicalItems, normalizedOrder],
  )

  const reorder = useCallback((group: NavGroup, activeId: string, overId: string) => {
    setSavedOrder((current: unknown) => {
      const currentOrder = normalizeSidebarNavigationOrder(current, canonicalItems)
      const next = reorderSidebarNavigationItem(currentOrder, group, activeId, overId)
      if (next !== currentOrder) saveOrder(next)
      return next
    })
  }, [canonicalItems])

  const reset = useCallback(() => {
    try { localStorage.removeItem(SIDEBAR_ORDER_STORAGE_KEY) } catch { /* ignore */ }
    setSavedOrder(null)
  }, [])

  return {
    orderedItems,
    reorder,
    reset,
    isCustomized: !ordersMatch(normalizedOrder, defaultOrder),
  }
}
