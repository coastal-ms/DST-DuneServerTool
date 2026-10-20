import fs from 'node:fs'
import path from 'node:path'
import { expect, it, vi } from 'vitest'
const html=fs.readFileSync(path.resolve(import.meta.dirname,'../../app/tools/DuneAtlas/index.html'),'utf8')
it('draws the first state before slow resource manifests finish',async()=>{
 const source=html.slice(html.indexOf('async function updateState()'),html.indexOf('let refreshTimer='))
 const draw=vi.fn(),elements=new Map()
 const document={querySelector:(id:string)=>{if(!elements.has(id))elements.set(id,{textContent:'',classList:{toggle:vi.fn()},replaceChildren:vi.fn(),append:vi.fn()});return elements.get(id)},createElement:()=>({className:''}),createTextNode:(v:string)=>v}
 let release!:()=>void
 const blocked=new Promise<void>(resolve=>release=resolve)
 const api=vi.fn(async(p:string)=>p==='/state'?{live:true,connected:true,gatheringUpdatedAt:'new',snapshot:{servers:[],spice:[]}}:(await blocked,{}))
 const update=new Function('api','draw','document','window',`let state=null,gatheringRevision=0,lastPointer=null,drag=null;const region={value:'DeepDesert'},renderFeedAge=()=>{},renderStormTiming=()=>{},renderCollectionControls=()=>{},restoreServerSelections=async()=>{},loadBaseArt=()=>{},regionReady=()=>false;${source};return updateState`)(api,draw,document,{})
 const pending=update()
 await vi.waitFor(()=>expect(api).toHaveBeenCalledWith('/gathering/HaggaBasin'))
 expect(draw).toHaveBeenCalled()
 release();await pending
 expect(draw.mock.calls.length).toBeGreaterThan(1)
})

it('keeps live polling and redraws new worms while supplemental manifests are pending',async()=>{
 const source=html.slice(html.indexOf('async function updateState()'),html.indexOf('let refreshTimer='))
 const draw=vi.fn(),elements=new Map()
 const document={querySelector:(id:string)=>{if(!elements.has(id))elements.set(id,{textContent:'',classList:{toggle:vi.fn()},replaceChildren:vi.fn(),append:vi.fn()});return elements.get(id)},createElement:()=>({className:''}),createTextNode:(v:string)=>v}
 let release!:()=>void
 const blocked=new Promise<void>(resolve=>release=resolve)
 let count=0
 const api=vi.fn(async(p:string)=>p==='/state'?{live:true,connected:true,gatheringUpdatedAt:'new',wormFeed:{items:Array(count++?9:0).fill({})},snapshot:{servers:[],spice:[]}}:(await blocked,{}))
 const update=new Function('api','draw','document','window',`let state=null,gatheringRevision=0,lastPointer=null,drag=null;const region={value:'DeepDesert'},renderFeedAge=()=>{},renderStormTiming=()=>{},renderCollectionControls=()=>{},restoreServerSelections=async()=>{},loadBaseArt=()=>{},regionReady=()=>false;${source};return {updateState,getState:()=>state}`)(api,draw,document,{})
 try {
  let finished=false
  const first=update.updateState().then(()=>finished=true)
  await vi.waitFor(()=>expect(api).toHaveBeenCalledWith('/gathering/HaggaBasin'))
  expect(finished).toBe(true)
  await first
  expect(update.getState().wormFeed.items).toHaveLength(0)
  await update.updateState()
  expect(update.getState().wormFeed.items).toHaveLength(9)
  expect(api.mock.calls.filter(([p])=>p==='/gathering/HaggaBasin')).toHaveLength(1)
 } finally {release()}
})
