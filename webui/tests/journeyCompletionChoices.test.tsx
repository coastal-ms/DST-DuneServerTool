import { afterEach, expect, it, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { JourneyCompletionChoices } from '../src/components/JourneyCompletionChoices'
vi.mock('../src/api/gameplay', () => ({
 getProgressionPresets: vi.fn().mockResolvedValue({presets:[
  {id:'act1_complete',name:'Complete Act 1',nodes:['DA_MQ_ANewBeginning','DA_MQ_FindTheFremen']},
  {id:'act2_complete',name:'Complete Act 2',nodes:['DA_MQ_AssassinsHandbook','DA_MQ_TheGreatConvention']},
  {id:'act4_complete',name:'Complete Act 4 — The Great Convention, Part III',nodes:['DA_MQ_TheGreatConventionPt3']},
  {id:'faction_atreides_complete',name:'Complete Atreides faction journeys',nodes:['DA_FQ_ClimbTheRanks.Rank20_Mission_Atreides']},
  {id:'scourge_complete',name:'Complete Scourge',nodes:[]},
  {id:'skip_npe',name:'Skip NPE',nodes:['DA_MQ_NPEAutocompleted']},
  {id:'unlock_all_lore',name:'Unlock All Lore',nodes:['DA_Dunipedia_KnownUniverse']},
 ]}),
 getMainQuestCatalog: vi.fn().mockResolvedValue({main_quests:[{id:'DA_MQ_AssassinsHandbook',name:'Assassin Handbook'},{id:'DA_MQ_FutureStory',name:'Future Story'}]})
}))
afterEach(cleanup)
it('merges story choices without duplicate main quests or tutorial/codex actions', async () => {
 const preset=vi.fn(), quest=vi.fn()
 render(<JourneyCompletionChoices category="story" busy={false} onPreset={preset} onQuest={quest} />)
 await screen.findByRole('option',{name:'Complete Act 2'})
 expect(screen.queryByRole('option',{name:/Assassin Handbook|NPE|Lore/})).not.toBeInTheDocument()
 expect(screen.getByRole('option',{name:/Complete Act 4/})).toBeInTheDocument()
 expect(screen.queryByRole('option',{name:/faction journeys/})).not.toBeInTheDocument()
 fireEvent.change(screen.getByRole('combobox'),{target:{value:'act2_complete'}})
 fireEvent.click(screen.getByRole('button',{name:'Complete Act 2'}));expect(preset).toHaveBeenCalledWith('act2_complete')
 fireEvent.change(screen.getByRole('combobox'),{target:{value:'DA_MQ_FutureStory'}})
 fireEvent.click(screen.getByRole('button',{name:'Complete Future Story'}));expect(quest).toHaveBeenCalledWith('DA_MQ_FutureStory')
})
it('keeps tutorial completion separate from story and codex', async () => {
 render(<JourneyCompletionChoices category="tutorial" busy={false} onPreset={vi.fn()} onQuest={vi.fn()} />)
 await screen.findByRole('option',{name:'Complete Full Tutorial'})
 expect(screen.getAllByRole('option')).toHaveLength(1)
})
