import { PageHeader } from '../PageHeader'
import { useApi } from '../../hooks/useApi'
import { useState } from 'react'
import { api } from '../../api/client'

export interface DeckReport {
  os: { VERSION_ID: string }
  installations: Array<{ path: string; build_id: string }>
  saves: Array<{ path: string; bytes: number; stable?: boolean }>
  game_processes: Array<{ pid: number; name: string }>
  errors: string[]
  settings_write_capabilities?: string[]
  mod_capabilities?: string[]
  settings_candidates: Array<{ saved_root: string; files: Array<{
    file: string; path: string; exists: boolean
    values: Array<{ section: string; key: string; value: string }>
    duplicates: Array<{ section: string; key: string }>
  }> }>
}
export interface SoloDeckStatus {
  ok: boolean; paired: boolean; connected: boolean; readOnly: boolean
  error: string; report: DeckReport | null
  comparison?: { available: boolean; error: string; differenceCount: number; differences: Array<{
    file: string; section: string; key: string; pcValue: string | null; deckValue: string | null
    action: string; warning?: string
  }> }
}

function DeckPairing() {
  const [info,setInfo] = useState<{addresses:string[];code:string;certificateFingerprint:string;expires:string}|null>(null)
  const [busy,setBusy] = useState(false)
  const [error,setError] = useState('')
  const download = async () => {
    setBusy(true);setError('')
    try {
      const script = await api<string>('/api/solo/deck/companion')
      if (!script.startsWith('#!/bin/sh')) throw Error('Companion download was incomplete. Try again.')
      const url=URL.createObjectURL(new Blob([script],{type:'application/x-sh'}))
      const link=document.createElement('a');link.href=url;link.download='DST-Deck-Companion.sh';link.click()
      setTimeout(()=>URL.revokeObjectURL(url),1000)
    }catch(e){setError(e instanceof Error?e.message:String(e))}finally{setBusy(false)}
  }
  const pair = async () => {
    setBusy(true);setError('')
    try{setInfo(await api('/api/solo/deck/pairing',{method:'POST',body:'{}'}))}
    catch(e){setError(e instanceof Error?e.message:String(e))}finally{setBusy(false)}
  }
  return <section className="card p-5 mb-4">
    <h2 className="font-semibold mb-2">Connect your Steam Deck</h2>
    <ol className="list-decimal pl-5 space-y-2 text-sm mb-4">
      <li>Download the companion and copy it to your Deck. In Desktop Mode, right-click the file → Properties → Permissions and enable Is executable.</li>
      <li>In Steam, choose Games → Add a Non-Steam Game → Browse → All Files and select DST-Deck-Companion.sh. Leave compatibility forcing off.</li>
      <li>The companion sets up its own private connection automatically when you pair. It does not ask for or change your Deck password, create an account, or change the system SSH service.</li>
      <li>Finish Cloud sync, load the intended Solo save on the Deck, exit Dune on both devices and wait for Cloud to show Up to date.</li>
      <li>Keep the PC and Deck on the same private network. Enable pairing here, run the companion on the Deck and choose Pair with a DST PC. Compare its fingerprint with the one below, then enter the pairing code.</li>
      <li>After pairing, close the companion and choose Refresh Deck. Keep the Deck awake on the same network.</li>
    </ol>
    <div className="flex flex-wrap gap-2"><button className="btn-secondary" disabled={busy} onClick={()=>void download()}>Download Deck Companion</button><button className="btn-secondary" disabled={busy} onClick={()=>void pair()}>{info ? 'Refresh pairing code' : 'Enable pairing'}</button></div>
    {error&&<p role="alert" className="text-danger mt-3">{error}</p>}
    {info&&<div className="mt-4 space-y-2 text-sm"><p>Use the PC address on the same network as your Deck:</p><ul>{info.addresses.map(address=><li key={address} className="font-mono">{address}</li>)}</ul><p>Pairing code: <strong>{info.code}</strong> · expires {new Date(info.expires).toLocaleTimeString()}</p><p>Connection fingerprint—must match the Deck exactly:</p><p className="font-mono break-all">{info.certificateFingerprint}</p><p>If the code expires or is rejected, choose Refresh pairing code and enter the new code in the companion. You do not need to download it again.</p></div>}
  </section>
}

