import { useCallback, useEffect, useState } from 'react'

const KEY = 'dst.sidebar.collapsed'

// Persists the sidebar collapsed/expanded state across reloads. When collapsed
// the sidebar shrinks to an icon rail; when expanded it shows the full nav.
export function useSidebarCollapsed() {
  const [collapsed, setCollapsed] = useState<boolean>(() => {
    try { return localStorage.getItem(KEY) === '1' } catch { return false }
  })
  useEffect(() => {
    try { localStorage.setItem(KEY, collapsed ? '1' : '0') } catch { /* ignore */ }
  }, [collapsed])
  const toggle = useCallback(() => setCollapsed(v => !v), [])
  return { collapsed, setCollapsed, toggle }
}
