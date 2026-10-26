import { useEffect, useId, useRef, useState } from 'react'
import { importBlueprint, type BlueprintFile, type Player } from '../../../api/gameplay'
import { Icon } from '../../../components/Icon'
import { parseBlueprintFile } from '../../../util/blueprintFile'

export function BlueprintImport({player,canWrite,onChanged}:{player:Player;canWrite:boolean;onChanged:()=>void}) {
  const [blueprint,setBlueprint]=useState<BlueprintFile|null>(null)
  const fileInput=useRef<HTMLInputElement>(null)
  const fileId=useId()
  const [fileName,setFileName]=useState('')
  const [message,setMessage]=useState('')
  const [error,setError]=useState('')
  const [busy,setBusy]=useState(false)
  useEffect(()=>{setBlueprint(null);setFileName('');setMessage('');setError('')},[player.id])
  const offline=(player.online_status || '').toLowerCase()==='offline'
  return <section className="card p-4 space-y-3" aria-label="Import blueprint">
    <h3 className="font-semibold">Import Blueprint</h3>
    <p className="text-sm text-text-muted">Import a blueprint or downloaded map base layout into {player.name}'s backpack. The character must be offline.</p>
    <div className="space-y-2">
      <label htmlFor={fileId} className="block text-sm font-medium">Blueprint file (.json)</label>
      <div className="flex flex-wrap items-center gap-3">
        <button type="button" className="btn-secondary border-2 border-ibad/50" disabled={busy || !canWrite} onClick={()=>fileInput.current?.click()}>
          <Icon name="FolderOpen" size={17}/> Choose blueprint file
        </button>
        <span className={fileName?'text-sm text-text break-all':'text-sm text-text-muted'}>{fileName || 'No file selected'}</span>
      </div>
      <input id={fileId} ref={fileInput} key={player.id} type="file" accept="application/json,.json" disabled={busy || !canWrite} className="sr-only" onChange={async event=>{
        setBlueprint(null);setError('');setMessage('')
        const file=event.target.files?.[0]
        setFileName(file?.name || '')
        if (!file) return
        try {setBlueprint(parseBlueprintFile(await file.text()))} catch(e){setError(e instanceof Error?e.message:String(e))}
      }}/>
    </div>
    {blueprint && <p>{blueprint.name || 'Blueprint'}: {blueprint.instances.length} pieces · {blueprint.placeables?.length || 0} placeables</p>}
    {!offline && <p className="text-warning">Log out of the game and wait for your character to be Offline before importing.</p>}
    <button className="btn-primary" disabled={busy || !canWrite || !offline || !blueprint} onClick={async()=>{
      if(!blueprint)return
      setBusy(true);setMessage('');setError('')
      try {const result=await importBlueprint(player.id,blueprint);setMessage(result.message || 'Blueprint imported into your backpack.');setBlueprint(null);setFileName('');if(fileInput.current)fileInput.current.value='';onChanged()}
      catch(e){setError(e instanceof Error?e.message:String(e))}finally{setBusy(false)}
    }}><Icon name={busy?'Loader2':'Upload'} size={15} className={busy?'animate-spin':''}/>{busy?'Importing…':'Import Blueprint'}</button>
    {message && <p role="status" className="text-success">{message}</p>}
    {error && <p role="alert" className="text-error">{error}</p>}
  </section>
}