function DeckModSync({gameRunning}:{gameRunning:boolean}) {
  const [preview,setPreview]=useState<{token:string;mods:Array<{folder:string;name:string;version:string}>;runtimeVersion:string;bytes:number}|null>(null)
  const [busy,setBusy]=useState(false)
  const [error,setError]=useState('')
  const [launcher,setLauncher]=useState('')
  const sync=async(apply=false)=>{
    setBusy(true);setError('');setLauncher('')
    try{
      if(!apply)setPreview(await api('/api/solo/deck/mods/preview',{method:'POST',body:'{}'}))
      else{
        const result=await api<{ok:boolean;launcher:string}>('/api/solo/deck/mods/apply',{method:'POST',body:JSON.stringify({token:preview?.token,confirmed:true})})
        if(!result.ok)throw Error('Mod sync did not complete. Refresh before retrying.')
        setLauncher(result.launcher);setPreview(null)
      }
    }catch(e){setError(e instanceof Error?e.message:String(e));setPreview(null)}finally{setBusy(false)}
  }
  return <section className="card p-5 mb-4"><h2 className="font-semibold mb-2">Mods and Load with Mods App</h2>
    <p className="text-sm text-text-muted mb-3">Copy the PC's enabled mods, configuration and load order to the Deck. Previous Deck mod packages are retained. The original Dune shortcut stays unmodded.</p>
    <p className="text-sm text-text-muted mb-3">The first launch with mods can take longer than normal while shaders compile. Let it finish; later launches should be faster once shaders are cached. Updates may require shaders to compile again.</p>
    <button className="btn-secondary" disabled={busy||gameRunning} onClick={()=>void sync()}>Preview mod sync</button>
    {busy&&<p role="status" className="mt-3">Preparing or transferring mods…</p>}
    {error&&<p role="alert" className="text-danger mt-3">{error}</p>}
    {preview&&<div className="mt-3 text-sm"><p>{preview.mods.length} enabled mods · UE4SS {preview.runtimeVersion} · {(preview.bytes/1048576).toFixed(1)} MB</p><ol className="list-decimal pl-5 my-3">{preview.mods.map(mod=><li key={mod.folder}>{mod.name} {mod.version}</li>)}</ol><button className="btn-primary" disabled={busy||gameRunning} onClick={()=>void sync(true)}>Sync mods and get Load with Mods App</button></div>}
    {launcher&&<div role="status" className="mt-3 text-sm"><p>Mods synced. Load with Mods App is in the Deck's Downloads folder.</p><p className="break-all text-text-muted">{launcher}</p><p className="mt-2">In Steam Desktop Mode, choose Games → Add a Non-Steam Game → Browse → All Files and select DST-Load-With-Mods.sh. Leave compatibility forcing off. Use this shortcut for mods, or the original Dune entry for normal play.</p></div>}
  </section>
}

export function SoloDeck() {
  const state = useApi<SoloDeckStatus>('/api/solo/deck')
  const [preview, setPreview] = useState<{token?: string;complete?: boolean;rows: Array<{file:string;key:string;pcValue:string;deckValue:string|null;warning?:string}>} | null>(null)
  const [cloud, setCloud] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const report = !state.error && state.data?.connected ? state.data.report : null
  const connectionMessage = state.error || state.data?.error || ''
  const deckUnavailable = connectionMessage.startsWith('Steam Deck is unavailable.')
  const transfer = async (apply = false) => {
    setBusy(true);setError('');setNotice('')
    try {
      if (!apply) {
        setPreview(await api('/api/solo/deck/settings/preview', {method:'POST',body:'{}'}))
        setCloud(false)
      } else {
        const result = await api<{backup:string;saveUnchanged:boolean;remainingDifferences:number}>('/api/solo/deck/settings/apply', {method:'POST',body:JSON.stringify({token:preview?.token,confirmed:true,cloudConfirmed:cloud})})
        setPreview(null);setCloud(false)
        if (!result.saveUnchanged || result.remainingDifferences) throw Error('Transfer returned with differences. Refresh and inspect before launching.')
        setNotice(`Settings now match DST. The Deck save is unchanged.${result.backup ? ` Backup on Deck: ${result.backup}` : ''}`)
        await state.refresh()
      }
    } catch(e) {setError(e instanceof Error ? e.message : String(e));setPreview(null)}
    finally {setBusy(false)}
  }
  return <div className="text-text">
    <PageHeader title="Steam Deck" icon="Gamepad2" description="Experimental Solo connection for stock SteamOS. Limited support."
      actions={<button className="btn-secondary" disabled={state.loading} onClick={() => void state.refresh()}>Refresh Deck</button>} />
    <div className="mb-4 rounded-lg border border-warning/30 bg-warning/5 p-4 text-sm">
      Make grants and save changes in PC DST, then finish Steam Cloud sync on the same Steam account before playing on the Deck. Settings sync is one way: this PC → Steam Deck.
    </div>
    {state.loading && <p role="status">Reading the Steam Deck…</p>}
    {connectionMessage && <p role={deckUnavailable ? 'status' : 'alert'} className={deckUnavailable ? 'text-text-muted mb-4' : 'text-danger'}>{connectionMessage}</p>}
    <DeckPairing />
    {report && <>
      {report.mod_capabilities?.includes('mods-sync-v1') && <DeckModSync gameRunning={!!report.game_processes.length}/>}
      {report.settings_write_capabilities?.includes('managed-ini-v1') && <section className="card p-5 mb-4">
        <h2 className="font-semibold mb-2">Sync settings to Deck</h2>
        <p className="text-sm text-text-muted mb-3">Copies explicit DST overrides in Engine.ini, Game.ini and ServerCustomSettings.ini. Other Deck settings are preserved. Original files are backed up on the Deck.</p>
        <button className="btn-secondary" disabled={busy || !!report.game_processes.length} onClick={()=>void transfer()}>Preview settings sync</button>
        {busy && <p role="status" className="mt-3">Checking the Deck…</p>}
        {error && <p role="alert" className="text-danger mt-3">{error}</p>}
        {notice && <p role="status" className="mt-3 break-all">{notice}</p>}
        {preview?.complete && <p role="status" className="mt-3">Managed settings already match.</p>}
        {preview?.token && <div className="mt-3 space-y-3">
          <ul className="text-sm space-y-2">{preview.rows.map(row=><li key={row.file+row.key}><strong>{row.key}</strong>: {row.deckValue ?? 'No override'} → {row.pcValue}{row.warning && <p className="text-warning">{row.warning}</p>}</li>)}</ul>
          <label className="flex items-start gap-3 text-sm"><input type="checkbox" checked={cloud} disabled={busy} onChange={e=>setCloud(e.target.checked)}/><span>I loaded the intended save on the Deck, exited Dune on both devices, and waited for Steam Cloud to show Up to date.</span></label>
          <button className="btn-primary" disabled={busy||!cloud||!!report.game_processes.length} onClick={()=>void transfer(true)}>Approve and sync settings to Deck</button>
        </div>}
      </section>}
      <div className="card p-5 mb-4 space-y-2 text-sm">
        <h2 className="font-semibold text-base text-text">Connected to Steam Deck</h2>
        <p>SteamOS {report.os.VERSION_ID} · Dune {report.game_processes.length ? 'running' : 'closed'}</p>
        {report.installations.map(install => <p key={install.path} className="break-all">Dune build {install.build_id}: {install.path}</p>)}
        {report.saves.map(save => <p key={save.path} className="break-all">Solo save ({save.bytes.toLocaleString()} bytes): {save.path}</p>)}
        {report.errors.map((error, index) => <p key={index} role="alert">{error}</p>)}
      </div>
      {state.data?.comparison && <section className="card p-5 mb-4">
        <h2 className="font-semibold text-text">One-way settings comparison</h2>
        <p className="text-sm text-text-muted my-2">This PC → Steam Deck. Only explicit settings overrides are compared.</p>
        {!state.data.comparison.available ? <p className="text-sm">{state.data.comparison.error}</p> : <>
          <p className="text-sm mb-3">{state.data.comparison.differenceCount} difference{state.data.comparison.differenceCount === 1 ? '' : 's'} in explicit settings.</p>
          <div className="overflow-x-auto"><table className="w-full text-left text-sm">
            <thead><tr><th className="py-2 pr-4">Setting</th><th className="pr-4">Deck now</th><th className="pr-4">This PC</th><th>Sync preview</th></tr></thead>
            <tbody>{state.data.comparison.differences.map(entry => <tr key={`${entry.file}:${entry.section}:${entry.key}`} className="border-t border-border">
              <td className="py-2 pr-4"><span className="break-all">{entry.key}</span><span className="block text-xs text-text-muted">{entry.file}</span></td>
              <td className="pr-4 break-all">{entry.deckValue ?? 'No override'}</td>
              <td className="pr-4 break-all">{entry.pcValue ?? 'No override'}</td>
              <td>{entry.action}{entry.warning && <span className="block mt-1 text-xs text-warning">{entry.warning}</span>}</td>
            </tr>)}</tbody>
          </table></div>
        </>}
      </section>}
      {report.settings_candidates.map(candidate => <div key={candidate.saved_root} className="space-y-4">
        {candidate.files.map(file => <section key={file.path} className="card p-5">
          <h2 className="font-semibold">{file.file}</h2>
          <p className="text-xs text-text-muted break-all my-2">{file.path}</p>
          {!!file.duplicates.length && <p role="alert" className="text-warning">Duplicate managed keys need review before syncing.</p>}
          {!file.exists ? <p className="text-sm">This file has not been created on the Deck.</p> : !file.values.length ? <p className="text-sm">No explicit DST-managed overrides found. Game defaults are not inferred.</p> :
            <div className="overflow-x-auto"><table className="w-full text-sm text-left">
              <thead><tr><th className="py-2">Setting</th><th>Deck value</th></tr></thead>
              <tbody>{file.values.map((entry, index) => <tr key={`${entry.section}:${entry.key}:${index}`} className="border-t border-border">
                <td className="py-2 pr-4 break-all">{entry.key}</td><td className="break-all">{entry.value}</td>
              </tr>)}</tbody>
            </table></div>}
        </section>)}
      </div>)}
    </>}
  </div>
}
