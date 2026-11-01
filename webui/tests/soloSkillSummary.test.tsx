import {afterEach,expect,it,vi} from 'vitest'
import {cleanup,fireEvent,render,screen,within} from '@testing-library/react'
import {SoloMode} from '../src/pages/SoloMode'
import {api} from '../src/api/client'

const status={connected:true,dataRoot:'C:/fixture',dbPath:'C:/fixture/game.db',profileToken:'fixture',profiles:[],inspection:{
  ok:true,characterCount:1,inventories:[],inventoryItems:[],rangedWeapons:[],fillables:[],currencies:{solari:0,scrip:0},
  progression:{specializations:[],totalSkillPoints:16,unspentSkillPoints:5,skillsAtSeven:0,intel:23},
}}
vi.mock('../src/hooks/useApi',()=>({useApi:(path:string)=>({data:path==='/api/solo/status'?status:path==='/api/solo/runtime'?{gameRunning:false,processes:[]}:null,loading:false,error:null,refresh:vi.fn()})}))
vi.mock('../src/api/client',()=>({api:vi.fn().mockResolvedValue({ok:true})}))
afterEach(()=>{cleanup();localStorage.clear();vi.clearAllMocks()})

it('shows allocated skill points even when no skill is at level seven, without editing the save',()=>{
  render(<SoloMode />)
  fireEvent.click(screen.getByRole('button',{name:'Character tools',exact:true}))
  fireEvent.click(screen.getByRole('button',{name:'Progression',exact:true}))
  fireEvent.click(screen.getByRole('button',{name:'Unlocks & rewards',exact:true}))
  const card=screen.getByText('Trainers and Skills',{selector:'summary'}).closest('details')!
  fireEvent.click(within(card).getByText('Trainers and Skills',{selector:'summary'}))
  expect(within(card).getByText('11 skill points spent · 5 unspent · 0/143 skills at level 7 · 23 Intel')).toBeVisible()
  expect(vi.mocked(api).mock.calls.some(([,options])=>options?.method&&options.method!=='GET')).toBe(false)
})
