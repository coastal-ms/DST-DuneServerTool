import { useEffect, useState } from 'react'
const key = 'dst.inventory.loadImages'
const event = 'dst-inventory-images'
function read() { try { return localStorage.getItem(key) !== 'false' } catch { return true } }
export function useInventoryImages(): [boolean, (enabled: boolean) => void] {
  const [enabled, setEnabled] = useState(read)
  useEffect(() => {
    const sync = () => setEnabled(read())
    window.addEventListener(event, sync)
    window.addEventListener('storage', sync)
    return () => { window.removeEventListener(event, sync); window.removeEventListener('storage', sync) }
  }, [])
  return [enabled, value => {
    setEnabled(value)
    try { localStorage.setItem(key, String(value)) } catch { /* keep the current view usable */ }
    window.dispatchEvent(new Event(event))
  }]
}
