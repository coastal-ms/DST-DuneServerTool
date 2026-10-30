import {useEffect,useMemo,useRef,useState} from 'react'
import {filterCosmeticsCatalog,type CosmeticEntry} from '../api/gameplay'

export type CosmeticGrantSummary={message:string;incomplete:boolean}
export function cosmeticGrantSummary(entries:CosmeticEntry[],results:Record<string,string>):CosmeticGrantSummary {
 const submitted=entries.filter(entry=>results[entry.template]==='Submitted')
 const remaining=entries.filter(entry=>results[entry.template]!=='Submitted')
 return {incomplete:remaining.length>0,message:[`${submitted.length}/${entries.length} selected grant requests submitted.`,...entries.map(entry=>`${entry.name}: ${results[entry.template]??'Not submitted'}`)].join('\n')}
}

export function CosmeticMultiSelect({catalog,owned,saved,pending,disabled,playerOnline=false,onGrant,onComplete}: {
 catalog:CosmeticEntry[];owned:Set<string>;saved:Set<string>;pending:Set<string>;disabled:boolean;playerOnline?:boolean
 onGrant:(entry:CosmeticEntry)=>Promise<boolean|void>;onComplete?:(summary:CosmeticGrantSummary)=>Promise<void>
}) {
 const [query,setQuery]=useState(''),[showOwned,setShowOwned]=useState(true),[showExcluded,setShowExcluded]=useState(false)
 const [selected,setSelected]=useState<string[]>([]),[results,setResults]=useState<Record<string,string>>({}),[running,setRunning]=useState(false)
 const mounted=useRef(true)
 useEffect(()=>{mounted.current=true;return()=>{mounted.current=false}},[])
 const entries=useMemo(()=>Array.from(new Map(catalog.map(entry=>[entry.template,entry])).values()),[catalog])
 const matches=filterCosmeticsCatalog(entries.filter(e=>(showExcluded||!e.bulk_exclusion)&&(showOwned||!owned.has(e.template.toLowerCase()))),query)
 const visible=new Set(matches.map(e=>e.template))
 const groups=new Map<string,CosmeticEntry[]>()
 for(const entry of matches)groups.set(entry.group,[...(groups.get(entry.group)??[]),entry])
 const chosen=selected.map(id=>entries.find(e=>e.template===id)).filter((e):e is CosmeticEntry=>!!e)
 const remaining=chosen.filter(e=>results[e.template]!=='Submitted')
 const locked=disabled||running
 const blocked=playerOnline&&remaining.some(e=>e.grant_method==='character')
 function choose(ids:string[]) {
  setSelected([...new Set(ids)])
  setResults(previous=>Object.fromEntries(Object.entries(previous).filter(([id])=>ids.includes(id)&&selected.includes(id))))
 }
 async function grant() {
  if(locked||blocked||!remaining.length)return
  const batch=[...remaining], completed={...results};setRunning(true)
  try {
   for(const entry of batch) {
    if(!mounted.current)break
    try {
     const result=await onGrant(entry)
     completed[entry.template]=result===false?'Not submitted — see action result.':'Submitted'
     setResults({...completed})
     if(result===false)break
    } catch(error) {completed[entry.template]=error instanceof Error?error.message:'Request failed.';setResults({...completed});break}
   }
   if(mounted.current)await onComplete?.(cosmeticGrantSummary(chosen,completed))
  } finally {if(mounted.current)setRunning(false)}
 }
 return <div className="space-y-3">
  <label className="flex items-center gap-2 text-xs text-text-muted"><input type="checkbox" checked={showOwned} disabled={locked} onChange={e=>{setShowOwned(e.target.checked);if(!e.target.checked)choose(selected.filter(id=>!owned.has(id.toLowerCase())))}} />Show saved records and held tokens</label>
  <p className="text-xs text-text-muted">{entries.filter(e=>saved.has(e.template.toLowerCase())).length} saved unlock records / {entries.filter(e=>pending.has(e.template.toLowerCase())&&!saved.has(e.template.toLowerCase())).length} held tokens</p>
  <label className="flex items-center gap-2 text-xs text-text-muted"><input type="checkbox" checked={showExcluded} disabled={locked} onChange={e=>{setShowExcluded(e.target.checked);if(!e.target.checked)choose(selected.filter(id=>!entries.find(row=>row.template===id)?.bulk_exclusion))}} />Show tokens excluded from bulk grants</label>
  <input className="input w-full" aria-label="Search cosmetics" placeholder="Search name, template id, or group" value={query} disabled={locked} onChange={e=>setQuery(e.target.value)} />
  <p className="text-xs text-text-muted">Ctrl-click to select several entries; Shift-click to select a range. Selections stay selected while searching.</p>
  <select multiple size={8} aria-label="Cosmetics and building sets" className="w-full rounded-lg border border-border bg-surface-2 p-3 text-text text-sm" style={{colorScheme:'inherit'}} value={selected} disabled={locked}
   onChange={event=>choose([...selected.filter(id=>!visible.has(id)),...Array.from(event.currentTarget.selectedOptions,option=>option.value)])}>
   {[...groups.entries()].sort(([a],[b])=>a.localeCompare(b)).map(([group,rows])=><optgroup key={group} label={group}>{rows.map(entry=><option key={entry.template} value={entry.template}>{entry.name}{entry.bulk_exclusion?' — Excluded from bulk':saved.has(entry.template.toLowerCase())?' — Unlock record saved':pending.has(entry.template.toLowerCase())?' — Token held':''}</option>)}</optgroup>)}
  </select>
  <div className="flex items-center justify-between gap-3"><span className="text-sm">{chosen.length} selected · {matches.length} matching</span><button type="button" className="btn-secondary" disabled={locked||!selected.length} onClick={()=>{setSelected([]);setResults({})}}>Clear selection</button></div>
  {!!chosen.length&&<ul className="max-h-48 overflow-y-auto space-y-2 text-xs" aria-label="Selected cosmetic grants">{chosen.map(entry=><li key={entry.template} className="flex flex-wrap justify-between gap-2"><div><span>{entry.name}{entry.bulk_exclusion&&<span className="text-warning"> — {entry.bulk_exclusion}</span>}</span>{entry.grant_method==='character'?<p className="text-text-muted">Saves this appearance directly to the character.</p>:pending.has(entry.template.toLowerCase())?<p className="text-text-muted">Unlock token already held in inventory. You can grant another token.</p>:saved.has(entry.template.toLowerCase())?<p className="text-text-muted">Unlock record saved. You can grant another token if the game still reports it locked.</p>:null}</div><span role="status">{results[entry.template]??'Selected'}</span></li>)}</ul>}
  {blocked&&<p className="text-xs text-warning">The player must be fully offline for the selected character appearances.</p>}
  <button type="button" className="btn-primary w-full" disabled={locked||blocked||!remaining.length} onClick={()=>void grant()}>{running?'Granting…':`Grant selected (${remaining.length})`}</button>
 </div>
}
