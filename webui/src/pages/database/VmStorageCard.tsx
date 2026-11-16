import { useEffect, useState } from 'react'
import { api } from '../../api/client'
import { isLocalViewer } from '../../util/viewer'

type Plan = { supported: boolean; toolsReady?: boolean; canInstallTools?: boolean; canGrow: boolean; reason: string; revision?: string; disk?: string; partition?: string; lv?: string; diskBytes?: number; lvBytes?: number; filesystemBytes?: number; partitionGrowthBytes?: number; pvGrowthBytes?: number; lvGrowthBytes?: number; filesystemGrowthBytes?: number; baselineFreeExtents?: number; extentBytes?: number; recoveryOf?: string }
type State = { phase: string; message?: string; error?: string; statusError?: string; recoveryDirectory?: string }
const active = (phase?: string) => ['backup', 'preparing', 'expanding', 'partition', 'physical-volume', 'logical-volume', 'filesystem'].includes(phase ?? '')
const size = (bytes?: number) => bytes == null ? '—' : `${(bytes / 1024 ** 3).toFixed(2)} GiB`
const messageOf = (e: unknown) => e instanceof Error ? e.message : String(e)

export function VmStorageCard({ onExpanded }: { onExpanded?: () => void }) {
  const [plan, setPlan] = useState<Plan | null>(null)
  const [state, setState] = useState<State | null>(null)
  const [inspecting, setInspecting] = useState(false)
  const [applying, setApplying] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => { if (isLocalViewer()) void api<State>('/api/vm-storage/status').then(setState).catch(() => {}) }, [])
  useEffect(() => {
    if (!applying && !active(state?.phase)) return
    let stopped = false, checking = false
    const timer = window.setInterval(() => {
      if (checking) return
      checking = true
      void api<State>('/api/vm-storage/status').then(result => { if (!stopped) setState(result) }).catch(e => { if (!stopped) setError(messageOf(e)) }).finally(() => { checking = false })
    }, 2000)
    return () => { stopped = true; window.clearInterval(timer) }
  }, [applying, state?.phase])
  const inspect = async () => {
    setInspecting(true); setError(''); setPlan(null)
    try { setPlan(await api<Plan>('/api/vm-storage')) } catch (e) { setError(messageOf(e)) }
    finally { setInspecting(false) }
  }
  const installTools = async () => {
    setInspecting(true); setError(''); setPlan(null)
    try { setPlan(await api<Plan>('/api/vm-storage/tools', { method: 'POST' })) } catch (e) { setError(messageOf(e)) }
    finally { setInspecting(false) }
  }
  const expand = async () => {
    if (!plan?.canGrow || !plan.revision) return
    if (!window.confirm(`Expand the guest root storage on ${plan.disk}?\n\nPartition: ${plan.partition}\nRoot logical volume: ${plan.lv}\nDisk capacity: ${size(plan.diskBytes)}\n\nDST will create a verified database backup, copy database and partition/LVM recovery files to this PC, then grow the supported partition, LVM volume and ext4 filesystem. Existing volume-group free space is reserved. This does not enlarge the Hyper-V virtual disk or request a reboot. Continue?`)) return
    setApplying(true); setError(''); setState({ phase: 'backup', message: 'Creating and verifying recovery backups…' })
    try {
      setState(await api<State>('/api/vm-storage/expand', { method: 'POST', body: JSON.stringify({ confirmed: true, revision: plan.revision }) }))
      setPlan(null); onExpanded?.()
    } catch (e) {
      setError(messageOf(e))
      try { setState(await api<State>('/api/vm-storage/status')) } catch { setState({ phase: 'interrupted', message: 'Completion was not confirmed. Inspect the operation before retrying.' }) }
    } finally { setApplying(false) }
  }
  if (!isLocalViewer()) return null
  const busy = applying || inspecting || active(state?.phase)
  return <section className="space-y-3 rounded border border-border p-4" aria-label="Expand VM storage">
    <h3 className="font-medium">Expand VM storage</h3>
    <p className="text-sm text-text-muted">After enlarging the VM hard drive in Hyper-V, inspect the guest to make that additional space available to its root filesystem.</p>
    <button type="button" className="btn-secondary" disabled={busy} onClick={() => void inspect()}>{inspecting ? 'Inspecting storage…' : 'Inspect storage'}</button>
    {error && <p role="alert" className="text-danger">{error}</p>}
    {state?.message && <p role="status">{state.message}</p>}
    {state?.error && <p role="alert" className="text-danger">{state.error}</p>}
    {state?.statusError && <p className="text-warning">Status could not be refreshed: {state.statusError}</p>}
    {active(state?.phase) && <p role="status">Current step: {state?.phase}. Keep DST and the VM running.</p>}
    {state?.recoveryDirectory && <p className="break-all text-sm">Recovery files on this PC: {state.recoveryDirectory}</p>}
    {plan && <>
      {plan.toolsReady && <p className="text-success">Guest storage tools installed.</p>}
      <p>{plan.reason}</p>
      {plan.canInstallTools && <button type="button" className="btn-secondary" disabled={busy} onClick={() => void installTools()}>Install guest storage tools</button>}
      {plan.supported && <dl className="grid gap-2 text-sm sm:grid-cols-2">
        <div><dt>VM disk</dt><dd>{plan.disk} · {size(plan.diskBytes)}</dd></div>
        <div><dt>Root logical volume</dt><dd>{size(plan.lvBytes)}</dd></div>
        <div><dt>Root filesystem</dt><dd>{size(plan.filesystemBytes)}</dd></div>
        <div><dt>Existing reserved VG free space</dt><dd>{size((plan.baselineFreeExtents ?? 0) * (plan.extentBytes ?? 0))}</dd></div>
      </dl>}
      {plan.recoveryOf && <p className="text-warning">A previous expansion was incomplete. Its recovery files are retained. This preview continues only the remaining supported growth.</p>}
      <button type="button" className="btn-primary" disabled={busy || !plan.canGrow} onClick={() => void expand()}>{plan.recoveryOf ? 'Continue storage expansion' : 'Expand root storage'}</button>
    </>}
  </section>
}
