import { useEffect, useState } from 'react'
import { getSoloNativeGrants, type SoloNativeGrantResult } from '../../api/solo'

export function SoloGrantDelivery({ profileToken, gameRunning, revision }: {
  profileToken: string; gameRunning: boolean; revision: number
}) {
  const [requests, setRequests] = useState<SoloNativeGrantResult[]>([])
  const [error, setError] = useState('')
  useEffect(() => {
    let active = true
    let timer: ReturnType<typeof setTimeout> | undefined
    setRequests([])
    setError('')
    if (!profileToken) return
    const refresh = async () => {
      try {
        const result = await getSoloNativeGrants(profileToken)
        if (!active) return
        setRequests(result.requests)
        setError(result.error ?? '')
        if (gameRunning && result.requests.some(r => r.status === 'queued' || r.status === 'processing')) {
          timer = setTimeout(() => void refresh(), 1500)
        }
      } catch (e) { if (active) setError(e instanceof Error ? e.message : String(e)) }
    }
    void refresh()
    return () => { active = false; if (timer) clearTimeout(timer) }
  }, [profileToken, gameRunning, revision])
  if (!requests.length && !error) return null
  return <div className="mt-3 space-y-2 text-sm" aria-live="polite">
    {requests.slice(0, 10).map(r => <div key={r.requestId} className={r.status === 'uncertain' ? 'text-warning' : 'text-text-muted'}>
      <strong>{({queued: 'Queued', processing: 'Delivering', delivered: 'Delivered', uncertain: 'Check backpack'})[r.status]}</strong>
      {' · '}{r.completed}/{r.total} item types. {r.message}
    </div>)}
    {error && <p className="text-warning">{error}</p>}
  </div>
}
